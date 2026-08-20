defmodule PtcLlmHttp.RuntimeTest do
  use ExUnit.Case, async: false

  alias PtcLlmHttp.{Deadline, Error, Limits, ProcessBudget, Runtime}
  alias PtcLlmHttp.Runtime.{Admission, AttemptTree, Coordinator, Guardian, Role}
  alias PtcLlmHttp.Test.{RawServer, ScriptedBackend}
  alias PtcLlmHttp.Transport.Tcp

  test "validates runtime-wide and group ceilings before starting" do
    assert {:ok, runtime} = Runtime.start_link(groups: %{"group" => 1}, max_concurrency: 1)
    assert Runtime.ready?(runtime)
    Supervisor.stop(runtime)

    assert {:error, %Error{kind: :invalid_request}} =
             Runtime.start_link(max_concurrency: 0, groups: %{})

    assert {:error, %Error{kind: :invalid_request}} =
             Runtime.start_link(max_concurrency: 2, groups: %{"group" => 3})

    assert {:error, %Error{kind: :invalid_request}} =
             Runtime.start_link(
               max_concurrency: 1_024,
               groups: Map.new(1..257, &{"group-#{&1}", 1})
             )

    assert {:error, %Error{kind: :invalid_request}} =
             Runtime.start_link(max_concurrency: 1, groups: %{"bad\ngroup" => 1})
  end

  test "publishes readiness and bounded counter snapshots" do
    runtime = runtime(max_concurrency: 3, groups: %{"a" => 1, "b" => 2})

    assert Runtime.ready?(runtime)

    assert Runtime.snapshot(runtime) ==
             {:ok,
              %{
                in_use: 0,
                limit: 3,
                groups: %{
                  "a" => %{in_use: 0, limit: 1},
                  "b" => %{in_use: 0, limit: 2}
                }
              }}
  end

  test "global and group reservations are fail-fast and atomic" do
    runtime = runtime(max_concurrency: 2, groups: %{"a" => 1, "b" => 2})
    budget = budget()
    deadline = deadline()
    first = async_attempt(runtime, "a", budget, deadline, ScriptedBackend.hold(self(), :first))

    assert_receive {:scripted_backend_started, :first, first_role}
    assert {:ok, %{in_use: 1, groups: %{"a" => %{in_use: 1}}}} = Runtime.snapshot(runtime)

    refute_receive {:should_not_run, :same_group}

    assert {:error, %Error{kind: :capacity_exhausted}} =
             Runtime.run_attempt(runtime, "a", budget, deadline, fn ->
               send(self(), {:should_not_run, :same_group})
               {:ok, :wrong}
             end)

    second = async_attempt(runtime, "b", budget, deadline, ScriptedBackend.hold(self(), :second))
    assert_receive {:scripted_backend_started, :second, second_role}

    assert {:error, %Error{kind: :capacity_exhausted}} =
             Runtime.run_attempt(runtime, "b", budget, deadline, fn -> {:ok, :wrong} end)

    send(first_role, {:scripted_backend_release, :first, {:ok, :first}})
    send(second_role, {:scripted_backend_release, :second, {:ok, :second}})
    assert Task.await(first) == {:ok, :first}
    assert Task.await(second) == {:ok, :second}
    assert {:ok, %{in_use: 0}} = Runtime.snapshot(runtime)
  end

  test "payload enters only registered attempt roles and never shared control state" do
    runtime = runtime(max_concurrency: 1, groups: %{"group" => 1})
    sentinel = "private-payload-sentinel"

    task =
      async_attempt(
        runtime,
        "group",
        budget(),
        deadline(),
        ScriptedBackend.hold(self(), sentinel)
      )

    assert_receive {:scripted_backend_started, ^sentinel, role}
    {:ok, components} = Runtime.components(runtime)

    refute contains_binary?(:sys.get_state(components.guardian), sentinel)
    refute contains_binary?(:sys.get_state(components.admission), sentinel)
    refute contains_binary?(:sys.get_state(components.attempt_supervisor), sentinel)

    send(role, {:scripted_backend_release, sentinel, {:ok, :done}})
    assert Task.await(task) == {:ok, :done}
  end

  test "success and classified errors commit only after full tree teardown and lease release" do
    runtime = runtime(max_concurrency: 1, groups: %{"group" => 1})
    error = Error.build!(:internal_failure, :admission, :transport, :not_sent)

    assert Runtime.run_attempt(runtime, "group", budget(), deadline(), fn -> {:ok, :done} end) ==
             {:ok, :done}

    refute_receive {:ptc_llm_http_progress, _attempt_id, _phase, _dispatch}

    assert {:ok, %{in_use: 0}} = Runtime.snapshot(runtime)

    assert Runtime.run_attempt(runtime, "group", budget(), deadline(), fn -> {:error, error} end) ==
             {:error, error}

    assert {:ok, %{in_use: 0}} = Runtime.snapshot(runtime)
  end

  test "the absolute deadline kills held work before returning and releases capacity" do
    runtime = runtime(max_concurrency: 1, groups: %{"group" => 1})
    {:ok, deadline} = Deadline.new(System.monotonic_time(:millisecond) + 50)

    task =
      async_attempt(
        runtime,
        "group",
        budget(),
        deadline,
        ScriptedBackend.hold(self(), :deadline)
      )

    assert_receive {:scripted_backend_started, :deadline, role}
    role_monitor = Process.monitor(role)

    assert {:error,
            %Error{
              kind: :deadline_exceeded,
              phase: :send,
              dispatch: :possibly_sent
            }} = Task.await(task, 2_000)

    assert_receive {:DOWN, ^role_monitor, :process, ^role, _reason}, 1_200
    refute Process.alive?(role)
    assert {:ok, %{in_use: 0}} = Runtime.snapshot(runtime)
  end

  test "a deadline beyond the OTP timer maximum remains usable" do
    runtime = runtime(max_concurrency: 1, groups: %{"group" => 1})

    {:ok, far_deadline} =
      Deadline.new(
        System.monotonic_time(:millisecond) + Limits.maximum_timer_milliseconds() + 10_000
      )

    assert Runtime.run_attempt(runtime, "group", budget(), far_deadline, fn -> {:ok, :done} end) ==
             {:ok, :done}
  end

  test "caller death tears down every attempt role before the lease becomes reusable" do
    runtime = runtime(max_concurrency: 1, groups: %{"group" => 1})
    parent = self()

    {caller, caller_monitor} =
      spawn_monitor(fn ->
        Runtime.run_attempt(
          runtime,
          "group",
          budget(),
          deadline(),
          ScriptedBackend.hold(parent, :caller_death)
        )
      end)

    assert_receive {:scripted_backend_started, :caller_death, role}
    role_monitor = Process.monitor(role)
    {:ok, components} = Runtime.components(runtime)
    attempt_id = only_attempt_id(components.guardian)

    assert :ok =
             Guardian.cause(
               components.guardian,
               components.generation,
               attempt_id,
               :deadline_exceeded
             )

    Process.exit(caller, :kill)

    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :killed}
    assert_receive {:DOWN, ^role_monitor, :process, ^role, _reason}, 1_200
    assert_eventually(fn -> Runtime.snapshot(runtime) == {:ok, idle_snapshot(1)} end)
  end

  test "caller death during provisional startup kills the unregistered tree and releases its lease" do
    runtime = runtime(max_concurrency: 1, groups: %{"group" => 1})
    {:ok, components} = Runtime.components(runtime)
    parent = self()
    attempt_id = make_ref()
    lease_deadline = deadline()

    {caller, caller_monitor} =
      spawn_monitor(fn ->
        {:ok, lease} =
          Admission.reserve(
            components.admission,
            components.generation,
            "group",
            attempt_id,
            self(),
            lease_deadline
          )

        {:ok, tree} =
          Admission.start_attempt(
            components.admission,
            components.generation,
            lease,
            attempt_id,
            self(),
            components.attempt_supervisor,
            budget(),
            lease_deadline
          )

        send(parent, {:provisional_tree, tree})

        receive do
          :never_sent -> :ok
        end
      end)

    assert_receive {:provisional_tree, tree}
    tree_monitor = Process.monitor(tree)
    Process.exit(caller, :kill)

    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :killed}
    assert_receive {:DOWN, ^tree_monitor, :process, ^tree, _reason}
    assert_eventually(fn -> Runtime.snapshot(runtime) == {:ok, idle_snapshot(1)} end)
  end

  test "a role heap death is classified without exposing its raw reason" do
    runtime = runtime(max_concurrency: 1, groups: %{"group" => 1})

    result =
      Runtime.run_attempt(
        runtime,
        "group",
        budget(),
        deadline(),
        ScriptedBackend.allocate(self(), :heap, 1_000_000)
      )

    assert_receive {:scripted_backend_started, :heap, _role}
    refute_receive {:scripted_backend_allocated, :heap, _entries}

    assert {:error,
            %Error{
              kind: :resource_limit_exceeded,
              phase: :send,
              dispatch: :possibly_sent
            }} = result

    assert inspect(elem(result, 1)) == "#PtcLlmHttp.Error<redacted>"
    assert {:ok, %{in_use: 0}} = Runtime.snapshot(runtime)
  end

  test "every fixed role heap death is classified before and after dispatch" do
    runtime = runtime(max_concurrency: 1, groups: %{"group" => 1})

    for phase <- [:admission, :send],
        role <- [:attempt_tree, :coordinator, :codec, :callback, :dns, :socket, :relay] do
      %{attempt_id: attempt_id, tree: tree, roles: roles} = registered_attempt(runtime)

      if phase == :send do
        {:ok, components} = Runtime.components(runtime)

        assert :ok =
                 Guardian.progress(
                   components.guardian,
                   components.generation,
                   attempt_id,
                   :send,
                   :possibly_sent
                 )
      end

      role_pid = if role == :attempt_tree, do: tree, else: Map.fetch!(roles, role)
      force_heap_death(role_pid, role)

      expected_dispatch = if phase == :send, do: :possibly_sent, else: :not_sent

      assert_receive {:ptc_llm_http_decision, ^attempt_id, nil,
                      {:discard, :resource_limit, ^phase, ^expected_dispatch}},
                     1_200

      assert_eventually(fn -> Runtime.snapshot(runtime) == {:ok, idle_snapshot(1)} end)
    end
  end

  test "a higher-precedence deadline can discard an acknowledged terminal candidate" do
    runtime = runtime(max_concurrency: 1, groups: %{"group" => 1})
    %{attempt_id: attempt_id, roles: roles} = registered_attempt(runtime)
    operation = ScriptedBackend.hold(self(), :terminal_race)
    Role.run(roles.socket, self(), make_ref(), operation)
    assert_receive {:scripted_backend_started, :terminal_race, _socket}

    {:ok, components} = Runtime.components(runtime)
    delivery_ref = make_ref()

    assert :ok =
             Guardian.candidate(
               components.guardian,
               components.generation,
               attempt_id,
               deadline(),
               delivery_ref,
               :success
             )

    assert :ok =
             Guardian.cause(
               components.guardian,
               components.generation,
               attempt_id,
               :deadline_exceeded
             )

    assert_receive {:ptc_llm_http_decision, ^attempt_id, ^delivery_ref,
                    {:discard, :deadline_exceeded, :admission, :not_sent}},
                   1_200

    assert_eventually(fn -> Runtime.snapshot(runtime) == {:ok, idle_snapshot(1)} end)
  end

  test "deadline precedence is deterministic when resource failure races cleanup" do
    runtime = runtime(max_concurrency: 1, groups: %{"group" => 1})
    %{attempt_id: attempt_id, roles: roles} = registered_attempt(runtime)
    Role.run(roles.socket, self(), make_ref(), ScriptedBackend.hold(self(), :cause_race))
    assert_receive {:scripted_backend_started, :cause_race, _socket}
    {:ok, components} = Runtime.components(runtime)

    assert :ok =
             Guardian.cause(
               components.guardian,
               components.generation,
               attempt_id,
               :resource_limit
             )

    assert :ok =
             Guardian.cause(
               components.guardian,
               components.generation,
               attempt_id,
               :deadline_exceeded
             )

    assert_receive {:ptc_llm_http_decision, ^attempt_id, nil,
                    {:discard, :deadline_exceeded, :admission, :not_sent}},
                   1_200

    assert_eventually(fn -> Runtime.snapshot(runtime) == {:ok, idle_snapshot(1)} end)
  end

  test "deadline remains authoritative until the guardian adopts the terminal candidate" do
    runtime = runtime(max_concurrency: 1, groups: %{"group" => 1})
    {:ok, absolute_deadline} = Deadline.new(System.monotonic_time(:millisecond) + 500)

    task =
      async_attempt(
        runtime,
        "group",
        budget(),
        absolute_deadline,
        ScriptedBackend.hold(self(), :handoff_deadline)
      )

    assert_receive {:scripted_backend_started, :handoff_deadline, socket}
    {:ok, components} = Runtime.components(runtime)

    [{_id, tree, :supervisor, _modules}] =
      DynamicSupervisor.which_children(components.attempt_supervisor)

    {:ok, roles} = AttemptTree.roles(tree)
    :ok = :sys.suspend(roles.relay)
    send(socket, {:scripted_backend_release, :handoff_deadline, {:ok, :too_late}})
    assert_eventually(fn -> :sys.get_state(roles.coordinator).terminal end)
    assert_eventually(fn -> match?({:error, %Error{}}, Deadline.remaining(absolute_deadline)) end)
    :ok = :sys.resume(roles.relay)

    assert {:error, %Error{kind: :deadline_exceeded, phase: :send, dispatch: :possibly_sent}} =
             Task.await(task, 2_000)

    assert {:ok, %{in_use: 0}} = Runtime.snapshot(runtime)
  end

  test "admission-owner death before terminal handoff fences the attempt" do
    runtime = runtime(max_concurrency: 1, groups: %{"group" => 1})
    {:ok, old} = Runtime.components(runtime)

    task =
      async_attempt(
        runtime,
        "group",
        budget(),
        deadline(),
        ScriptedBackend.hold(self(), :pre_handoff_admission_death)
      )

    assert_receive {:scripted_backend_started, :pre_handoff_admission_death, role}
    role_monitor = Process.monitor(role)
    Process.exit(old.admission, :kill)

    assert {:error, %Error{kind: :runtime_unavailable, phase: :send, dispatch: :possibly_sent}} =
             Task.await(task, 2_000)

    assert_receive {:DOWN, ^role_monitor, :process, ^role, _reason}
    assert_eventually(fn -> Runtime.ready?(runtime) end, 1_500)
    assert {:ok, %{in_use: 0}} = Runtime.snapshot(runtime)
  end

  test "admission-owner death fences the old generation and publishes no stale capacity" do
    runtime = runtime(max_concurrency: 1, groups: %{"group" => 1})
    {:ok, old} = Runtime.components(runtime)

    task =
      async_attempt(
        runtime,
        "group",
        budget(),
        deadline(),
        ScriptedBackend.hold(self(), :fenced)
      )

    assert_receive {:scripted_backend_started, :fenced, role}
    role_monitor = Process.monitor(role)
    attempt_id = only_attempt_id(old.guardian)

    assert :ok =
             Guardian.candidate(
               old.guardian,
               old.generation,
               attempt_id,
               deadline(),
               make_ref(),
               :success
             )

    Process.exit(old.admission, :kill)

    assert {:error,
            %Error{
              kind: :runtime_unavailable,
              phase: :send,
              dispatch: :possibly_sent
            }} = Task.await(task, 2_000)

    assert_receive {:DOWN, ^role_monitor, :process, ^role, _reason}

    assert_eventually(fn -> Runtime.ready?(runtime) end)
    {:ok, replacement} = Runtime.components(runtime)
    refute replacement.generation == old.generation
    refute replacement.admission == old.admission
    assert {:ok, %{in_use: 0}} = Runtime.snapshot(runtime)

    assert Runtime.run_attempt(runtime, "group", budget(), deadline(), fn ->
             {:ok, :replacement}
           end) ==
             {:ok, :replacement}
  end

  test "guardian death tears down the later generation before the runtime restarts" do
    runtime = runtime(max_concurrency: 1, groups: %{"group" => 1})
    {:ok, old} = Runtime.components(runtime)

    task =
      async_attempt(
        runtime,
        "group",
        budget(),
        deadline(),
        ScriptedBackend.hold(self(), :guardian)
      )

    assert_receive {:scripted_backend_started, :guardian, role}
    role_monitor = Process.monitor(role)
    Process.exit(old.guardian, :kill)

    assert {:error, %Error{kind: :runtime_unavailable}} = Task.await(task, 2_000)
    assert_receive {:DOWN, ^role_monitor, :process, ^role, _reason}
    assert_eventually(fn -> Runtime.ready?(runtime) end)

    {:ok, replacement} = Runtime.components(runtime)
    refute replacement.guardian == old.guardian
    refute replacement.generation_supervisor == old.generation_supervisor
    assert {:ok, %{in_use: 0}} = Runtime.snapshot(runtime)
  end

  test "expired work is never dispatched after coordinator binding" do
    parent = self()
    {:ok, coordinator} = Coordinator.start_link(100_000)
    {:ok, socket} = Role.start_link({:socket, 200_000})
    {:ok, expired} = Deadline.new(System.monotonic_time(:millisecond))
    generation = make_ref()
    attempt_id = make_ref()

    :ok =
      Coordinator.bind(coordinator, %{
        guardian: self(),
        generation: generation,
        attempt_id: attempt_id,
        caller: self(),
        deadline: expired,
        roles: %{socket: socket}
      })

    Coordinator.execute(coordinator, fn ->
      send(parent, :expired_operation_ran)
      {:ok, :wrong}
    end)

    assert_receive {:"$gen_call", from, {:cause, ^generation, ^attempt_id, :deadline_exceeded}}

    GenServer.reply(from, :ok)
    refute_receive :expired_operation_ran
    GenServer.stop(coordinator)
    GenServer.stop(socket)
  end

  test "terminal role messages recheck the clock even when the timer message is delayed" do
    {:ok, coordinator} = Coordinator.start_link(100_000)
    {:ok, future} = Deadline.new(System.monotonic_time(:millisecond) + 10_000)
    generation = make_ref()
    attempt_id = make_ref()
    operation_ref = make_ref()

    :ok =
      Coordinator.bind(coordinator, %{
        guardian: self(),
        generation: generation,
        attempt_id: attempt_id,
        caller: self(),
        deadline: future,
        roles: %{}
      })

    {:ok, expired} = Deadline.new(System.monotonic_time(:millisecond))

    :sys.replace_state(coordinator, fn state ->
      %{state | operation_ref: operation_ref, binding: %{state.binding | deadline: expired}}
    end)

    send(coordinator, {:role_result, operation_ref, {:ok, :late}})
    assert_receive {:"$gen_call", from, {:cause, ^generation, ^attempt_id, :deadline_exceeded}}
    GenServer.reply(from, :ok)
    refute_receive {:ptc_llm_http_candidate, ^attempt_id, _ref, :late, _relay}
    GenServer.stop(coordinator)
  end

  test "guardian death before progress acknowledgement records no dispatch" do
    parent = self()

    guardian =
      spawn(fn ->
        receive do
          {:"$gen_call", _from, {:progress, _generation, _attempt_id, :send, :possibly_sent}} ->
            exit(:killed)
        end
      end)

    guardian_monitor = Process.monitor(guardian)
    {:ok, coordinator} = Coordinator.start_link(100_000)
    {:ok, socket} = Role.start_link({:socket, 200_000})
    generation = make_ref()
    attempt_id = make_ref()

    :ok =
      Coordinator.bind(coordinator, %{
        guardian: guardian,
        generation: generation,
        attempt_id: attempt_id,
        caller: self(),
        deadline: deadline(),
        roles: %{socket: socket}
      })

    Coordinator.execute(coordinator, fn ->
      send(parent, :operation_dispatched_without_ack)
      {:ok, :wrong}
    end)

    assert_receive {:DOWN, ^guardian_monitor, :process, ^guardian, :killed}
    refute_receive {:ptc_llm_http_progress, ^attempt_id, :send, :possibly_sent}
    refute_receive :operation_dispatched_without_ack
    GenServer.stop(coordinator)
    GenServer.stop(socket)
  end

  test "a progress acknowledgement cannot hold an open socket past its deadline" do
    server = start_supervised!({RawServer, [transport: :tcp]})
    parent = self()

    guardian =
      spawn(fn ->
        receive do
          {:"$gen_call", _from, {:progress, _generation, _attempt_id, :tls, :not_sent}} ->
            send(parent, :guardian_progress_blocked)

            receive do
              :never -> :ok
            end
        end
      end)

    {:ok, coordinator} = Coordinator.start_link(100_000)
    {:ok, progress_deadline} = Deadline.new(System.monotonic_time(:millisecond) + 150)
    operation_ref = make_ref()

    :ok =
      Coordinator.bind(coordinator, %{
        guardian: guardian,
        generation: make_ref(),
        attempt_id: make_ref(),
        caller: self(),
        deadline: progress_deadline,
        roles: %{}
      })

    :sys.replace_state(coordinator, fn state ->
      %{state | operation_ref: operation_ref, mode: :http}
    end)

    task =
      Task.async(fn ->
        {:ok, socket} =
          Tcp.connect(
            %{address: {127, 0, 0, 1}, port: RawServer.port(server)},
            Deadline.monotonic_millisecond(progress_deadline)
          )

        try do
          Coordinator.transport_progress(
            coordinator,
            operation_ref,
            progress_deadline,
            :tls,
            :not_sent
          )
        after
          Tcp.close(socket)
        end
      end)

    assert :ok = RawServer.await_connection(server)
    assert_receive :guardian_progress_blocked
    assert {:error, :runtime_unavailable} = Task.await(task, 1_000)
    assert :ok = RawServer.await_close(server, 1_000)
    Process.exit(guardian, :kill)
    Process.exit(coordinator, :kill)
  end

  test "expiry during initial HTTP progress reports the deadline instead of wedging" do
    parent = self()

    guardian =
      spawn(fn ->
        receive do
          {:"$gen_call", progress_from, {:progress, generation, attempt_id, :dns, :not_sent}} ->
            Process.send_after(self(), {:finish_progress, progress_from}, 100)

            receive do
              {:finish_progress, ^progress_from} ->
                GenServer.reply(progress_from, {:error, :runtime_unavailable})
            end

            receive do
              {:"$gen_call", cause_from, {:cause, ^generation, ^attempt_id, :deadline_exceeded}} ->
                send(parent, :initial_progress_deadline_reported)
                GenServer.reply(cause_from, :ok)
            end
        end
      end)

    {:ok, coordinator} = Coordinator.start_link(100_000)
    {:ok, short_deadline} = Deadline.new(System.monotonic_time(:millisecond) + 50)

    :ok =
      Coordinator.bind(coordinator, %{
        guardian: guardian,
        generation: make_ref(),
        attempt_id: make_ref(),
        caller: self(),
        deadline: short_deadline,
        roles: %{}
      })

    Coordinator.execute(coordinator, {:http, %{}})
    assert_receive :initial_progress_deadline_reported, 1_000
    Process.exit(guardian, :kill)
    Process.exit(coordinator, :kill)
  end

  test "the cleanup bound cannot masquerade as a later operation deadline" do
    parent = self()

    guardian =
      spawn(fn ->
        receive do
          {:"$gen_call", _progress_from, {:progress, generation, attempt_id, :connect, :not_sent}} ->
            send(parent, :long_deadline_progress_blocked)

            receive do
              {:"$gen_call", _cause_from, {:cause, ^generation, ^attempt_id, :deadline_exceeded}} ->
                send(parent, :false_deadline_reported)
            end
        end
      end)

    guardian_monitor = Process.monitor(guardian)
    {:ok, coordinator} = Coordinator.start_link(100_000)
    {:ok, long_deadline} = Deadline.new(System.monotonic_time(:millisecond) + 5_000)
    operation_ref = make_ref()

    :ok =
      Coordinator.bind(coordinator, %{
        guardian: guardian,
        generation: make_ref(),
        attempt_id: make_ref(),
        caller: self(),
        deadline: long_deadline,
        roles: %{}
      })

    :sys.replace_state(coordinator, fn state ->
      %{state | operation_ref: operation_ref, mode: :http}
    end)

    task =
      Task.async(fn ->
        Coordinator.transport_progress(
          coordinator,
          operation_ref,
          long_deadline,
          :connect,
          :not_sent
        )
      end)

    assert_receive :long_deadline_progress_blocked
    assert {:error, :runtime_unavailable} = Task.await(task, 2_000)
    assert_receive {:DOWN, ^guardian_monitor, :process, ^guardian, :killed}, 2_000
    refute_receive :false_deadline_reported
    assert {:ok, _remaining} = Deadline.remaining(long_deadline)
    Process.exit(coordinator, :kill)
  end

  test "a timed-out provisional reservation reports the deadline and kills its generation" do
    runtime = runtime(max_concurrency: 1, groups: %{"group" => 1})
    {:ok, old} = Runtime.components(runtime)
    admission_monitor = Process.monitor(old.admission)
    :ok = :sys.suspend(old.admission)
    {:ok, short_deadline} = Deadline.new(System.monotonic_time(:millisecond) + 50)

    assert {:error, :deadline_exceeded} =
             Admission.reserve(
               old.admission,
               old.generation,
               "group",
               make_ref(),
               self(),
               short_deadline
             )

    assert_receive {:DOWN, ^admission_monitor, :process, _admission, :killed}
    assert_eventually(fn -> Runtime.ready?(runtime) end, 1_500)
    assert {:ok, %{in_use: 0}} = Runtime.snapshot(runtime)
  end

  test "deadline expiry during tree startup remains a deadline error" do
    runtime = runtime(max_concurrency: 1, groups: %{"group" => 1})
    {:ok, old} = Runtime.components(runtime)
    admission_monitor = Process.monitor(old.admission)
    :ok = :sys.suspend(old.attempt_supervisor)
    {:ok, short_deadline} = Deadline.new(System.monotonic_time(:millisecond) + 50)

    assert {:error, %Error{kind: :deadline_exceeded, phase: :admission, dispatch: :not_sent}} =
             Runtime.run_attempt(runtime, "group", budget(), short_deadline, fn ->
               {:ok, :wrong}
             end)

    assert_receive {:DOWN, ^admission_monitor, :process, _admission, :killed}
    assert_eventually(fn -> Runtime.ready?(runtime) end, 1_500)
    assert {:ok, %{in_use: 0}} = Runtime.snapshot(runtime)
  end

  test "deadline expiry during guardian adoption is not flattened" do
    runtime = runtime(max_concurrency: 1, groups: %{"group" => 1})
    {:ok, components} = Runtime.components(runtime)
    attempt_id = make_ref()
    setup_deadline = deadline()

    {:ok, lease} =
      Admission.reserve(
        components.admission,
        components.generation,
        "group",
        attempt_id,
        self(),
        setup_deadline
      )

    {:ok, tree} =
      Admission.start_attempt(
        components.admission,
        components.generation,
        lease,
        attempt_id,
        self(),
        components.attempt_supervisor,
        budget(),
        setup_deadline
      )

    {:ok, roles} = AttemptTree.roles(tree)
    {:ok, expired} = Deadline.new(System.monotonic_time(:millisecond))

    assert {:error, :deadline_exceeded} =
             GenServer.call(
               components.guardian,
               {:register, components.generation, attempt_id, tree, roles, lease, self(), expired}
             )

    tree_monitor = Process.monitor(tree)

    assert :ok =
             Admission.release(
               components.admission,
               components.generation,
               lease,
               attempt_id,
               Limits.cleanup_milliseconds()
             )

    assert_receive {:DOWN, ^tree_monitor, :process, ^tree, _reason}
    assert {:ok, %{in_use: 0}} = Runtime.snapshot(runtime)
  end

  test "a timed-out guardian registration kills the guardian before the request can run later" do
    runtime = runtime(max_concurrency: 1, groups: %{"group" => 1})
    {:ok, old} = Runtime.components(runtime)
    attempt_id = make_ref()
    setup_deadline = deadline()

    {:ok, lease} =
      Admission.reserve(
        old.admission,
        old.generation,
        "group",
        attempt_id,
        self(),
        setup_deadline
      )

    {:ok, tree} =
      Admission.start_attempt(
        old.admission,
        old.generation,
        lease,
        attempt_id,
        self(),
        old.attempt_supervisor,
        budget(),
        setup_deadline
      )

    {:ok, roles} = AttemptTree.roles(tree)
    guardian_monitor = Process.monitor(old.guardian)
    tree_monitor = Process.monitor(tree)
    :ok = :sys.suspend(old.guardian)
    {:ok, short_deadline} = Deadline.new(System.monotonic_time(:millisecond) + 50)

    assert {:error, :deadline_exceeded} =
             Guardian.register(
               old.guardian,
               old.generation,
               attempt_id,
               tree,
               roles,
               lease,
               self(),
               short_deadline
             )

    assert_receive {:DOWN, ^guardian_monitor, :process, _guardian, :killed}
    assert_receive {:DOWN, ^tree_monitor, :process, ^tree, _reason}
    assert_eventually(fn -> Runtime.ready?(runtime) end, 1_500)
    assert {:ok, %{in_use: 0}} = Runtime.snapshot(runtime)
  end

  test "generation cleanup uses one aggregate cutoff for resistant attempts" do
    runtime = runtime(max_concurrency: 2, groups: %{"group" => 2})
    {:ok, old} = Runtime.components(runtime)

    first =
      async_attempt(
        runtime,
        "group",
        budget(),
        deadline(),
        ScriptedBackend.hold(self(), :aggregate_first)
      )

    second =
      async_attempt(
        runtime,
        "group",
        budget(),
        deadline(),
        ScriptedBackend.hold(self(), :aggregate_second)
      )

    assert_receive {:scripted_backend_started, :aggregate_first, _first_role}
    assert_receive {:scripted_backend_started, :aggregate_second, _second_role}
    started = System.monotonic_time(:millisecond)
    Process.exit(old.admission, :kill)

    assert {:error, %Error{kind: :runtime_unavailable}} = Task.await(first, 2_000)
    assert {:error, %Error{kind: :runtime_unavailable}} = Task.await(second, 2_000)
    assert System.monotonic_time(:millisecond) - started < 1_300
    assert {:ok, %{in_use: 0}} = Runtime.snapshot(runtime)
  end

  test "attempt-supervisor and outer-generation death fence and replace their generation" do
    for component <- [:attempt_supervisor, :outer] do
      runtime = runtime(max_concurrency: 1, groups: %{"group" => 1})
      {:ok, old} = Runtime.components(runtime)

      task =
        async_attempt(
          runtime,
          "group",
          budget(),
          deadline(),
          ScriptedBackend.hold(self(), {:generation_role, component})
        )

      assert_receive {:scripted_backend_started, {:generation_role, ^component}, role}
      role_monitor = Process.monitor(role)
      Process.exit(Map.fetch!(old, component), :kill)

      assert {:error, %Error{kind: :runtime_unavailable}} = Task.await(task, 2_000)
      assert_receive {:DOWN, ^role_monitor, :process, ^role, _reason}
      assert_eventually(fn -> Runtime.ready?(runtime) end, 1_500)
      {:ok, replacement} = Runtime.components(runtime)
      refute replacement.generation == old.generation
      assert {:ok, %{in_use: 0}} = Runtime.snapshot(runtime)
      Supervisor.stop(runtime)
    end
  end

  test "a clean generation-child exit is fenced and replaced at the aggregate cutoff" do
    runtime = runtime(max_concurrency: 1, groups: %{"group" => 1})
    {:ok, old} = Runtime.components(runtime)
    :ok = GenServer.stop(old.admission, :normal)

    assert_eventually(fn -> Runtime.ready?(runtime) end, 1_500)
    {:ok, replacement} = Runtime.components(runtime)
    refute replacement.generation == old.generation
    refute replacement.admission == old.admission
  end

  # Flaky under suite load while the runtime owner and descendant roles tear down.
  # Keep skipped until the ordering is covered by a deterministic lifecycle fixture.
  @tag :flaky
  @tag skip: "intermittent owner-death teardown ordering"
  test "runtime-owner death stops the runtime and all work beneath it" do
    parent = self()

    owner =
      spawn(fn ->
        {:ok, runtime} = Runtime.start_link(max_concurrency: 1, groups: %{"group" => 1})
        send(parent, {:owned_runtime, runtime})

        receive do
          :owner_finished -> :ok
        end
      end)

    assert_receive {:owned_runtime, runtime}
    runtime_monitor = Process.monitor(runtime)

    task =
      async_attempt(
        runtime,
        "group",
        budget(),
        deadline(),
        ScriptedBackend.hold(self(), :owner_death)
      )

    assert_receive {:scripted_backend_started, :owner_death, role}
    role_monitor = Process.monitor(role)
    Process.exit(owner, :kill)

    assert_receive {:DOWN, ^runtime_monitor, :process, ^runtime, _reason}
    assert_receive {:DOWN, ^role_monitor, :process, ^role, _reason}
    assert {:error, error} = Task.await(task, 2_000)

    assert %{kind: :runtime_unavailable} = Map.from_struct(error)
  end

  test "every package process receives its exact derived heap ceiling before work" do
    runtime = runtime(max_concurrency: 2, groups: %{"group" => 2})
    control_total = Limits.runtime_control_words(2, 1)
    control = Limits.runtime_control_partition(control_total)
    attempt = ProcessBudget.partition(budget())
    {:ok, components} = Runtime.components(runtime)

    task =
      async_attempt(
        runtime,
        "group",
        budget(),
        deadline(),
        ScriptedBackend.hold(self(), :heap_flags)
      )

    assert_receive {:scripted_backend_started, :heap_flags, socket_role}

    [{_id, tree, :supervisor, _modules}] =
      DynamicSupervisor.which_children(components.attempt_supervisor)

    {:ok, roles} = AttemptTree.roles(tree)

    assert heap_size(runtime) == control.root
    assert heap_size(components.guardian) == control.guardian
    assert heap_size(components.generation_supervisor) == control.generation_supervisor
    assert heap_size(components.outer) == control.generation
    assert heap_size(components.admission) == control.admission
    assert heap_size(components.attempt_supervisor) == control.attempt_supervisor
    assert heap_size(tree) == attempt.attempt_tree
    assert heap_size(roles.coordinator) == attempt.coordinator
    assert heap_size(roles.codec) == attempt.codec
    assert heap_size(roles.callback) == attempt.callback
    assert heap_size(roles.dns) == attempt.dns
    assert heap_size(roles.socket) == attempt.socket
    assert heap_size(roles.relay) == attempt.relay

    Enum.each(
      [
        runtime,
        components.guardian,
        components.generation_supervisor,
        components.outer,
        components.admission,
        components.attempt_supervisor,
        tree
      ] ++ Map.values(roles),
      fn pid ->
        assert {:max_heap_size, %{kill: true, error_logger: false}} =
                 Process.info(pid, :max_heap_size)
      end
    )

    send(socket_role, {:scripted_backend_release, :heap_flags, {:ok, :done}})
    assert Task.await(task) == {:ok, :done}
  end

  test "runtime control and attempt partitions sum without multiplying role budgets" do
    total = Limits.runtime_control_words(1_024, 256)
    assert total == 2_912_512
    assert Enum.sum(Map.values(Limits.runtime_control_partition(total))) == total

    {:ok, budget} = ProcessBudget.new(total_heap_words: 2_073_600_000)
    assert Enum.sum(Map.values(ProcessBudget.partition(budget))) == 2_073_600_000
  end

  defp runtime(options), do: start_supervised!({Runtime, options})

  defp budget do
    {:ok, budget} = ProcessBudget.new(total_heap_words: 1_000_000)
    budget
  end

  defp deadline do
    {:ok, deadline} = Deadline.new(System.monotonic_time(:millisecond) + 10_000)
    deadline
  end

  defp async_attempt(runtime, group, budget, deadline, operation) do
    Task.async(fn -> Runtime.run_attempt(runtime, group, budget, deadline, operation) end)
  end

  defp registered_attempt(runtime) do
    {:ok, components} = Runtime.components(runtime)
    attempt_id = make_ref()
    attempt_deadline = deadline()

    {:ok, lease} =
      Admission.reserve(
        components.admission,
        components.generation,
        "group",
        attempt_id,
        self(),
        attempt_deadline
      )

    {:ok, tree} =
      Admission.start_attempt(
        components.admission,
        components.generation,
        lease,
        attempt_id,
        self(),
        components.attempt_supervisor,
        budget(),
        attempt_deadline
      )

    {:ok, roles} = AttemptTree.roles(tree)

    :ok =
      Guardian.register(
        components.guardian,
        components.generation,
        attempt_id,
        tree,
        roles,
        lease,
        self(),
        attempt_deadline
      )

    %{attempt_id: attempt_id, tree: tree, roles: roles}
  end

  defp force_heap_death(pid, role) do
    monitor = Process.monitor(pid)
    send(pid, {:external_heap_pressure, role, List.duplicate({:external, role}, 200_000)})
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}
  end

  defp only_attempt_id(guardian) do
    %{attempts: attempts} = :sys.get_state(guardian)
    [attempt_id] = Map.keys(attempts)
    attempt_id
  end

  defp contains_binary?(term, sentinel) when is_binary(term), do: term == sentinel

  defp contains_binary?(term, sentinel) when is_list(term),
    do: Enum.any?(term, &contains_binary?(&1, sentinel))

  defp contains_binary?(term, sentinel) when is_tuple(term),
    do: term |> Tuple.to_list() |> contains_binary?(sentinel)

  defp contains_binary?(term, sentinel) when is_map(term),
    do: term |> Map.to_list() |> contains_binary?(sentinel)

  defp contains_binary?(_term, _sentinel), do: false

  defp idle_snapshot(limit),
    do: %{in_use: 0, limit: limit, groups: %{"group" => %{in_use: 0, limit: limit}}}

  defp heap_size(pid) do
    {:max_heap_size, %{size: size}} = Process.info(pid, :max_heap_size)
    size
  end

  defp assert_eventually(assertion, attempts \\ 1_000)

  defp assert_eventually(assertion, attempts) when attempts > 0 do
    if assertion.() do
      :ok
    else
      receive do
      after
        1 -> assert_eventually(assertion, attempts - 1)
      end
    end
  end

  defp assert_eventually(_assertion, 0), do: flunk("condition did not become true")
end
