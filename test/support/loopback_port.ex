defmodule PtcLlmHttp.Test.LoopbackPort do
  @moduledoc false

  # Name a loopback TCP port that currently refuses connect, without binding a
  # listener. Bind-then-close races with other tests that just released an
  # ephemeral port and still expect `econnrefused`.

  @ephemeral 49_152..65_535
  @attempts 32
  @connect_timeout 200

  def unused do
    Enum.find_value(1..@attempts, &refused_ephemeral/1) ||
      raise "could not find a refused loopback TCP port"
  end

  defp refused_ephemeral(_attempt) do
    port = Enum.random(@ephemeral)

    case :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], @connect_timeout) do
      {:error, :econnrefused} ->
        port

      {:ok, socket} ->
        :ok = :gen_tcp.close(socket)
        nil

      {:error, _reason} ->
        nil
    end
  end
end
