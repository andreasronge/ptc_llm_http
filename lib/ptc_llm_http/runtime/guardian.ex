defmodule PtcLlmHttp.Runtime.Guardian do
  @moduledoc false

  use GenServer

  alias PtcLlmHttp.{Deadline, Limits}
  alias PtcLlmHttp.Runtime.{Admission, Generation, GenerationSupervisor}

  @causes [
    :runtime_shutdown,
    :caller_cancelled,
    :deadline_exceeded,
    :consumer_halted,
    :callback_misuse,
    :resource_limit,
    :internal_failure
  ]

  def start_link({config, owner}), do: GenServer.start_link(__MODULE__, {config, owner})

  @impl GenServer
  def init({config, owner}) do
    :ok = Limits.set_max_heap(config.control_partition.guardian)
    owner_ref = Process.monitor(owner)

    {:ok,
     %{
       config: config,
       owner: owner,
       owner_ref: owner_ref,
       generation: nil,
       attempts: %{},
       monitor_index: %{}
     }}
  end

  def bind(guardian, generation_supervisor, outer, components) do
    mutating_call(
      guardian,
      {:bind, generation_supervisor, outer, components},
      Limits.cleanup_milliseconds()
    )
  end

  def status(guardian), do: read_call(guardian, :status)

  def register(guardian, generation, attempt_id, tree, roles, lease, caller, deadline) do
    case Deadline.remaining(deadline) do
      {:ok, timeout} ->
        deadline_call(
          guardian,
          {:register, generation, attempt_id, tree, roles, lease, caller, deadline},
          min(timeout, Limits.maximum_timer_milliseconds())
        )

      {:error, _deadline} ->
        {:error, :deadline_exceeded}
    end
  end

  def candidate(guardian, generation, attempt_id, deadline, delivery_ref, category)
      when category in [:success, :classified] do
    mutating_call(
      guardian,
      {:candidate, generation, attempt_id, deadline, delivery_ref, category},
      Limits.cleanup_milliseconds()
    )
  end

  def cause(guardian, generation, attempt_id, cause) when cause in @causes,
    do:
      mutating_call(
        guardian,
        {:cause, generation, attempt_id, cause},
        Limits.cleanup_milliseconds()
      )

  def progress(guardian, generation, attempt_id, phase, dispatch)
      when phase in [
             :admission,
             :dns,
             :connect,
             :tls,
             :send,
             :receive_head,
             :receive_body
           ] and dispatch in [:not_sent, :possibly_sent, :completed] do
    mutating_call(
      guardian,
      {:progress, generation, attempt_id, phase, dispatch},
      Limits.cleanup_milliseconds()
    )
  end

  def progress_until(guardian, generation, attempt_id, phase, dispatch, timeout)
      when phase in [
             :admission,
             :dns,
             :connect,
             :tls,
             :send,
             :receive_head,
             :receive_body
           ] and dispatch in [:not_sent, :possibly_sent, :completed] and is_integer(timeout) and
             timeout > 0 do
    progress_call(
      guardian,
      {:progress, generation, attempt_id, phase, dispatch},
      timeout
    )
  end

  @impl GenServer
  def handle_call({:bind, generation_supervisor, outer, components}, _from, state) do
    case state.generation do
      nil ->
        {:reply, :ok, publish_generation(state, generation_supervisor, outer, components)}

      %{id: id, phase: :ready} when id == components.generation ->
        {:reply, :ok, state}

      _fenced_or_different ->
        {:reply, {:error, :runtime_unavailable}, state}
    end
  end

  def handle_call(:status, _from, %{generation: %{phase: :ready}} = state),
    do: {:reply, :ready, state}

  def handle_call(:status, _from, state), do: {:reply, :unavailable, state}

  def handle_call(:config, _from, state), do: {:reply, {:ok, state.config}, state}

  def handle_call(
        {:register, generation, attempt_id, tree, roles, lease, caller, deadline},
        _from,
        %{generation: %{id: generation, phase: :ready}} = state
      ) do
    if valid_registration?(state, attempt_id, tree, roles, caller) do
      case Admission.adopt(state.generation.admission, generation, lease, attempt_id, deadline) do
        :ok -> register_attempt(state, attempt_id, tree, roles, lease, caller)
        {:error, :deadline_exceeded} -> {:reply, {:error, :deadline_exceeded}, state}
        {:error, _reason} -> {:reply, {:error, :registration_rejected}, state}
      end
    else
      {:reply, {:error, :registration_rejected}, state}
    end
  end

  def handle_call(
        {:register, _generation, _attempt_id, _tree, _roles, _lease, _caller, _deadline},
        _from,
        state
      ),
      do: {:reply, {:error, :runtime_unavailable}, state}

  def handle_call(
        {:candidate, generation, attempt_id, deadline, delivery_ref, category},
        _from,
        %{generation: %{id: generation}} = state
      ) do
    state =
      update_attempt(state, attempt_id, fn attempt ->
        attempt =
          case attempt.candidate do
            nil -> %{attempt | candidate: {delivery_ref, category}}
            _already_recorded -> attempt
          end

        case Deadline.remaining(deadline) do
          {:ok, _remaining} ->
            attempt

          {:error, _deadline} ->
            %{attempt | causes: MapSet.put(attempt.causes, :deadline_exceeded)}
        end
      end)

    {:reply, :ok, begin_cleanup(state, attempt_id)}
  end

  def handle_call(
        {:candidate, _generation, _attempt_id, _deadline, _delivery_ref, _category},
        _from,
        state
      ),
      do: {:reply, {:error, :runtime_unavailable}, state}

  def handle_call(
        {:cause, generation, attempt_id, cause},
        _from,
        %{generation: %{id: generation}} = state
      ) do
    state =
      update_attempt(state, attempt_id, fn attempt ->
        %{attempt | causes: MapSet.put(attempt.causes, cause)}
      end)

    {:reply, :ok, begin_cleanup(state, attempt_id)}
  end

  def handle_call({:cause, _generation, _attempt_id, _cause}, _from, state),
    do: {:reply, {:error, :runtime_unavailable}, state}

  def handle_call(
        {:progress, generation, attempt_id, phase, dispatch},
        _from,
        %{generation: %{id: generation, phase: :ready}} = state
      ) do
    case Map.fetch(state.attempts, attempt_id) do
      {:ok, %{cleanup_started: false} = attempt} ->
        attempt = %{attempt | phase: phase, dispatch: dispatch}
        {:reply, :ok, %{state | attempts: Map.put(state.attempts, attempt_id, attempt)}}

      _missing_or_terminal ->
        {:reply, {:error, :runtime_unavailable}, state}
    end
  end

  def handle_call({:progress, _generation, _attempt_id, _phase, _dispatch}, _from, state),
    do: {:reply, {:error, :runtime_unavailable}, state}

  @impl GenServer
  def handle_info({:attempt_brutal_cutoff, attempt_id}, state) do
    case Map.fetch(state.attempts, attempt_id) do
      {:ok, attempt} ->
        brutally_stop_attempt(attempt)
        {:noreply, state}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:cleanup_cutoff, attempt_id}, state) do
    case Map.fetch(state.attempts, attempt_id) do
      {:ok, %{refs: refs}} ->
        if MapSet.size(refs) > 0 do
          state = fence_generation(state)
          brutally_stop_generation(state)
          {:noreply, state}
        else
          {:noreply, state}
        end

      _finished ->
        {:noreply, state}
    end
  end

  def handle_info(
        {:generation_brutal_cutoff, generation},
        %{generation: %{id: generation, phase: :fenced}} = state
      ) do
    brutally_stop_generation(state)
    {:noreply, state}
  end

  def handle_info(
        {:generation_cleanup_cutoff, generation},
        %{generation: %{id: generation, phase: :fenced}} = state
      ) do
    brutally_stop_generation(state)
    {:noreply, state}
  end

  def handle_info(
        {:DOWN, owner_ref, :process, owner, _reason},
        %{owner: owner, owner_ref: owner_ref} = state
      ) do
    state = state |> Map.put(:owner_ref, nil) |> fence_generation()
    {:noreply, state}
  end

  def handle_info({:DOWN, monitor_ref, :process, _pid, reason}, state) do
    case Map.pop(state.monitor_index, monitor_ref) do
      {nil, _monitor_index} ->
        {:noreply, state}

      {{:generation, _role}, monitor_index} ->
        generation = %{state.generation | refs: MapSet.delete(state.generation.refs, monitor_ref)}
        state = %{state | generation: generation, monitor_index: monitor_index}
        state = fence_generation(state)
        {:noreply, maybe_replace_generation(state)}

      {{:attempt, attempt_id, role}, monitor_index} ->
        state = %{state | monitor_index: monitor_index}

        state =
          update_attempt(state, attempt_id, fn attempt ->
            attempt = %{attempt | refs: MapSet.delete(attempt.refs, monitor_ref)}
            classify_unplanned_down(attempt, role, reason)
          end)

        state = maybe_begin_after_down(state, attempt_id)
        state = maybe_stop_empty_tree(state, attempt_id)
        state = maybe_finalize_attempt(state, attempt_id)
        {:noreply, maybe_replace_generation(state)}

      {{:caller, attempt_id}, monitor_index} ->
        state = %{state | monitor_index: monitor_index}

        state =
          update_attempt(state, attempt_id, fn attempt ->
            %{attempt | causes: MapSet.put(attempt.causes, :caller_cancelled)}
          end)

        {:noreply, begin_cleanup(state, attempt_id)}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp register_attempt(state, attempt_id, tree, roles, lease, caller) do
    {refs, monitor_index} = monitor_attempt(state.monitor_index, attempt_id, tree, roles)
    caller_ref = Process.monitor(caller)
    monitor_index = Map.put(monitor_index, caller_ref, {:caller, attempt_id})

    attempt = %{
      tree: tree,
      roles: roles,
      lease: lease,
      caller: caller,
      caller_ref: caller_ref,
      refs: refs,
      causes: MapSet.new(),
      candidate: nil,
      phase: :admission,
      dispatch: :not_sent,
      cleanup_started: false,
      cleanup_deadline: nil,
      brutal_timer: nil,
      cleanup_timer: nil
    }

    {:reply, :ok,
     %{
       state
       | attempts: Map.put(state.attempts, attempt_id, attempt),
         monitor_index: monitor_index
     }}
  end

  defp valid_registration?(state, attempt_id, tree, roles, caller) do
    valid_roles?(roles) and is_pid(tree) and is_pid(caller) and Process.alive?(caller) and
      not Map.has_key?(state.attempts, attempt_id)
  end

  defp publish_generation(state, generation_supervisor, outer, components) do
    monitored = [
      {:outer, outer},
      {:admission, components.admission},
      {:attempt_supervisor, components.attempt_supervisor}
    ]

    {refs, monitor_index} =
      Enum.reduce(monitored, {MapSet.new(), state.monitor_index}, fn {role, pid}, {refs, index} ->
        ref = Process.monitor(pid)
        {MapSet.put(refs, ref), Map.put(index, ref, {:generation, role})}
      end)

    generation = %{
      id: components.generation,
      generation_supervisor: generation_supervisor,
      outer: outer,
      admission: components.admission,
      attempt_supervisor: components.attempt_supervisor,
      refs: refs,
      phase: :ready,
      brutal_timer: nil,
      cleanup_timer: nil
    }

    %{state | generation: generation, monitor_index: monitor_index}
  end

  defp monitor_attempt(monitor_index, attempt_id, tree, roles) do
    [{:tree, tree} | Map.to_list(roles)]
    |> Enum.reduce({MapSet.new(), monitor_index}, fn {role, pid}, {refs, index} ->
      ref = Process.monitor(pid)
      {MapSet.put(refs, ref), Map.put(index, ref, {:attempt, attempt_id, role})}
    end)
  end

  defp valid_roles?(roles) when is_map(roles) and map_size(roles) == 6 do
    Enum.sort(Map.keys(roles)) ==
      Enum.sort([:coordinator, :codec, :callback, :dns, :socket, :relay]) and
      Enum.all?(roles, fn {_role, pid} -> is_pid(pid) end)
  end

  defp valid_roles?(_roles), do: false

  defp update_attempt(state, attempt_id, update) do
    case Map.fetch(state.attempts, attempt_id) do
      {:ok, attempt} -> %{state | attempts: Map.put(state.attempts, attempt_id, update.(attempt))}
      :error -> state
    end
  end

  defp begin_cleanup(state, attempt_id) do
    case Map.fetch(state.attempts, attempt_id) do
      {:ok, %{cleanup_started: false} = attempt} ->
        cleanup_deadline = System.monotonic_time(:millisecond) + Limits.cleanup_milliseconds()

        brutal_timer =
          Process.send_after(
            self(),
            {:attempt_brutal_cutoff, attempt_id},
            Limits.cooperative_cleanup_milliseconds()
          )

        cleanup_timer =
          Process.send_after(self(), {:cleanup_cutoff, attempt_id}, Limits.cleanup_milliseconds())

        state =
          update_attempt(state, attempt_id, fn _old ->
            %{
              attempt
              | cleanup_started: true,
                cleanup_deadline: cleanup_deadline,
                brutal_timer: brutal_timer,
                cleanup_timer: cleanup_timer
            }
          end)

        signal_attempt_cleanup(attempt)
        state

      _already_started_or_missing ->
        state
    end
  end

  defp maybe_begin_after_down(state, attempt_id) do
    case Map.fetch(state.attempts, attempt_id) do
      {:ok, %{cleanup_started: false}} -> begin_cleanup(state, attempt_id)
      _started_or_missing -> state
    end
  end

  defp maybe_stop_empty_tree(state, attempt_id) do
    case Map.fetch(state.attempts, attempt_id) do
      {:ok, %{cleanup_started: true} = attempt} ->
        if Enum.all?(attempt.roles, fn {_role, pid} -> not Process.alive?(pid) end) do
          brutally_stop_attempt(attempt)
        end

        state

      _active_or_missing ->
        state
    end
  end

  defp classify_unplanned_down(%{cleanup_started: true} = attempt, _role, _reason), do: attempt

  defp classify_unplanned_down(attempt, role, reason) do
    cause =
      cond do
        reason == :killed -> :resource_limit
        role == :callback -> :callback_misuse
        true -> :internal_failure
      end

    %{attempt | causes: MapSet.put(attempt.causes, cause)}
  end

  defp maybe_finalize_attempt(state, attempt_id) do
    case Map.fetch(state.attempts, attempt_id) do
      {:ok, %{refs: refs}} ->
        if MapSet.size(refs) == 0, do: finalize_attempt(state, attempt_id), else: state

      _active_or_missing ->
        state
    end
  end

  defp finalize_attempt(state, attempt_id) do
    attempt = Map.fetch!(state.attempts, attempt_id)
    cancel_timer(attempt.brutal_timer)
    cancel_timer(attempt.cleanup_timer)
    Process.demonitor(attempt.caller_ref, [:flush])
    state = %{state | monitor_index: Map.delete(state.monitor_index, attempt.caller_ref)}

    attempt =
      if Process.alive?(attempt.caller) do
        attempt
      else
        %{attempt | causes: MapSet.put(attempt.causes, :caller_cancelled)}
      end

    outcome = choose_outcome(attempt)
    {outcome, state} = release_if_allowed(outcome, state, attempt_id, attempt)
    notify_caller(attempt_id, attempt, outcome)
    %{state | attempts: Map.delete(state.attempts, attempt_id)}
  end

  defp release_if_allowed({:discard, :runtime_shutdown} = outcome, state, _attempt_id, _attempt),
    do: {outcome, state}

  defp release_if_allowed(outcome, %{generation: %{phase: :ready}} = state, attempt_id, attempt) do
    timeout = max(attempt.cleanup_deadline - System.monotonic_time(:millisecond), 1)

    case Admission.release(
           state.generation.admission,
           state.generation.id,
           attempt.lease,
           attempt_id,
           timeout
         ) do
      :ok ->
        {outcome, state}

      {:error, _unavailable} ->
        state = fence_generation(state)
        brutally_stop_generation(state)
        {{:discard, :runtime_shutdown}, state}
    end
  end

  defp release_if_allowed(_outcome, state, _attempt_id, _attempt),
    do: {{:discard, :runtime_shutdown}, state}

  defp choose_outcome(attempt) do
    causes = attempt.causes

    cond do
      MapSet.member?(causes, :runtime_shutdown) -> {:discard, :runtime_shutdown}
      MapSet.member?(causes, :caller_cancelled) -> :caller_cancelled
      MapSet.member?(causes, :deadline_exceeded) -> {:discard, :deadline_exceeded}
      MapSet.member?(causes, :consumer_halted) -> {:discard, :consumer_halted}
      MapSet.member?(causes, :callback_misuse) -> {:discard, :callback_misuse}
      MapSet.member?(causes, :resource_limit) -> {:discard, :resource_limit}
      match?({_ref, :classified}, attempt.candidate) -> {:commit, elem(attempt.candidate, 0)}
      MapSet.member?(causes, :internal_failure) -> {:discard, :internal_failure}
      match?({_ref, :success}, attempt.candidate) -> {:commit, elem(attempt.candidate, 0)}
      true -> {:discard, :internal_failure}
    end
  end

  defp notify_caller(_attempt_id, _attempt, :caller_cancelled), do: :ok

  defp notify_caller(attempt_id, attempt, {:commit, delivery_ref}) do
    send(attempt.caller, {:ptc_llm_http_decision, attempt_id, delivery_ref, :commit})
  end

  defp notify_caller(attempt_id, attempt, {:discard, cause}) do
    delivery_ref = if attempt.candidate, do: elem(attempt.candidate, 0), else: nil

    send(
      attempt.caller,
      {:ptc_llm_http_decision, attempt_id, delivery_ref,
       {:discard, cause, attempt.phase, attempt.dispatch}}
    )
  end

  defp fence_generation(%{generation: nil} = state), do: state
  defp fence_generation(%{generation: %{phase: :fenced}} = state), do: state

  defp fence_generation(state) do
    generation_id = state.generation.id

    brutal_timer =
      Process.send_after(
        self(),
        {:generation_brutal_cutoff, generation_id},
        Limits.cooperative_cleanup_milliseconds()
      )

    cleanup_timer =
      Process.send_after(
        self(),
        {:generation_cleanup_cutoff, generation_id},
        Limits.cleanup_milliseconds()
      )

    generation = %{
      state.generation
      | phase: :fenced,
        brutal_timer: brutal_timer,
        cleanup_timer: cleanup_timer
    }

    Enum.reduce(Map.keys(state.attempts), %{state | generation: generation}, fn attempt_id,
                                                                                current ->
      current
      |> update_attempt(attempt_id, fn attempt ->
        %{attempt | causes: MapSet.put(attempt.causes, :runtime_shutdown)}
      end)
      |> begin_cleanup(attempt_id)
    end)
  end

  defp brutally_stop_generation(%{generation: nil}), do: :ok

  defp brutally_stop_generation(state) do
    if Process.alive?(state.generation.outer), do: Process.exit(state.generation.outer, :kill)
    :ok
  end

  defp signal_attempt_cleanup(attempt) do
    Enum.each(attempt.roles, fn {_role, pid} -> send(pid, :ptc_llm_http_cleanup) end)
    :ok
  end

  defp brutally_stop_attempt(attempt) do
    if Process.alive?(attempt.tree), do: Process.exit(attempt.tree, :kill)
    :ok
  end

  defp maybe_replace_generation(
         %{generation: %{phase: :fenced, refs: refs}, attempts: attempts} = state
       ) do
    if MapSet.size(refs) == 0 and map_size(attempts) == 0 do
      generation_supervisor = state.generation.generation_supervisor
      cancel_timer(state.generation.brutal_timer)
      cancel_timer(state.generation.cleanup_timer)
      state = %{state | generation: nil}

      with {:ok, outer} <-
             GenerationSupervisor.ensure_generation(generation_supervisor, state.config),
           {:ok, components} <- Generation.components(outer) do
        publish_generation(state, generation_supervisor, outer, components)
      else
        _unavailable -> state
      end
    else
      state
    end
  end

  defp maybe_replace_generation(state), do: state

  defp cancel_timer(nil), do: :ok

  defp cancel_timer(timer) do
    _timer_state = Process.cancel_timer(timer)
    :ok
  end

  defp read_call(server, message) do
    GenServer.call(server, message, 5_000)
  catch
    :exit, _guardian_gone -> {:error, :runtime_unavailable}
  end

  defp mutating_call(server, message, timeout) do
    GenServer.call(server, message, timeout)
  catch
    :exit, {:timeout, _call} ->
      Process.exit(server, :kill)
      {:error, :runtime_unavailable}

    :exit, _guardian_gone ->
      {:error, :runtime_unavailable}
  end

  defp progress_call(server, message, timeout) do
    GenServer.call(server, message, timeout)
  catch
    :exit, {:timeout, _call} -> {:error, :timeout}
    :exit, _guardian_gone -> {:error, :runtime_unavailable}
  end

  defp deadline_call(server, message, timeout) do
    GenServer.call(server, message, timeout)
  catch
    :exit, {:timeout, _call} ->
      Process.exit(server, :kill)
      {:error, :deadline_exceeded}

    :exit, _server_gone ->
      {:error, :runtime_unavailable}
  end
end
