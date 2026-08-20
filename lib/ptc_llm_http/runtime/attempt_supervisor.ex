defmodule PtcLlmHttp.Runtime.AttemptSupervisor do
  @moduledoc false

  use DynamicSupervisor

  alias PtcLlmHttp.Limits
  alias PtcLlmHttp.Runtime.AttemptTree

  def start_link({config, generation}),
    do: DynamicSupervisor.start_link(__MODULE__, {config, generation})

  @impl DynamicSupervisor
  def init({config, _generation}) do
    :ok = Limits.set_max_heap(config.control_partition.attempt_supervisor)

    DynamicSupervisor.init(
      strategy: :one_for_one,
      max_children: config.max_concurrency,
      max_restarts: 0
    )
  end

  def start_attempt(supervisor, generation, attempt_id, budget) do
    DynamicSupervisor.start_child(supervisor, {AttemptTree, {generation, attempt_id, budget}})
  catch
    :exit, _supervisor_gone -> {:error, :attempt_supervisor_unavailable}
  end

  def terminate_attempt(supervisor, tree) do
    DynamicSupervisor.terminate_child(supervisor, tree)
  catch
    :exit, _supervisor_gone -> {:error, :attempt_supervisor_unavailable}
  end
end
