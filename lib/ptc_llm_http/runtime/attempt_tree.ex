defmodule PtcLlmHttp.Runtime.AttemptTree do
  @moduledoc false

  use Supervisor

  alias PtcLlmHttp.{Limits, ProcessBudget}
  alias PtcLlmHttp.Runtime.{AttemptRelay, Coordinator, Role}

  def start_link({_generation, _attempt_id, _budget} = init),
    do: Supervisor.start_link(__MODULE__, init)

  @impl Supervisor
  def init({_generation, _attempt_id, budget}) do
    partition = ProcessBudget.partition(budget)
    :ok = Limits.set_max_heap(partition.attempt_tree)

    children = [
      Supervisor.child_spec({Coordinator, partition.coordinator},
        id: :coordinator,
        restart: :transient
      ),
      Supervisor.child_spec({Role, {:codec, partition.codec}}, id: :codec, restart: :transient),
      Supervisor.child_spec({Role, {:callback, partition.callback}},
        id: :callback,
        restart: :transient
      ),
      Supervisor.child_spec({Role, {:dns, partition.dns}}, id: :dns, restart: :transient),
      Supervisor.child_spec({Role, {:socket, partition.socket}},
        id: :socket,
        restart: :transient
      ),
      Supervisor.child_spec({AttemptRelay, partition.relay}, id: :relay, restart: :transient)
    ]

    Supervisor.init(children, strategy: :one_for_all, max_restarts: 0, max_seconds: 1)
  end

  def roles(tree) do
    roles =
      tree
      |> Supervisor.which_children()
      |> Map.new(fn {id, pid, _type, _modules} -> {id, pid} end)

    if Enum.all?([:coordinator, :codec, :callback, :dns, :socket, :relay], &is_pid(roles[&1])) do
      {:ok, roles}
    else
      {:error, :attempt_tree_incomplete}
    end
  catch
    :exit, _tree_gone -> {:error, :attempt_tree_incomplete}
  end

  def child_spec({_generation, attempt_id, _budget} = init) do
    %{
      id: attempt_id,
      start: {__MODULE__, :start_link, [init]},
      restart: :temporary,
      shutdown: Limits.cooperative_cleanup_milliseconds(),
      type: :supervisor
    }
  end
end
