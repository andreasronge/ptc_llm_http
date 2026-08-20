defmodule PtcLlmHttp.Runtime.Coordinator do
  @moduledoc false

  use GenServer

  alias PtcLlmHttp.{Deadline, Limits}
  alias PtcLlmHttp.Runtime.{AttemptRelay, Guardian, Role}

  def start_link(words), do: GenServer.start_link(__MODULE__, words)

  @impl GenServer
  def init(words) do
    :ok = Limits.set_max_heap(words)
    {:ok, %{binding: nil, operation_ref: nil, timer_ref: nil, terminal: false}}
  end

  def bind(coordinator, binding), do: GenServer.call(coordinator, {:bind, binding})
  def execute(coordinator, operation), do: GenServer.cast(coordinator, {:execute, operation})

  @impl GenServer
  def handle_call({:bind, binding}, _from, %{binding: nil} = state) do
    caller_monitor = Process.monitor(binding.caller)
    state = %{state | binding: Map.put(binding, :caller_monitor, caller_monitor)}
    {:reply, :ok, schedule_deadline(state)}
  end

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
        {:noreply, %{state | timer_ref: nil, terminal: true}}
    end
  end

  def handle_info(
        {:DOWN, caller_monitor, :process, _caller, _reason},
        %{binding: %{caller_monitor: caller_monitor}} = state
      ) do
    report_cause(state, :caller_cancelled)
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
        {:noreply, %{state | operation_ref: operation_ref}}

      {:error, _runtime_unavailable} ->
        {:noreply, %{state | terminal: true}}
    end
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
