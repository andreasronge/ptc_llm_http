defmodule PtcLlmHttp.Runtime.Admission do
  @moduledoc false

  use GenServer

  alias PtcLlmHttp.{Deadline, Limits}
  alias PtcLlmHttp.Runtime.AttemptSupervisor

  def start_link({config, generation}), do: GenServer.start_link(__MODULE__, {config, generation})

  @impl GenServer
  def init({config, generation}) do
    :ok = Limits.set_max_heap(config.control_partition.admission)

    {:ok,
     %{
       generation: generation,
       maximum: config.max_concurrency,
       groups: config.groups,
       total: 0,
       group_counts: Map.new(config.groups, fn {group, _limit} -> {group, 0} end),
       leases: %{},
       monitor_index: %{}
     }}
  end

  def identity(admission), do: read_call(admission, :identity)

  def reserve(admission, generation, group, attempt_id, caller, deadline) do
    case Deadline.remaining(deadline) do
      {:ok, timeout} ->
        deadline_call(
          admission,
          {:reserve, generation, group, attempt_id, caller},
          min(timeout, Limits.maximum_timer_milliseconds())
        )

      {:error, _deadline} ->
        {:error, :deadline_exceeded}
    end
  end

  def adopt(admission, generation, lease, attempt_id, deadline) do
    case Deadline.remaining(deadline) do
      {:ok, timeout} ->
        deadline_call(
          admission,
          {:adopt, generation, lease, attempt_id},
          min(timeout, Limits.maximum_timer_milliseconds())
        )

      {:error, _deadline} ->
        {:error, :deadline_exceeded}
    end
  end

  def start_attempt(
        admission,
        generation,
        lease,
        attempt_id,
        caller,
        attempt_supervisor,
        budget,
        deadline
      ) do
    case Deadline.remaining(deadline) do
      {:ok, timeout} ->
        deadline_call(
          admission,
          {:start_attempt, generation, lease, attempt_id, caller, attempt_supervisor, budget},
          min(timeout, Limits.maximum_timer_milliseconds())
        )

      {:error, _deadline} ->
        {:error, :deadline_exceeded}
    end
  end

  def release(admission, generation, lease, attempt_id, timeout) do
    mutating_call(admission, {:release, generation, lease, attempt_id}, timeout)
  end

  def snapshot(admission, generation), do: read_call(admission, {:snapshot, generation})

  @impl GenServer
  def handle_call(:identity, _from, state), do: {:reply, {:ok, state.generation}, state}

  def handle_call({:reserve, generation, group, attempt_id, caller}, _from, state) do
    with true <- generation == state.generation,
         {:ok, group_limit} <- Map.fetch(state.groups, group),
         true <- state.total < state.maximum,
         true <- Map.fetch!(state.group_counts, group) < group_limit,
         false <- Map.has_key?(state.leases, attempt_id),
         true <- is_pid(caller) and Process.alive?(caller) do
      lease = make_ref()
      owner_ref = Process.monitor(caller)

      state = %{
        state
        | total: state.total + 1,
          group_counts: Map.update!(state.group_counts, group, &(&1 + 1)),
          leases:
            Map.put(state.leases, attempt_id, %{
              lease: lease,
              group: group,
              caller: caller,
              tree: nil,
              owner_ref: owner_ref,
              phase: :provisional
            }),
          monitor_index: Map.put(state.monitor_index, owner_ref, attempt_id)
      }

      {:reply, {:ok, lease}, state}
    else
      false -> {:reply, {:error, :capacity_exhausted}, state}
      :error -> {:reply, {:error, :unknown_group}, state}
    end
  end

  def handle_call(
        {:start_attempt, generation, lease, attempt_id, caller, attempt_supervisor, budget},
        _from,
        state
      ) do
    case {generation == state.generation, Map.fetch(state.leases, attempt_id)} do
      {true,
       {:ok,
        %{
          lease: ^lease,
          caller: ^caller,
          tree: nil,
          phase: :provisional
        } = reservation}} ->
        if Process.alive?(caller) do
          case AttemptSupervisor.start_attempt(attempt_supervisor, generation, attempt_id, budget) do
            {:ok, tree} ->
              reservation = %{reservation | tree: tree}

              {:reply, {:ok, tree},
               %{state | leases: Map.put(state.leases, attempt_id, reservation)}}

            {:error, _reason} = error ->
              {:reply, error, state}
          end
        else
          {:reply, {:error, :caller_gone}, release_reservation(state, attempt_id)}
        end

      _stale_or_released ->
        {:reply, {:error, :stale_lease}, state}
    end
  end

  def handle_call({:adopt, generation, lease, attempt_id}, _from, state) do
    case {generation == state.generation, Map.fetch(state.leases, attempt_id)} do
      {true, {:ok, %{lease: ^lease, owner_ref: owner_ref, phase: :provisional} = reservation}} ->
        Process.demonitor(owner_ref, [:flush])

        reservation = %{reservation | caller: nil, tree: nil, owner_ref: nil, phase: :adopted}

        {:reply, :ok,
         %{
           state
           | leases: Map.put(state.leases, attempt_id, reservation),
             monitor_index: Map.delete(state.monitor_index, owner_ref)
         }}

      _stale_or_released ->
        {:reply, {:error, :stale_lease}, state}
    end
  end

  def handle_call({:release, generation, lease, attempt_id}, _from, state) do
    case {generation == state.generation, Map.fetch(state.leases, attempt_id)} do
      {true, {:ok, %{lease: ^lease}}} ->
        {:reply, :ok, release_reservation(state, attempt_id)}

      _stale_or_duplicate ->
        {:reply, {:error, :stale_lease}, state}
    end
  end

  def handle_call({:snapshot, generation}, _from, %{generation: generation} = state) do
    groups =
      Map.new(state.groups, fn {group, limit} ->
        {group, %{in_use: Map.fetch!(state.group_counts, group), limit: limit}}
      end)

    {:reply, {:ok, %{in_use: state.total, limit: state.maximum, groups: groups}}, state}
  end

  def handle_call({:snapshot, _stale_generation}, _from, state),
    do: {:reply, {:error, :stale_generation}, state}

  @impl GenServer
  def handle_info({:DOWN, owner_ref, :process, _caller, _reason}, state) do
    case Map.pop(state.monitor_index, owner_ref) do
      {nil, monitor_index} ->
        {:noreply, %{state | monitor_index: monitor_index}}

      {attempt_id, monitor_index} ->
        state = %{state | monitor_index: monitor_index}
        {:noreply, release_reservation(state, attempt_id)}
    end
  end

  defp release_reservation(state, attempt_id) do
    case Map.pop(state.leases, attempt_id) do
      {nil, _leases} ->
        state

      {%{group: group, owner_ref: owner_ref, tree: tree}, leases} ->
        if owner_ref, do: Process.demonitor(owner_ref, [:flush])
        if is_pid(tree) and Process.alive?(tree), do: Process.exit(tree, :kill)

        %{
          state
          | total: state.total - 1,
            group_counts: Map.update!(state.group_counts, group, &(&1 - 1)),
            leases: leases,
            monitor_index:
              if(owner_ref,
                do: Map.delete(state.monitor_index, owner_ref),
                else: state.monitor_index
              )
        }
    end
  end

  defp read_call(server, message) do
    GenServer.call(server, message, 5_000)
  catch
    :exit, _server_gone -> {:error, :admission_unavailable}
  end

  defp mutating_call(server, message, timeout) do
    GenServer.call(server, message, timeout)
  catch
    :exit, {:timeout, _call} ->
      Process.exit(server, :kill)
      {:error, :admission_unavailable}

    :exit, _server_gone ->
      {:error, :admission_unavailable}
  end

  defp deadline_call(server, message, timeout) do
    GenServer.call(server, message, timeout)
  catch
    :exit, {:timeout, _call} ->
      Process.exit(server, :kill)
      {:error, :deadline_exceeded}

    :exit, _server_gone ->
      {:error, :admission_unavailable}
  end
end
