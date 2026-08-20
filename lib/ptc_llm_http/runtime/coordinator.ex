defmodule PtcLlmHttp.Runtime.Coordinator do
  @moduledoc false

  use GenServer

  alias PtcLlmHttp.{Deadline, Error, Limits, Transport}
  alias PtcLlmHttp.Runtime.{AttemptRelay, Guardian, Role}

  def start_link(words), do: GenServer.start_link(__MODULE__, words)

  @impl GenServer
  def init(words) do
    :ok = Limits.set_max_heap(words)

    {:ok,
     %{
       binding: nil,
       operation_ref: nil,
       timer_ref: nil,
       terminal: false,
       mode: nil,
       step: nil,
       operation: nil,
       progress: {:admission, :not_sent}
     }}
  end

  def bind(coordinator, binding), do: GenServer.call(coordinator, {:bind, binding})
  def execute(coordinator, operation), do: GenServer.cast(coordinator, {:execute, operation})

  def transport_progress(coordinator, operation_ref, deadline, phase, dispatch) do
    case Deadline.remaining(deadline) do
      {:ok, remaining} ->
        GenServer.call(
          coordinator,
          {:transport_progress, operation_ref, phase, dispatch},
          min(remaining, Limits.cleanup_milliseconds())
        )

      {:error, _deadline} ->
        {:error, :runtime_unavailable}
    end
  catch
    :exit, _coordinator_unavailable -> {:error, :runtime_unavailable}
  end

  @impl GenServer
  def handle_call({:bind, binding}, _from, %{binding: nil} = state) do
    caller_monitor = Process.monitor(binding.caller)
    state = %{state | binding: Map.put(binding, :caller_monitor, caller_monitor)}
    {:reply, :ok, schedule_deadline(state)}
  end

  def handle_call(
        {:transport_progress, operation_ref, phase, dispatch},
        _from,
        %{operation_ref: operation_ref, mode: :http, terminal: false} = state
      ) do
    case update_progress(state, phase, dispatch) do
      {:ok, state} ->
        {:reply, :ok, state}

      {:error, :deadline_exceeded, state} ->
        report_cause(state, :deadline_exceeded)
        {:reply, {:error, :runtime_unavailable}, %{state | terminal: true}}

      {:error, :runtime_unavailable, state} ->
        {:reply, {:error, :runtime_unavailable}, %{state | terminal: true}}
    end
  end

  def handle_call({:transport_progress, _operation_ref, _phase, _dispatch}, _from, state),
    do: {:reply, {:error, :runtime_unavailable}, state}

  @impl GenServer
  def handle_cast(
        {:execute, operation},
        %{binding: binding, operation_ref: nil, terminal: false} = state
      )
      when not is_nil(binding) do
    case Deadline.remaining(binding.deadline) do
      {:ok, _remaining} ->
        dispatch_operation(state, operation)

      {:error, _deadline} ->
        report_cause(state, :deadline_exceeded)
        {:noreply, %{state | terminal: true}}
    end
  end

  def handle_cast({:execute, _operation}, state) do
    report_cause(state, :internal_failure)
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(
        {:role_result, operation_ref, {:ok, {:http_dns, {:ok, connection_spec}}}},
        %{operation_ref: operation_ref, mode: :http, step: :dns} = state
      ) do
    dispatch_exchange(state, connection_spec)
  end

  def handle_info(
        {:role_result, operation_ref, {:ok, {:http_dns, {:error, _reason}}}},
        %{operation_ref: operation_ref, mode: :http, step: :dns} = state
      ) do
    terminal(state, fn -> deliver(state, {:error, http_error(state)}) end)
  end

  def handle_info(
        {:role_result, operation_ref, {:ok, {:http_exchange, {:ok, response}}}},
        %{operation_ref: operation_ref, mode: :http, step: :socket} = state
      ) do
    terminal(state, fn -> deliver(state, {:ok, response}) end)
  end

  def handle_info(
        {:role_result, operation_ref, {:ok, {:http_exchange, {:error, :deadline_exceeded}}}},
        %{operation_ref: operation_ref, mode: :http, step: :socket} = state
      ) do
    terminal(state, fn -> report_cause(state, :deadline_exceeded) end)
  end

  def handle_info(
        {:role_result, operation_ref, {:ok, {:http_exchange, {:error, _reason}}}},
        %{operation_ref: operation_ref, mode: :http, step: :socket} = state
      ) do
    terminal(state, fn -> deliver(state, {:error, http_error(state)}) end)
  end

  def handle_info(
        {:role_result, operation_ref, {:ok, _value} = candidate},
        %{operation_ref: operation_ref} = state
      ) do
    terminal(state, fn -> deliver(state, candidate) end)
  end

  def handle_info(
        {:role_result, operation_ref, {:error, _error} = candidate},
        %{operation_ref: operation_ref} = state
      ) do
    terminal(state, fn -> deliver(state, candidate) end)
  end

  def handle_info(
        {:role_result, operation_ref, {:failure, cause}},
        %{operation_ref: operation_ref} = state
      ) do
    terminal(state, fn -> report_cause(state, cause) end)
  end

  def handle_info({:role_failure, operation_ref, cause}, %{operation_ref: operation_ref} = state) do
    terminal(state, fn -> report_cause(state, cause) end)
  end

  def handle_info(
        {:deadline_check, deadline},
        %{binding: %{deadline: deadline}, terminal: false} = state
      ) do
    case Deadline.remaining(deadline) do
      {:ok, _remaining} ->
        {:noreply, schedule_deadline(%{state | timer_ref: nil})}

      {:error, _deadline_error} ->
        report_cause(state, :deadline_exceeded)
        stop_active_role(state)
        {:noreply, %{state | timer_ref: nil, terminal: true}}
    end
  end

  def handle_info(
        {:DOWN, caller_monitor, :process, _caller, _reason},
        %{binding: %{caller_monitor: caller_monitor}} = state
      ) do
    report_cause(state, :caller_cancelled)
    stop_active_role(state)
    {:noreply, state}
  end

  def handle_info(:ptc_llm_http_cleanup, state), do: {:stop, :shutdown, state}

  def handle_info(_message, state), do: {:noreply, state}

  defp deliver(%{binding: binding}, candidate) do
    AttemptRelay.deliver(
      binding.roles.relay,
      binding.caller,
      binding.guardian,
      binding.generation,
      binding.attempt_id,
      binding.deadline,
      candidate
    )
  end

  defp dispatch_operation(%{binding: binding} = state, {:http, operation})
       when is_map(operation) do
    case update_progress(state, :dns, :not_sent) do
      {:ok, state} ->
        operation_ref = make_ref()
        role_operation = fn -> {:ok, {:http_dns, Transport.resolve(operation)}} end
        Role.run(binding.roles.dns, self(), operation_ref, role_operation)

        {:noreply,
         %{
           state
           | operation_ref: operation_ref,
             mode: :http,
             step: :dns,
             operation: operation
         }}

      {:error, :deadline_exceeded, state} ->
        report_cause(state, :deadline_exceeded)
        {:noreply, %{state | terminal: true}}

      {:error, :runtime_unavailable, state} ->
        {:noreply, %{state | terminal: true}}
    end
  end

  defp dispatch_operation(%{binding: binding} = state, operation) do
    case Guardian.progress(
           binding.guardian,
           binding.generation,
           binding.attempt_id,
           :send,
           :possibly_sent
         ) do
      :ok ->
        operation_ref = make_ref()
        send(binding.caller, {:ptc_llm_http_progress, binding.attempt_id, :send, :possibly_sent})
        Role.run(binding.roles.socket, self(), operation_ref, operation)

        {:noreply,
         %{
           state
           | operation_ref: operation_ref,
             mode: :function,
             step: :socket,
             progress: {:send, :possibly_sent}
         }}

      {:error, _runtime_unavailable} ->
        {:noreply, %{state | terminal: true}}
    end
  end

  defp dispatch_exchange(%{binding: binding, operation: operation} = state, connection_spec) do
    coordinator = self()
    operation_ref = state.operation_ref
    deadline = binding.deadline

    progress = fn phase, dispatch ->
      transport_progress(coordinator, operation_ref, deadline, phase, dispatch)
    end

    role_operation = fn ->
      {:ok, {:http_exchange, Transport.exchange(operation, connection_spec, progress)}}
    end

    Role.run(binding.roles.socket, self(), operation_ref, role_operation)
    {:noreply, %{state | step: :socket}}
  end

  defp update_progress(%{binding: binding} = state, phase, dispatch) do
    case Deadline.remaining(binding.deadline) do
      {:ok, remaining} ->
        progress_result =
          Guardian.progress_until(
            binding.guardian,
            binding.generation,
            binding.attempt_id,
            phase,
            dispatch,
            min(remaining, Limits.cleanup_milliseconds())
          )

        finish_progress(state, phase, dispatch, progress_result)

      {:error, _deadline} ->
        {:error, :deadline_exceeded, state}
    end
  end

  defp finish_progress(%{binding: binding} = state, phase, dispatch, :ok) do
    send(binding.caller, {:ptc_llm_http_progress, binding.attempt_id, phase, dispatch})
    {:ok, %{state | progress: {phase, dispatch}}}
  end

  defp finish_progress(%{binding: binding} = state, _phase, _dispatch, {:error, :timeout}) do
    case Deadline.remaining(binding.deadline) do
      {:ok, _remaining} ->
        Process.exit(binding.guardian, :kill)
        {:error, :runtime_unavailable, state}

      {:error, _deadline} ->
        {:error, :deadline_exceeded, state}
    end
  end

  defp finish_progress(%{binding: binding} = state, _phase, _dispatch, _unavailable) do
    case Deadline.remaining(binding.deadline) do
      {:ok, _remaining} -> {:error, :runtime_unavailable, state}
      {:error, _deadline} -> {:error, :deadline_exceeded, state}
    end
  end

  defp http_error(%{progress: {phase, dispatch}}),
    do: Error.build!(:internal_failure, phase, :transport, dispatch)

  defp stop_active_role(%{binding: binding, step: step}) do
    role = if step == :dns, do: binding.roles.dns, else: binding.roles.socket
    if is_pid(role) and Process.alive?(role), do: Process.exit(role, :kill)
    :ok
  end

  defp report_cause(%{binding: nil}, _cause), do: :ok

  defp report_cause(%{binding: binding}, cause) do
    Guardian.cause(binding.guardian, binding.generation, binding.attempt_id, cause)
  end

  defp terminal(%{binding: %{deadline: deadline}} = state, on_time) do
    case Deadline.remaining(deadline) do
      {:ok, _remaining} -> on_time.()
      {:error, _deadline} -> report_cause(state, :deadline_exceeded)
    end

    {:noreply, %{state | terminal: true}}
  end

  defp schedule_deadline(%{binding: %{deadline: deadline}} = state) do
    milliseconds =
      case Deadline.remaining(deadline) do
        {:ok, remaining} -> min(remaining, Limits.maximum_timer_milliseconds())
        {:error, _deadline_error} -> 0
      end

    timer_ref = Process.send_after(self(), {:deadline_check, deadline}, milliseconds)
    %{state | timer_ref: timer_ref}
  end
end
