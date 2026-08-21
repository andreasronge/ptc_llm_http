defmodule PtcLlmHttp.Runtime do
  @moduledoc """
  Fail-fast physical-attempt admission and ownership runtime.

  Each runtime is an independent capacity domain. Global and per-group limits
  are reserved atomically, and a reservation is released only after the
  guardian has observed the complete attempt tree go down. Runtime generation
  failure fences old counters instead of resetting them under surviving work.
  """

  alias PtcLlmHttp.{Deadline, Error, Limits, ProcessBudget, Target}

  alias PtcLlmHttp.Runtime.{
    Admission,
    AttemptSupervisor,
    AttemptTree,
    Coordinator,
    Generation,
    GenerationSupervisor,
    Guardian,
    Root
  }

  @maximum_concurrency Limits.max_concurrency()
  @maximum_groups Limits.max_groups()

  @type t :: pid()
  @type option :: {:max_concurrency, pos_integer()} | {:groups, %{binary() => pos_integer()}}

  @doc "Starts an independent physical-connection capacity domain linked to its owner."
  @spec start_link([option()]) :: {:ok, t()} | {:error, Error.t()}
  def start_link(options) do
    with {:ok, config} <- validate_options(options),
         {:ok, root} <- start_root(config) do
      case runtime_components(root) do
        {:ok, _components} ->
          {:ok, root}

        {:error, _reason} ->
          _stopped = Supervisor.stop(root)
          {:error, runtime_error()}
      end
    end
  end

  @doc false
  def child_spec(options) do
    %{
      id: {__MODULE__, make_ref()},
      start: {__MODULE__, :start_link, [options]},
      restart: :temporary,
      shutdown: Limits.cleanup_milliseconds(),
      type: :supervisor
    }
  end

  @doc "Returns whether the current runtime generation is ready to admit."
  @spec ready?(t()) :: boolean()
  def ready?(runtime) when is_pid(runtime) do
    case runtime_components(runtime) do
      {:ok, %{guardian: guardian}} -> Guardian.status(guardian) == :ready
      {:error, _reason} -> false
    end
  end

  def ready?(_runtime), do: false

  @doc "Returns a bounded global and per-group admission counter snapshot."
  @spec snapshot(t()) :: {:ok, map()} | {:error, Error.t()}
  def snapshot(runtime) when is_pid(runtime) do
    with {:ok, components} <- runtime_components(runtime),
         {:ok, snapshot} <- Admission.snapshot(components.admission, components.generation) do
      {:ok, snapshot}
    else
      _unavailable -> {:error, runtime_error()}
    end
  end

  def snapshot(_runtime), do: {:error, runtime_error()}

  @doc false
  @spec run_attempt(
          t(),
          binary(),
          ProcessBudget.t(),
          Deadline.t(),
          (-> {:ok, term()} | {:error, Error.t()})
        ) :: {:ok, term()} | {:error, Error.t()}
  def run_attempt(runtime, group, budget, deadline, operation)
      when is_pid(runtime) and is_binary(group) and is_function(operation, 0) do
    run_owned_attempt(runtime, group, budget, deadline, operation)
  end

  def run_attempt(_runtime, _group, _budget, _deadline, _operation),
    do: {:error, Error.build!(:invalid_request, :validate, :request, :not_sent)}

  @doc false
  @spec run_http(t(), Target.t(), ProcessBudget.t(), Deadline.t(), {:http, map()}) ::
          {:ok, term()} | {:halted, term()} | {:error, Error.t()}
  def run_http(runtime, target, budget, deadline, {:http, spec})
      when is_pid(runtime) and is_map(spec) do
    operation = {:http, Map.put(spec, :deadline, deadline)}
    run_owned_attempt(runtime, Target.capacity_group(target), budget, deadline, operation)
  end

  def run_http(_runtime, _target, _budget, _deadline, _operation),
    do: {:error, Error.build!(:invalid_request, :validate, :request, :not_sent)}

  defp run_owned_attempt(runtime, group, budget, deadline, operation) do
    with {:ok, budget} <- ProcessBudget.validate(budget),
         {:ok, deadline} <- Deadline.validate(deadline),
         {:ok, _remaining} <- Deadline.remaining(deadline),
         {:ok, components} <- runtime_components(runtime),
         {:ok, _remaining} <- Deadline.remaining(deadline) do
      attempt_id = make_ref()

      case Admission.reserve(
             components.admission,
             components.generation,
             group,
             attempt_id,
             self(),
             deadline
           ) do
        {:ok, lease} -> launch_attempt(components, attempt_id, lease, budget, deadline, operation)
        {:error, :capacity_exhausted} -> {:error, capacity_error()}
        {:error, :unknown_group} -> {:error, capacity_error()}
        {:error, :deadline_exceeded} -> {:error, admission_deadline_error()}
        {:error, _unavailable} -> {:error, runtime_error()}
      end
    else
      :error -> {:error, Error.build!(:invalid_request, :validate, :request, :not_sent)}
      {:error, :runtime_unavailable} -> {:error, runtime_error()}
      {:error, error} -> {:error, error}
    end
  end

  @doc false
  def components(runtime), do: runtime_components(runtime)

  defp launch_attempt(components, attempt_id, lease, budget, deadline, operation) do
    case Admission.start_attempt(
           components.admission,
           components.generation,
           lease,
           attempt_id,
           self(),
           components.attempt_supervisor,
           budget,
           deadline
         ) do
      {:ok, tree} ->
        prepare_attempt(components, attempt_id, lease, tree, deadline, operation)

      {:error, reason} ->
        release_unregistered(components, attempt_id, lease)
        startup_error(reason)
    end
  end

  defp prepare_attempt(components, attempt_id, lease, tree, deadline, operation) do
    with {:ok, roles} <- AttemptTree.roles(tree),
         :ok <-
           Guardian.register(
             components.guardian,
             components.generation,
             attempt_id,
             tree,
             roles,
             lease,
             self(),
             deadline
           ) do
      case bind_coordinator(roles, components, attempt_id, deadline) do
        :ok ->
          Coordinator.execute(roles.coordinator, operation)
          await_attempt(components.guardian, tree, roles.coordinator, attempt_id)

        {:error, _reason} ->
          Guardian.cause(
            components.guardian,
            components.generation,
            attempt_id,
            :internal_failure
          )

          await_attempt(components.guardian, tree, roles.coordinator, attempt_id)
      end
    else
      {:error, reason} ->
        terminate_unregistered(components, tree)
        release_unregistered(components, attempt_id, lease)

        startup_error(reason)
    end
  end

  defp validate_options(options) when is_list(options) do
    if Keyword.keyword?(options) and length(options) == 2 and
         Enum.sort(Keyword.keys(options)) == [:groups, :max_concurrency] do
      validate_configuration(
        Keyword.fetch!(options, :max_concurrency),
        Keyword.fetch!(options, :groups)
      )
    else
      invalid_options()
    end
  end

  defp validate_options(_options), do: invalid_options()

  defp validate_configuration(maximum, groups)
       when is_integer(maximum) and maximum > 0 and maximum <= @maximum_concurrency and
              is_map(groups) and map_size(groups) <= @maximum_groups do
    if Enum.all?(groups, &valid_group?(&1, maximum)) do
      control_words = Limits.runtime_control_words(maximum, map_size(groups))

      {:ok,
       %{
         max_concurrency: maximum,
         groups: groups,
         control_partition: Limits.runtime_control_partition(control_words)
       }}
    else
      invalid_options()
    end
  end

  defp validate_configuration(_maximum, _groups), do: invalid_options()

  defp valid_group?({group, limit}, maximum) do
    is_binary(group) and byte_size(group) > 0 and
      byte_size(group) <= Limits.capacity_group_bytes() and String.valid?(group) and
      Enum.all?(:binary.bin_to_list(group), &(&1 > 31 and &1 != 127)) and is_integer(limit) and
      limit > 0 and limit <= maximum
  end

  defp invalid_options,
    do: {:error, Error.build!(:invalid_request, :validate, :request, :not_sent)}

  defp start_root(config) do
    case Root.start_link(config, self()) do
      {:ok, root} -> {:ok, root}
      {:error, _reason} -> {:error, runtime_error()}
    end
  end

  defp runtime_components(runtime) do
    with {:ok, guardian, generation_supervisor} <- root_children(runtime),
         {:ok, config} <- guardian_config(guardian),
         {:ok, outer} <- GenerationSupervisor.ensure_generation(generation_supervisor, config),
         {:ok, generation} <- Generation.components(outer),
         :ok <- Guardian.bind(guardian, generation_supervisor, outer, generation) do
      {:ok,
       Map.merge(generation, %{
         guardian: guardian,
         generation_supervisor: generation_supervisor,
         outer: outer
       })}
    else
      _unavailable -> {:error, :runtime_unavailable}
    end
  end

  defp guardian_config(guardian) do
    GenServer.call(guardian, :config, 5_000)
  catch
    :exit, _guardian_gone -> {:error, :runtime_unavailable}
  end

  defp root_children(root) do
    children = Supervisor.which_children(root)

    with {Guardian, guardian, :worker, _modules} when is_pid(guardian) <-
           List.keyfind(children, Guardian, 0),
         {GenerationSupervisor, generation_supervisor, :supervisor, _modules}
         when is_pid(generation_supervisor) <- List.keyfind(children, GenerationSupervisor, 0) do
      {:ok, guardian, generation_supervisor}
    else
      _missing -> {:error, :runtime_unavailable}
    end
  catch
    :exit, _root_gone -> {:error, :runtime_unavailable}
  end

  defp bind_coordinator(roles, components, attempt_id, deadline) do
    Coordinator.bind(roles.coordinator, %{
      guardian: components.guardian,
      generation: components.generation,
      attempt_id: attempt_id,
      caller: self(),
      deadline: deadline,
      roles: roles
    })
  catch
    :exit, _coordinator_gone -> {:error, :coordinator_unavailable}
  end

  defp terminate_unregistered(components, tree) do
    _result = AttemptSupervisor.terminate_attempt(components.attempt_supervisor, tree)
    :ok
  end

  defp release_unregistered(components, attempt_id, lease) do
    _result =
      Admission.release(
        components.admission,
        components.generation,
        lease,
        attempt_id,
        Limits.cleanup_milliseconds()
      )

    :ok
  end

  defp await_attempt(guardian, tree, coordinator, attempt_id) do
    guardian_monitor = Process.monitor(guardian)
    tree_monitor = Process.monitor(tree)
    coordinator_monitor = Process.monitor(coordinator)

    await_attempt(
      attempt_id,
      guardian_monitor,
      tree_monitor,
      coordinator_monitor,
      nil,
      false,
      false,
      {:admission, :not_sent}
    )
  end

  defp await_attempt(
         attempt_id,
         guardian_monitor,
         tree_monitor,
         coordinator_monitor,
         candidate,
         tree_down?,
         coordinator_down?,
         progress
       ) do
    receive do
      {:ptc_llm_http_progress, ^attempt_id, phase, dispatch} ->
        await_attempt(
          attempt_id,
          guardian_monitor,
          tree_monitor,
          coordinator_monitor,
          candidate,
          tree_down?,
          coordinator_down?,
          {phase, dispatch}
        )

      {:ptc_llm_http_candidate, ^attempt_id, delivery_ref, value, relay} ->
        send(relay, {:ptc_llm_http_candidate_ack, delivery_ref})

        await_attempt(
          attempt_id,
          guardian_monitor,
          tree_monitor,
          coordinator_monitor,
          {delivery_ref, value},
          tree_down?,
          coordinator_down?,
          progress
        )

      {:ptc_llm_http_decision, ^attempt_id, delivery_ref, :commit} ->
        _progress =
          settle_attempt_messages(
            attempt_id,
            tree_monitor,
            coordinator_monitor,
            tree_down?,
            coordinator_down?,
            progress,
            System.monotonic_time(:millisecond) + Limits.cleanup_milliseconds()
          )

        case candidate do
          {^delivery_ref, value} ->
            demonitor(guardian_monitor)
            demonitor(tree_monitor)
            demonitor(coordinator_monitor)
            value

          _missing_candidate ->
            demonitor(guardian_monitor)
            demonitor(tree_monitor)
            demonitor(coordinator_monitor)
            {:error, internal_error()}
        end

      {:ptc_llm_http_decision, ^attempt_id, _delivery_ref, {:discard, cause, phase, dispatch}} ->
        _progress =
          settle_attempt_messages(
            attempt_id,
            tree_monitor,
            coordinator_monitor,
            tree_down?,
            coordinator_down?,
            progress,
            System.monotonic_time(:millisecond) + Limits.cleanup_milliseconds()
          )

        demonitor(guardian_monitor)
        demonitor(tree_monitor)
        demonitor(coordinator_monitor)
        {:error, cause_error(cause, phase, dispatch)}

      {:DOWN, ^tree_monitor, :process, _tree, _reason} ->
        await_attempt(
          attempt_id,
          guardian_monitor,
          tree_monitor,
          coordinator_monitor,
          candidate,
          true,
          coordinator_down?,
          progress
        )

      {:DOWN, ^coordinator_monitor, :process, _coordinator, _reason} ->
        await_attempt(
          attempt_id,
          guardian_monitor,
          tree_monitor,
          coordinator_monitor,
          candidate,
          tree_down?,
          true,
          progress
        )

      {:DOWN, ^guardian_monitor, :process, _guardian, _reason} ->
        {phase, dispatch} =
          settle_attempt_messages(
            attempt_id,
            tree_monitor,
            coordinator_monitor,
            tree_down?,
            coordinator_down?,
            progress,
            System.monotonic_time(:millisecond) + Limits.cleanup_milliseconds()
          )

        demonitor(tree_monitor)
        demonitor(coordinator_monitor)
        {:error, runtime_error(phase, dispatch)}
    end
  end

  defp settle_attempt_messages(
         attempt_id,
         _tree_monitor,
         _coordinator_monitor,
         true,
         true,
         progress,
         _cleanup_deadline
       ),
       do: drain_progress(attempt_id, progress)

  defp settle_attempt_messages(
         attempt_id,
         tree_monitor,
         coordinator_monitor,
         tree_down?,
         coordinator_down?,
         progress,
         cleanup_deadline
       ) do
    remaining = max(cleanup_deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:ptc_llm_http_progress, ^attempt_id, phase, dispatch} ->
        settle_attempt_messages(
          attempt_id,
          tree_monitor,
          coordinator_monitor,
          tree_down?,
          coordinator_down?,
          {phase, dispatch},
          cleanup_deadline
        )

      {:DOWN, ^tree_monitor, :process, _tree, _reason} ->
        settle_attempt_messages(
          attempt_id,
          tree_monitor,
          coordinator_monitor,
          true,
          coordinator_down?,
          progress,
          cleanup_deadline
        )

      {:DOWN, ^coordinator_monitor, :process, _coordinator, _reason} ->
        settle_attempt_messages(
          attempt_id,
          tree_monitor,
          coordinator_monitor,
          tree_down?,
          true,
          progress,
          cleanup_deadline
        )
    after
      remaining -> progress
    end
  end

  defp drain_progress(attempt_id, progress) do
    receive do
      {:ptc_llm_http_progress, ^attempt_id, phase, dispatch} ->
        drain_progress(attempt_id, {phase, dispatch})
    after
      0 -> progress
    end
  end

  defp demonitor(reference) do
    Process.demonitor(reference, [:flush])
    :ok
  end

  defp cause_error(:runtime_shutdown, phase, dispatch), do: runtime_error(phase, dispatch)

  defp cause_error(:deadline_exceeded, phase, dispatch),
    do: Error.build!(:deadline_exceeded, phase, :transport, dispatch)

  defp cause_error(:callback_misuse, _phase, _dispatch),
    do: Error.build!(:callback_failed, :stream, :provider, :possibly_sent)

  defp cause_error(:resource_limit, phase, dispatch),
    do: Error.build!(:resource_limit_exceeded, phase, :capacity, dispatch)

  defp cause_error(:consumer_halted, phase, dispatch), do: internal_error(phase, dispatch)
  defp cause_error(:internal_failure, phase, dispatch), do: internal_error(phase, dispatch)
  defp cause_error(:caller_cancelled, phase, dispatch), do: internal_error(phase, dispatch)

  defp capacity_error,
    do: Error.build!(:capacity_exhausted, :admission, :capacity, :not_sent)

  defp startup_error(:deadline_exceeded), do: {:error, admission_deadline_error()}
  defp startup_error(_reason), do: {:error, runtime_error()}

  defp admission_deadline_error,
    do: Error.build!(:deadline_exceeded, :admission, :transport, :not_sent)

  defp runtime_error,
    do: Error.build!(:runtime_unavailable, :admission, :capacity, :not_sent)

  defp runtime_error(phase, dispatch),
    do: Error.build!(:runtime_unavailable, phase, :capacity, dispatch)

  defp internal_error,
    do: Error.build!(:internal_failure, :admission, :transport, :not_sent)

  defp internal_error(phase, dispatch),
    do: Error.build!(:internal_failure, phase, :transport, dispatch)
end
