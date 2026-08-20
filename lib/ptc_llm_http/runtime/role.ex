defmodule PtcLlmHttp.Runtime.Role do
  @moduledoc false

  use GenServer

  alias PtcLlmHttp.{Error, Limits}

  def start_link({role, words}), do: GenServer.start_link(__MODULE__, {role, words})

  @impl GenServer
  def init({role, words}) do
    :ok = Limits.set_max_heap(words)
    {:ok, %{role: role, running: false}}
  end

  def run(role, coordinator, operation_ref, operation),
    do: GenServer.cast(role, {:run, coordinator, operation_ref, operation})

  @impl GenServer
  def handle_cast({:run, coordinator, operation_ref, operation}, %{running: false} = state) do
    result = invoke(operation)
    send(coordinator, {:role_result, operation_ref, result})
    {:noreply, %{state | running: true}}
  end

  def handle_cast({:run, coordinator, operation_ref, _operation}, state) do
    send(coordinator, {:role_failure, operation_ref, :internal_failure})
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(:ptc_llm_http_cleanup, state), do: {:stop, :shutdown, state}

  defp invoke(operation) when is_function(operation, 0) do
    case operation.() do
      {:ok, _value} = result -> result
      {:error, %Error{}} = result -> result
      _invalid_return -> {:failure, :internal_failure}
    end
  catch
    _kind, _discarded_reason -> {:failure, :internal_failure}
  end

  defp invoke(_operation), do: {:failure, :internal_failure}
end
