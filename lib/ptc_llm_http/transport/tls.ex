defmodule PtcLlmHttp.Transport.Tls do
  @moduledoc false

  # Verified-TLS socket backend. Every option below is contract rather than a
  # default worth revisiting per call site; `docs/transport-backend.md` records
  # the measurements each bound came from.
  #
  # Reads work the way the TCP backend's do, with one difference the caller
  # cannot avoid: `:ssl` decrypts whole records, so the smallest unit it will
  # hand back is one record's plaintext. A caller asking for less than that
  # gets what it asked for, and the remainder is held in `:leftover` — at most
  # `SocketBackend.max_chunk/0` bytes, which is also what the pinned `buffer`
  # allows the connection process to read at a time.

  @behaviour PtcLlmHttp.Transport.SocketBackend

  alias PtcLlmHttp.Transport.SocketBackend

  @enforce_keys [:socket]
  defstruct [:socket, leftover: <<>>]

  @type t :: %__MODULE__{socket: :ssl.sslsocket(), leftover: binary()}

  @typedoc """
  Certificate authorities to verify the peer against.

  `:system` is the OTP-held platform trust store: in-memory, present inside an
  assembled release, and never a file this package ships. A host without one
  fails the connection with `:no_trust_store`; there is no unverified fallback.
  """
  @type trust :: :system | [binary()]

  # Intermediate CAs allowed between the peer certificate and a trusted root.
  # OTP's own default, stated rather than inherited: real chains carry one or
  # two, cross-signed ones a few more.
  @depth 10

  # Cap on a handshake message that spans several records. A message that fits
  # in one record is always accepted, so the true bound is
  # `max(16 KiB, @max_handshake_size)` — see the spike notes. 32 KiB clears the
  # few-KiB chains in use today with room for larger post-quantum ones, and
  # rejects the 200 KiB certificate the conformance suite fires at it.
  @max_handshake_size 32_768

  # A per-connection-process heap ceiling is deliberately absent, though
  # `:ssl` accepts one through `receiver_spawn_opts`. It bounds the term heap
  # and not the reference-counted binaries the response actually lives in --
  # counting those needs `include_shared_binaries`, which postdates the
  # supported OTP floor -- and a ceiling below what the connection process
  # needs to start kills it while the caller is still linked, hanging the
  # caller instead of failing it. Bounding process memory is the runtime
  # slice's aggregate budget to design, once, for every role.

  @options [
    :binary,
    packet: :raw,
    active: false,
    nodelay: true,
    send_timeout_close: true,
    versions: [:"tlsv1.2", :"tlsv1.3"],
    verify: :verify_peer,
    depth: @depth,
    max_handshake_size: @max_handshake_size,
    alpn_advertised_protocols: ["http/1.1"],
    # One connection per attempt is the whole transport model, so there is no
    # session to resume and no ticket worth keeping across calls.
    session_tickets: :disabled,
    reuse_sessions: false,
    secure_renegotiate: true,
    # `:ssl`'s own log records embed alert text and connection detail. The
    # alert name reaches the caller as a typed error instead.
    log_level: :none
  ]

  @doc """
  Opens one verified connection to an already-authorized address.

  The spec separates `:address` — the single `:inet.ip_address()` that policy
  approved — from `:hostname`, the name the caller started with. SNI and
  certificate verification use the name; only the socket uses the address, so
  pinning one resolved address cannot weaken what the certificate must prove.
  `:trust` selects the certificate authorities.
  """
  @impl SocketBackend
  def connect(%{address: address, port: port, hostname: hostname, trust: trust}, deadline)
      when is_tuple(address) and is_integer(port) and port in 1..65_535 and is_binary(hostname) do
    with {:ok, timeout} <- SocketBackend.remaining(deadline),
         {:ok, cacerts} <- authorities(trust) do
      case handshake(address, port, options(hostname, cacerts), timeout) do
        {:ok, socket} -> {:ok, %__MODULE__{socket: socket}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @impl SocketBackend
  def send(%__MODULE__{} = state, data, deadline) do
    with {:ok, timeout} <- SocketBackend.remaining(deadline),
         :ok <- setopts(state, send_timeout: timeout) do
      guard(fn ->
        case :ssl.send(state.socket, data) do
          :ok -> :ok
          {:error, reason} -> {:error, SocketBackend.classify(reason)}
        end
      end)
    end
  end

  @impl SocketBackend
  def recv_up_to(%__MODULE__{leftover: <<>>} = state, max, deadline)
      when is_integer(max) and max > 0 do
    with {:ok, timeout} <- SocketBackend.remaining(deadline) do
      guard(fn ->
        case :ssl.recv(state.socket, 0, timeout) do
          {:ok, data} -> deliver(state, data, max)
          {:error, reason} -> {:error, SocketBackend.classify(reason)}
        end
      end)
    end
  end

  def recv_up_to(%__MODULE__{leftover: leftover} = state, max, deadline)
      when is_integer(max) and max > 0 do
    with {:ok, _timeout} <- SocketBackend.remaining(deadline) do
      deliver(%__MODULE__{state | leftover: <<>>}, leftover, max)
    end
  end

  @impl SocketBackend
  def close(%__MODULE__{} = state), do: :ssl.close(state.socket)

  defp deliver(%__MODULE__{} = state, data, max) do
    {chunk, leftover} = SocketBackend.split(data, max)
    {:ok, chunk, %__MODULE__{state | leftover: leftover}}
  end

  defp options(hostname, cacerts) do
    [
      buffer: SocketBackend.max_chunk(),
      cacerts: cacerts,
      server_name_indication: String.to_charlist(hostname),
      customize_hostname_check: [
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      ]
    ] ++ @options
  end

  defp authorities(:system) do
    {:ok, :public_key.cacerts_get()}
  catch
    :error, _no_store -> {:error, :no_trust_store}
  end

  defp authorities(cacerts) when is_list(cacerts), do: {:ok, cacerts}

  defp handshake(address, port, options, timeout) do
    guard(fn ->
      case :ssl.connect(address, port, options, timeout) do
        {:ok, socket} -> {:ok, socket}
        {:error, reason} -> {:error, SocketBackend.classify(reason)}
      end
    end)
  end

  # Options are this module's own and always well formed, so the only way a
  # socket refuses them is by being gone. Saying so is the following read or
  # write's job, in the one vocabulary every other failure uses.
  defp setopts(%__MODULE__{} = state, options) do
    guard(fn ->
      _refused_by_a_dead_socket = :ssl.setopts(state.socket, options)
      :ok
    end)
  end

  # Every `:ssl` entry point is a call into the connection process, so that
  # process dying takes the caller with it unless the exit is caught. A caller
  # that handed over a socket must get a typed failure back, not an exit it
  # never asked for.
  defp guard(operation) do
    operation.()
  catch
    :exit, _connection_process_gone -> {:error, {:transport, :process_exit}}
  end
end

defimpl Inspect, for: PtcLlmHttp.Transport.Tls do
  # A socket names a host the caller chose to talk to. That is a private
  # endpoint, so nothing about it survives inspection.
  def inspect(_socket, _opts), do: "#PtcLlmHttp.Transport.Tls<redacted>"
end
