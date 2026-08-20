defmodule PtcLlmHttp.Test.SocketBackendConformance do
  @moduledoc false

  # The socket contract, as tests. Both backends run it: TCP and verified TLS
  # must be indistinguishable to the HTTP core, and the only honest way to know
  # that is to assert the same behavior against both.
  #
  # A host module supplies three functions and inherits every test below:
  #
  #   * `start_peer/0` — a `RawServer` speaking the backend's transport
  #   * `open/2` — connect this backend to that peer under a deadline
  #   * `shrink_kernel_buffer/1` — pin this socket's receive buffer small

  defmacro __using__(options) do
    quote do
      unquote(preamble(Keyword.fetch!(options, :backend)))
      unquote(helpers())
      unquote(reading_tests())
      unquote(ending_tests())
      unquote(bound_tests())
    end
  end

  defp preamble(backend) do
    quote do
      use ExUnit.Case, async: true
      use ExUnitProperties

      alias PtcLlmHttp.Test.RawServer
      alias PtcLlmHttp.Transport.SocketBackend

      @backend unquote(backend)
    end
  end

  defp helpers do
    quote do
      defp deadline(milliseconds), do: System.monotonic_time(:millisecond) + milliseconds

      defp expired_deadline, do: System.monotonic_time(:millisecond) - 1

      defp connected do
        server = start_peer()
        {:ok, socket} = open(server, deadline(5_000))
        :ok = RawServer.await_connection(server)
        {server, socket}
      end

      # Reads until `count` bytes have been returned, honouring one cap per
      # call, and hands back the concatenation plus the carried state. Every
      # chunk is checked against the cap it was read under, because "never more
      # than the maximum" has to hold on every call, not on average.
      defp read_bytes(socket, count, caps) do
        Enum.reduce_while(Stream.cycle(caps), {<<>>, socket}, fn cap, {acc, socket} ->
          case @backend.recv_up_to(socket, cap, deadline(5_000)) do
            {:ok, chunk, socket} ->
              assert byte_size(chunk) <= cap
              acc = acc <> chunk
              if byte_size(acc) >= count, do: {:halt, {acc, socket}}, else: {:cont, {acc, socket}}

            {:error, reason} ->
              flunk("read failed after #{byte_size(acc)}/#{count} bytes: #{inspect(reason)}")
          end
        end)
      end
    end
  end

  defp reading_tests do
    quote do
      test "delivers the single available byte to a caller that asked for 4 KiB" do
        {server, socket} = connected()
        :ok = RawServer.write(server, "x")

        assert {:ok, "x", _socket} = @backend.recv_up_to(socket, 4_096, deadline(5_000))
      end

      test "returns exactly the requested maximum when far more has arrived" do
        {server, socket} = connected()
        payload = :crypto.strong_rand_bytes(65_536)
        :ok = RawServer.write(server, payload)

        assert {:ok, chunk, socket} = @backend.recv_up_to(socket, 1_024, deadline(5_000))
        assert byte_size(chunk) == 1_024

        # What the socket read past the cap is held, not dropped, and what is
        # held is one arrival's worth at most.
        assert byte_size(socket.leftover) <= SocketBackend.max_chunk()

        {rest, _socket} = read_bytes(socket, 65_536 - 1_024, [4_096])
        assert chunk <> rest == payload
      end

      test "an expired deadline fails without consuming the bytes that are waiting" do
        {server, socket} = connected()
        :ok = RawServer.write(server, "pending")

        assert {:error, :timeout} = @backend.recv_up_to(socket, 4_096, expired_deadline())
        assert {:ok, "pending", _socket} = @backend.recv_up_to(socket, 4_096, deadline(5_000))
      end

      test "reports timeout when the deadline passes before the first byte" do
        {_server, socket} = connected()

        assert {:error, :timeout} = @backend.recv_up_to(socket, 4_096, deadline(50))
      end

      test "reports timeout between chunks, after bytes have already been delivered" do
        {server, socket} = connected()
        :ok = RawServer.write(server, "first")

        assert {:ok, "first", socket} = @backend.recv_up_to(socket, 4_096, deadline(5_000))
        assert {:error, :timeout} = @backend.recv_up_to(socket, 4_096, deadline(50))
      end
    end
  end

  defp ending_tests do
    quote do
      test "reports closure when the peer closes without sending anything" do
        {server, socket} = connected()
        :ok = RawServer.close(server)

        assert {:error, :closed} = @backend.recv_up_to(socket, 4_096, deadline(5_000))
      end

      test "delivers the bytes that arrived before a close, then reports closure" do
        {server, socket} = connected()
        :ok = RawServer.write(server, "tail")
        :ok = RawServer.close(server)

        assert {:ok, "tail", socket} = @backend.recv_up_to(socket, 4_096, deadline(5_000))
        assert {:error, :closed} = @backend.recv_up_to(socket, 4_096, deadline(5_000))
      end

      test "reports closure once the caller has closed the socket itself" do
        {_server, socket} = connected()
        assert :ok = @backend.close(socket)

        assert {:error, :closed} = @backend.recv_up_to(socket, 4_096, deadline(5_000))
      end

      test "sends bytes the peer receives" do
        {server, socket} = connected()

        assert :ok = @backend.send(socket, ["pi", "ng"], deadline(5_000))
        assert {:ok, "ping"} = RawServer.recv(server, 4, 5_000)
      end

      test "refuses to send once the deadline has passed" do
        {server, socket} = connected()

        assert {:error, :timeout} = @backend.send(socket, "late", expired_deadline())
        assert {:error, :timeout} = RawServer.recv(server, 1, 50)
      end

      test "one attempt opens exactly one connection" do
        {server, socket} = connected()
        :ok = RawServer.write(server, "one")

        assert {:ok, "one", _socket} = @backend.recv_up_to(socket, 4_096, deadline(5_000))
        assert RawServer.connection_count(server) == 1
      end

      test "the connection dies with the process that opened it" do
        server = start_peer()
        test_process = self()

        owner =
          spawn(fn ->
            {:ok, socket} = open(server, deadline(5_000))
            send(test_process, {:opened, socket})

            receive do
              :never -> :ok
            end
          end)

        assert_receive {:opened, _socket}, 5_000
        :ok = RawServer.await_connection(server)

        reference = Process.monitor(owner)
        Process.exit(owner, :kill)
        assert_receive {:DOWN, ^reference, :process, ^owner, :killed}, 5_000

        assert :ok = RawServer.await_close(server, 5_000)
      end
    end
  end

  defp bound_tests do
    quote do
      test "a peer that outruns the reader is blocked rather than buffered" do
        {server, socket} = connected()
        :ok = shrink_kernel_buffer(socket)

        # A backend that kept reading ahead would swallow all of this. Being
        # stopped part-way is the bound: how far the peer gets before that is a
        # property of the kernel's buffers, not of this library.
        offered = 128 * 1_024 * 1_024
        assert {:blocked, written} = RawServer.flood(server, offered, 500)
        assert written < offered

        # The connection is still usable and still capped: what the peer did
        # manage to push is read back in bounded pieces.
        assert {:ok, chunk, _socket} = @backend.recv_up_to(socket, 512, deadline(5_000))
        assert byte_size(chunk) == 512
      end

      property "arbitrary write and read fragmentation loses and duplicates nothing" do
        {server, socket} = connected()
        {:ok, holder} = Agent.start_link(fn -> socket end)

        check all(
                writes <-
                  list_of(binary(min_length: 1, max_length: 3_000),
                    min_length: 1,
                    max_length: 6
                  ),
                caps <- list_of(integer(1..4_096), min_length: 1, max_length: 6),
                max_runs: 25
              ) do
          payload = IO.iodata_to_binary(writes)
          Enum.each(writes, &(:ok = RawServer.write(server, &1)))

          {read, socket} = read_bytes(Agent.get(holder, & &1), byte_size(payload), caps)
          Agent.update(holder, fn _previous -> socket end)

          assert read == payload
          # Reading exactly what was written must leave nothing behind, or the
          # next exchange would start with someone else's bytes.
          assert socket.leftover == <<>>
        end
      end
    end
  end
end
