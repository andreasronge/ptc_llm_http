defmodule PtcLlmHttp.Test.ScriptedBackend do
  @moduledoc false

  def hold(observer, tag) do
    fn ->
      send(observer, {:scripted_backend_started, tag, self()})

      receive do
        {:scripted_backend_release, ^tag, result} -> result
      end
    end
  end

  def allocate(observer, tag, entries) do
    fn ->
      send(observer, {:scripted_backend_started, tag, self()})
      retained = List.duplicate({:external, tag}, entries)
      send(observer, {:scripted_backend_allocated, tag, length(retained)})
      {:ok, :unexpected_survival}
    end
  end
end
