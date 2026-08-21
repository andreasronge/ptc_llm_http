defmodule PtcLlmHttp.Transport.TcpTest do
  use PtcLlmHttp.Test.SocketBackendConformance, backend: PtcLlmHttp.Transport.Tcp

  alias PtcLlmHttp.Transport.Tcp

  def start_peer, do: start_supervised!({RawServer, [transport: :tcp]})

  def open(server, deadline) do
    Tcp.connect(%{address: {127, 0, 0, 1}, port: RawServer.port(server)}, deadline)
  end

  def shrink_kernel_buffer(%Tcp{socket: socket}), do: :inet.setopts(socket, recbuf: 8_192)

  test "the read cap is applied where the bytes arrive" do
    {server, socket} = connected()
    :ok = RawServer.write(server, :binary.copy("a", 65_536))

    assert {:ok, chunk, socket} = Tcp.recv_up_to(socket, 1_024, deadline(5_000))
    assert byte_size(chunk) == 1_024
    # The driver was told to read 1 KiB, so there is no over-read to carry:
    # the remaining 63 KiB is still the kernel's, not the BEAM's.
    assert socket.leftover == <<>>
  end

  test "a read cap above one arrival's worth is clamped to it" do
    {server, socket} = connected()
    :ok = RawServer.write(server, :binary.copy("a", 65_536))

    assert {:ok, chunk, _socket} = Tcp.recv_up_to(socket, 1_000_000, deadline(5_000))
    assert byte_size(chunk) <= SocketBackend.max_chunk()
  end

  test "shrinking the cap between reads keeps the bytes already buffered" do
    {server, socket} = connected()
    payload = :crypto.strong_rand_bytes(8_192)
    :ok = RawServer.write(server, payload)

    assert {:ok, first, socket} = Tcp.recv_up_to(socket, 4_096, deadline(5_000))
    assert {:ok, second, socket} = Tcp.recv_up_to(socket, 64, deadline(5_000))
    assert byte_size(second) <= 64

    {rest, _socket} = read_bytes(socket, 8_192 - byte_size(first) - byte_size(second), [4_096])
    assert first <> second <> rest == payload
  end

  test "refuses a connection whose deadline has already passed" do
    server = start_peer()

    assert {:error, :timeout} =
             Tcp.connect(
               %{address: {127, 0, 0, 1}, port: RawServer.port(server)},
               expired_deadline()
             )

    assert RawServer.connection_count(server) == 0
  end

  test "classifies a refused connection" do
    assert {:error, {:transport, :econnrefused}} = refused_loopback_connect()
  end

  test "inspection reveals nothing about the connection" do
    {_server, socket} = connected()

    assert inspect(socket) == "#PtcLlmHttp.Transport.Tcp<redacted>"
    refute inspect(socket) =~ "socket"
  end

  defp refused_loopback_connect(attempts \\ 8)
  defp refused_loopback_connect(0), do: {:error, :gave_up}

  defp refused_loopback_connect(attempts) do
    server = start_peer()
    port = RawServer.port(server)
    :ok = stop_supervised!(RawServer)

    case Tcp.connect(%{address: {127, 0, 0, 1}, port: port}, deadline(5_000)) do
      {:error, {:transport, :econnrefused}} = refused ->
        refused

      {:ok, socket} ->
        :ok = Tcp.close(socket)
        refused_loopback_connect(attempts - 1)
    end
  end
end
