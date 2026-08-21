defmodule PtcLlmHttp.Test.LoopbackPort do
  @moduledoc false

  # Bind and immediately close a loopback listener so a test can name a TCP
  # port that will refuse the next connect. Shared by in-VM transport tests
  # and the fresh-OS hostname-budget probe.

  def unused do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false])
    {:ok, {_address, port}} = :inet.sockname(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end
