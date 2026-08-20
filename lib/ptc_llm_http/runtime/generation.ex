defmodule PtcLlmHttp.Runtime.Generation do
  @moduledoc false

  use Supervisor

  alias PtcLlmHttp.Limits
  alias PtcLlmHttp.Runtime.{Admission, AttemptSupervisor}

  def start_link(config), do: Supervisor.start_link(__MODULE__, config)

  @impl Supervisor
  def init(config) do
    :ok = Limits.set_max_heap(config.control_partition.generation)
    generation = make_ref()

    children = [
      Supervisor.child_spec(
        {Admission, {config, generation}},
        id: Admission,
        restart: :transient
      ),
      Supervisor.child_spec(
        {AttemptSupervisor, {config, generation}},
        id: AttemptSupervisor,
        restart: :transient
      )
    ]

    Supervisor.init(children, strategy: :one_for_all, max_restarts: 0, max_seconds: 1)
  end

  def components(generation_supervisor) do
    children = Supervisor.which_children(generation_supervisor)

    with {Admission, admission, :worker, _modules} when is_pid(admission) <-
           List.keyfind(children, Admission, 0),
         {AttemptSupervisor, attempt_supervisor, :supervisor, _modules}
         when is_pid(attempt_supervisor) <- List.keyfind(children, AttemptSupervisor, 0),
         {:ok, generation} <- Admission.identity(admission) do
      {:ok,
       %{generation: generation, admission: admission, attempt_supervisor: attempt_supervisor}}
    else
      _missing -> {:error, :generation_unavailable}
    end
  catch
    :exit, _generation_gone -> {:error, :generation_unavailable}
  end

  def child_spec(config) do
    %{
      id: make_ref(),
      start: {__MODULE__, :start_link, [config]},
      restart: :temporary,
      shutdown: PtcLlmHttp.Limits.cleanup_milliseconds(),
      type: :supervisor
    }
  end
end
