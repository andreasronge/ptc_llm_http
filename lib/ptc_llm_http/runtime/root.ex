defmodule PtcLlmHttp.Runtime.Root do
  @moduledoc false

  use Supervisor

  alias PtcLlmHttp.Limits
  alias PtcLlmHttp.Runtime.{GenerationSupervisor, Guardian}

  def start_link(config), do: Supervisor.start_link(__MODULE__, config)

  @impl Supervisor
  def init(config) do
    :ok = Limits.set_max_heap(config.control_partition.root)

    children = [
      Supervisor.child_spec({Guardian, config}, id: Guardian, restart: :permanent),
      Supervisor.child_spec(
        {GenerationSupervisor, config},
        id: GenerationSupervisor,
        restart: :permanent
      )
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
