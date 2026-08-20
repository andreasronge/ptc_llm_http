defmodule PtcLlmHttp.Test.HttpParserBackend do
  @moduledoc false

  @behaviour PtcLlmHttp.Transport.SocketBackend

  alias PtcLlmHttp.Transport.SocketBackend

  @enforce_keys [:chunks]
  defstruct [:chunks, :observer]

  def socket(chunks, observer \\ nil), do: %__MODULE__{chunks: chunks, observer: observer}

  @impl true
  def connect(_spec, _deadline), do: {:error, {:transport, :unsupported}}

  @impl true
  def send(_socket, _data, _deadline), do: {:error, {:transport, :unsupported}}

  @impl true
  def recv_up_to(%__MODULE__{chunks: []}, _maximum, _deadline), do: {:error, :closed}

  def recv_up_to(%__MODULE__{chunks: [chunk | rest]} = socket, maximum, _deadline) do
    if socket.observer, do: send(socket.observer, {:parser_read, maximum})
    {delivered, leftover} = SocketBackend.split(chunk, maximum)
    chunks = if leftover == <<>>, do: rest, else: [leftover | rest]
    {:ok, delivered, %__MODULE__{socket | chunks: chunks}}
  end

  @impl true
  def close(_socket), do: :ok
end

defimpl Inspect, for: PtcLlmHttp.Test.HttpParserBackend do
  def inspect(_socket, _options), do: "#PtcLlmHttp.Test.HttpParserBackend<redacted>"
end
