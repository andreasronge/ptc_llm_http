defmodule PtcLlmHttp.Test.RawServer do
  @moduledoc false

  # A loopback peer that does exactly what a test tells it to, byte by byte and
  # event by event: accept, write these bytes, keep writing until you are
  # blocked, close now. Nothing here waits on a clock — every observation a
  # test needs is a call that blocks until the event happens.
  #
  # It speaks raw TCP or raw TLS, so one conformance suite runs against both
  # backends, and it counts accepted connections so "one attempt opens one
  # connection" is an assertion rather than a hope.

  use GenServer

  alias PtcLlmHttp.Test.Certificates

  @type option :: {:transport, :tcp | :tls} | {:certificates, Certificates.bundle()}

  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  @spec port(pid()) :: :inet.port_number()
  def port(server), do: GenServer.call(server, :port)

  @doc "The DER-encoded authorities a client should trust to reach this server."
  @spec trust(pid()) :: [binary()]
  def trust(server), do: GenServer.call(server, :trust)

  @doc "Blocks until a client connection has been accepted (and, for TLS, negotiated)."
  @spec await_connection(pid(), timeout()) :: :ok
  def await_connection(server, timeout \\ 5_000),
    do: GenServer.call(server, {:await_connection, timeout}, timeout + 1_000)

  @doc "How many connections this server has accepted since it started."
  @spec connection_count(pid()) :: non_neg_integer()
  def connection_count(server), do: GenServer.call(server, :connection_count)

  @doc """
  Writes bytes to the accepted connection.

  `:timeout` bounds the write, which is how a test observes that the peer
  stopped accepting data — the flow-control assertion — rather than inferring
  it from memory.
  """
  @spec write(pid(), iodata(), timeout()) :: :ok | {:error, term()}
  def write(server, data, timeout \\ 5_000),
    do: GenServer.call(server, {:write, data, timeout}, timeout + 1_000)

  @doc """
  Writes 64 KiB at a time until `bytes` have gone out or a write blocks.

  `{:blocked, written}` is the interesting answer: it means the client stopped
  taking data, which is the only externally visible proof that the bytes are
  not piling up inside it. A single large write would prove nothing — the
  driver queues it and reports success.
  """
  @spec flood(pid(), pos_integer(), timeout()) ::
          {:blocked | :completed, non_neg_integer()} | {:error, term(), non_neg_integer()}
  def flood(server, bytes, timeout),
    do: GenServer.call(server, {:flood, bytes, timeout}, timeout * 4 + 5_000)

  @spec recv(pid(), non_neg_integer(), timeout()) :: {:ok, binary()} | {:error, term()}
  def recv(server, bytes, timeout \\ 5_000),
    do: GenServer.call(server, {:recv, bytes, timeout}, timeout + 1_000)

  @doc "Closes the accepted connection while leaving the listener open."
  @spec close(pid()) :: :ok
  def close(server), do: GenServer.call(server, :close)

  @doc "Blocks until the accepted connection reports that the client is gone."
  @spec await_close(pid(), timeout()) :: :ok | {:error, term()}
  def await_close(server, timeout \\ 5_000),
    do: GenServer.call(server, {:await_close, timeout}, timeout + 1_000)

  @impl GenServer
  def init(options) do
    transport = Keyword.get(options, :transport, :tcp)
    bundle = Keyword.get(options, :certificates)

    {:ok, listen} = listen(transport, bundle)

    state = %{
      transport: transport,
      listen: listen,
      bundle: bundle,
      connections: [],
      count: 0,
      waiting: []
    }

    {:ok, state, {:continue, :accept}}
  end

  @impl GenServer
  def handle_continue(:accept, state) do
    server = self()
    spawn_link(fn -> accept_loop(server, state) end)
    {:noreply, state}
  end

  @impl GenServer
  def handle_call(:port, _from, state), do: {:reply, listen_port(state), state}

  def handle_call(:trust, _from, state), do: {:reply, state.bundle.roots, state}

  def handle_call(:connection_count, _from, state), do: {:reply, state.count, state}

  def handle_call({:await_connection, _timeout}, _from, %{connections: [_ | _]} = state),
    do: {:reply, :ok, state}

  def handle_call({:await_connection, timeout}, from, state) do
    Process.send_after(self(), {:await_timeout, from}, timeout)
    {:noreply, %{state | waiting: [from | state.waiting]}}
  end

  def handle_call({:write, data, timeout}, _from, state) do
    socket = current(state)
    setopts(state.transport, socket, send_timeout: timeout)
    {:reply, send_data(state.transport, socket, data), state}
  end

  def handle_call({:flood, bytes, timeout}, _from, state) do
    socket = current(state)
    setopts(state.transport, socket, send_timeout: timeout, sndbuf: 4_096)
    {:reply, flood(state, socket, :binary.copy("z", 65_536), bytes, 0), state}
  end

  def handle_call({:recv, bytes, timeout}, _from, state),
    do: {:reply, recv_data(state.transport, current(state), bytes, timeout), state}

  def handle_call(:close, _from, %{connections: [socket | rest]} = state) do
    close_socket(state.transport, socket)
    {:reply, :ok, %{state | connections: rest}}
  end

  def handle_call({:await_close, timeout}, _from, state) do
    {:reply, drain_until_closed(state, System.monotonic_time(:millisecond) + timeout), state}
  end

  @impl GenServer
  def handle_info({:accepted, socket}, state) do
    Enum.each(state.waiting, &GenServer.reply(&1, :ok))

    {:noreply,
     %{state | connections: [socket | state.connections], count: state.count + 1, waiting: []}}
  end

  def handle_info({:await_timeout, from}, state) do
    if from in state.waiting do
      GenServer.reply(from, {:error, :timeout})
      {:noreply, %{state | waiting: List.delete(state.waiting, from)}}
    else
      {:noreply, state}
    end
  end

  defp flood(_state, _socket, _chunk, remaining, written) when remaining <= 0,
    do: {:completed, written}

  defp flood(state, socket, chunk, remaining, written) do
    case send_data(state.transport, socket, chunk) do
      :ok ->
        flood(state, socket, chunk, remaining - byte_size(chunk), written + byte_size(chunk))

      {:error, :timeout} ->
        {:blocked, written}

      {:error, reason} ->
        {:error, reason, written}
    end
  end

  # Whatever the client managed to send before it died is not interesting; that
  # the socket ends up closed is.
  defp drain_until_closed(state, deadline) do
    case System.monotonic_time(:millisecond) do
      now when now >= deadline ->
        {:error, :timeout}

      now ->
        case recv_data(state.transport, current(state), 0, deadline - now) do
          {:error, :closed} -> :ok
          {:ok, _discarded} -> drain_until_closed(state, deadline)
          other -> other
        end
    end
  end

  defp accept_loop(server, %{transport: :tcp} = state) do
    case :gen_tcp.accept(state.listen) do
      {:ok, socket} ->
        :ok = :gen_tcp.controlling_process(socket, server)
        send(server, {:accepted, socket})
        accept_loop(server, state)

      {:error, _listener_gone} ->
        :ok
    end
  end

  defp accept_loop(server, %{transport: :tls} = state) do
    case :ssl.transport_accept(state.listen) do
      {:ok, pending} ->
        handshake(server, pending)
        accept_loop(server, state)

      {:error, _listener_gone} ->
        :ok
    end
  end

  # A client that rejects this server's certificate is a normal outcome here,
  # not a fixture failure: the acceptor drops the attempt and keeps listening.
  defp handshake(server, pending) do
    case :ssl.handshake(pending, 5_000) do
      {:ok, socket} ->
        :ok = :ssl.controlling_process(socket, server)
        send(server, {:accepted, socket})

      {:error, _rejected_by_client} ->
        :ok
    end
  end

  defp listen(:tcp, _bundle) do
    :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true, backlog: 8])
  end

  defp listen(:tls, bundle) do
    :ssl.listen(
      0,
      [
        :binary,
        packet: :raw,
        active: false,
        reuseaddr: true,
        backlog: 8,
        versions: [:"tlsv1.2", :"tlsv1.3"],
        alpn_preferred_protocols: ["http/1.1"],
        log_level: :none
      ] ++ Certificates.server_options(bundle)
    )
  end

  defp listen_port(%{transport: :tcp, listen: listen}) do
    {:ok, port} = :inet.port(listen)
    port
  end

  defp listen_port(%{transport: :tls, listen: listen}) do
    {:ok, {_address, port}} = :ssl.sockname(listen)
    port
  end

  defp current(%{connections: [socket | _rest]}), do: socket

  defp setopts(:tcp, socket, options), do: :inet.setopts(socket, options)
  defp setopts(:tls, socket, options), do: :ssl.setopts(socket, options)

  defp send_data(:tcp, socket, data), do: :gen_tcp.send(socket, data)
  defp send_data(:tls, socket, data), do: :ssl.send(socket, data)

  defp recv_data(:tcp, socket, bytes, timeout), do: :gen_tcp.recv(socket, bytes, timeout)
  defp recv_data(:tls, socket, bytes, timeout), do: :ssl.recv(socket, bytes, timeout)

  defp close_socket(:tcp, socket), do: :gen_tcp.close(socket)
  defp close_socket(:tls, socket), do: :ssl.close(socket)
end
