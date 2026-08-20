defmodule PtcLlmHttp.Runtime.AttemptRelay do
  @moduledoc false

  use GenServer

  alias PtcLlmHttp.Error
  alias PtcLlmHttp.Limits
  alias PtcLlmHttp.Runtime.Guardian

  def start_link(words), do: GenServer.start_link(__MODULE__, words)

  @impl GenServer
  def init(words) do
    :ok = Limits.set_max_heap(words)
    {:ok, %{delivery: nil}}
  end

  def deliver(relay, caller, guardian, generation, attempt_id, deadline, candidate) do
    GenServer.cast(
      relay,
      {:deliver, caller, guardian, generation, attempt_id, deadline, candidate}
    )
  end

  @impl GenServer
  def handle_cast(
        {:deliver, caller, guardian, generation, attempt_id, deadline, candidate},
        %{delivery: nil} = state
      ) do
    delivery_ref = make_ref()
    send(caller, {:ptc_llm_http_candidate, attempt_id, delivery_ref, candidate, self()})

    {:noreply,
     %{
       state
       | delivery:
           {caller, guardian, generation, attempt_id, deadline, delivery_ref, category(candidate)}
     }}
  end

  @impl GenServer
  def handle_info(
        {:ptc_llm_http_candidate_ack, delivery_ref},
        %{
          delivery: {
            _caller,
            guardian,
            generation,
            attempt_id,
            deadline,
            delivery_ref,
            category
          }
        } = state
      ) do
    Guardian.candidate(guardian, generation, attempt_id, deadline, delivery_ref, category)
    {:noreply, state}
  end

  def handle_info(:ptc_llm_http_cleanup, state), do: {:stop, :shutdown, state}

  def handle_info(_message, state), do: {:noreply, state}

  defp category({:error, %Error{}}), do: :classified
  defp category({:ok, _value}), do: :success
end
