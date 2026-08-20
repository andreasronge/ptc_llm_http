defmodule PtcLlmHttp.Transport.Tcp do
  @moduledoc false

  # Plain-TCP socket backend, for the credential-free loopback targets the
  # target constructor admits. Everything else uses `PtcLlmHttp.Transport.Tls`.
  #
  # `:gen_tcp.recv(socket, 0, timeout)` on a `:raw` passive socket returns as
  # soon as bytes are available and never returns more than the `buffer`
  # option allows, so the cap is set where the bytes arrive rather than
  # trimmed after a buffer has grown. `buffer` is re-set per call when the
  # requested maximum changes; shrinking it mid-stream keeps whatever the
  # driver has already buffered.

  @behaviour PtcLlmHttp.Transport.SocketBackend

  alias PtcLlmHttp.Transport.SocketBackend

  @enforce_keys [:socket, :chunk]
  defstruct [:socket, :chunk, leftover: <<>>]

  @type t :: %__MODULE__{
          socket: :gen_tcp.socket(),
          chunk: pos_integer(),
          leftover: binary()
        }

  # `send_timeout_close` makes a send that outran its deadline fatal to the
  # socket: a half-written request must never look reusable.
  @options [
    :binary,
    packet: :raw,
    active: false,
    nodelay: true,
    send_timeout_close: true
  ]

  @doc """
  Opens one connection to an already-authorized address.

  The spec takes `:address` — an `:inet.ip_address()`, never a name, because
  resolution and address policy happen before the backend is reached — and
  `:port`.
  """
  @impl SocketBackend
  def connect(%{address: address, port: port}, deadline)
      when is_tuple(address) and is_integer(port) and port in 1..65_535 do
    chunk = SocketBackend.max_chunk()

    with {:ok, timeout} <- SocketBackend.remaining(deadline) do
      case :gen_tcp.connect(address, port, [{:buffer, chunk} | @options], timeout) do
        {:ok, socket} -> {:ok, %__MODULE__{socket: socket, chunk: chunk}}
        {:error, reason} -> {:error, SocketBackend.classify(reason)}
      end
    end
  end

  @impl SocketBackend
  def send(%__MODULE__{} = state, data, deadline) do
    with {:ok, timeout} <- SocketBackend.remaining(deadline) do
      setopts(state, send_timeout: timeout)

      case :gen_tcp.send(state.socket, data) do
        :ok -> :ok
        {:error, reason} -> {:error, SocketBackend.classify(reason)}
      end
    end
  end

  @impl SocketBackend
  def recv_up_to(%__MODULE__{leftover: <<>>} = state, max, deadline)
      when is_integer(max) and max > 0 do
    with {:ok, timeout} <- SocketBackend.remaining(deadline) do
      state = resize(state, min(max, SocketBackend.max_chunk()))

      case :gen_tcp.recv(state.socket, 0, timeout) do
        {:ok, data} -> deliver(state, data, max)
        {:error, reason} -> {:error, SocketBackend.classify(reason)}
      end
    end
  end

  def recv_up_to(%__MODULE__{leftover: leftover} = state, max, deadline)
      when is_integer(max) and max > 0 do
    with {:ok, _timeout} <- SocketBackend.remaining(deadline) do
      deliver(%__MODULE__{state | leftover: <<>>}, leftover, max)
    end
  end

  @impl SocketBackend
  def close(%__MODULE__{} = state), do: :gen_tcp.close(state.socket)

  defp deliver(%__MODULE__{} = state, data, max) do
    {chunk, leftover} = SocketBackend.split(data, max)
    {:ok, chunk, %__MODULE__{state | leftover: leftover}}
  end

  defp resize(%__MODULE__{chunk: chunk} = state, chunk), do: state

  defp resize(%__MODULE__{} = state, chunk) do
    setopts(state, buffer: chunk)
    %__MODULE__{state | chunk: chunk}
  end

  # Options are this module's own and always well formed, so the only way a
  # socket refuses them is by being gone. Saying so is the following read or
  # write's job, in the one vocabulary every other failure uses.
  defp setopts(%__MODULE__{} = state, options) do
    _refused_by_a_dead_socket = :inet.setopts(state.socket, options)
    :ok
  end
end

defimpl Inspect, for: PtcLlmHttp.Transport.Tcp do
  # A socket names a host the caller chose to talk to. That is a private
  # endpoint, so nothing about it survives inspection.
  def inspect(_socket, _opts), do: "#PtcLlmHttp.Transport.Tcp<redacted>"
end
