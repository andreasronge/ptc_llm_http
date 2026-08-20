defmodule PtcLlmHttp.Runtime.GenerationSupervisor do
  @moduledoc false

  use DynamicSupervisor

  alias PtcLlmHttp.Limits
  alias PtcLlmHttp.Runtime.Generation

  def start_link(config), do: DynamicSupervisor.start_link(__MODULE__, config)

  @impl DynamicSupervisor
  def init(config) do
    :ok = Limits.set_max_heap(config.control_partition.generation_supervisor)

    DynamicSupervisor.init(
      strategy: :one_for_one,
      max_children: 1,
      max_restarts: 0
    )
  end

  def ensure_generation(supervisor, config) do
    case DynamicSupervisor.which_children(supervisor) do
      [{_id, child, :supervisor, _modules}] when is_pid(child) ->
        {:ok, child}

      [] ->
        start_generation(supervisor, config)
    end
  catch
    :exit, _supervisor_gone -> {:error, :generation_supervisor_unavailable}
  end

  defp start_generation(supervisor, config) do
    case DynamicSupervisor.start_child(supervisor, {Generation, config}) do
      {:ok, child} -> {:ok, child}
      {:error, :max_children} -> existing_generation(supervisor)
      {:error, {:max_children, _detail}} -> existing_generation(supervisor)
      {:error, _reason} -> {:error, :generation_start_failed}
    end
  end

  defp existing_generation(supervisor) do
    case DynamicSupervisor.which_children(supervisor) do
      [{_id, child, :supervisor, _modules}] when is_pid(child) -> {:ok, child}
      _missing -> {:error, :generation_start_failed}
    end
  end
end
