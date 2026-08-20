defmodule PtcLlmHttp.Transport.SocketBackend do
  @moduledoc false

  # The socket contract the HTTP core is built on. Internal: consumers never
  # see a backend, and the shape here is free to change between 0.x releases.
  # The durable version of this contract, with the measurements behind it, is
  # `docs/transport-backend.md`.
  #
  # A backend does one job: move bounded bytes over one connection that dies
  # with its owner. It performs no name resolution, applies no address policy,
  # and knows nothing about HTTP. Callers hand it an address that policy has
  # already authorized.
  #
  # `recv_up_to/3` is the whole reason the backend exists:
  #
  #   * it returns as soon as one or more bytes are available;
  #   * it never returns more than the requested maximum;
  #   * unread bytes survive for the next call, in order and exactly once;
  #   * timeout, peer closure, and transport failure are distinguishable; and
  #   * it behaves the same over TCP and over verified TLS.
  #
  # An exact-size read cannot satisfy the first point, and an uncapped read
  # cannot satisfy the second, so neither is used.

  @typedoc "Absolute deadline on the `System.monotonic_time(:millisecond)` scale."
  @type deadline :: integer()

  @typedoc """
  Closed classification of a backend failure.

  `{:transport, atom}` carries a POSIX-style reason, `{:tls, atom}` an alert
  name. Neither ever carries the descriptive term OTP pairs with it: an
  `:ssl` alert description embeds peer-supplied text, and an `{:options, _}`
  error embeds the option list, private key included.
  """
  @type reason ::
          :timeout
          | :closed
          | :no_trust_store
          | {:transport, atom()}
          | {:tls, atom()}

  @type t :: struct()

  @callback connect(spec :: map(), deadline()) :: {:ok, t()} | {:error, reason()}
  @callback send(t(), iodata(), deadline()) :: :ok | {:error, reason()}
  @callback recv_up_to(t(), pos_integer(), deadline()) ::
              {:ok, binary(), t()} | {:error, reason()}
  @callback close(t()) :: :ok

  # One TLS record holds at most 16 KiB of plaintext (RFC 8446, section 5.1),
  # and `:ssl` will not hand back a fraction of a record. 16 KiB is therefore
  # the smallest arrival granularity TLS can offer, and both backends pin
  # their read size to it so that the two have one memory profile.
  @max_chunk 16_384

  @doc "Largest number of bytes either backend reads from the socket at once."
  @spec max_chunk() :: pos_integer()
  def max_chunk, do: @max_chunk

  @doc """
  Milliseconds left before `deadline`, or `{:error, :timeout}` once it passes.

  Every blocking operation derives its timeout from this, so a deadline that
  has already passed costs no syscall and no wait.
  """
  @spec remaining(deadline()) :: {:ok, pos_integer()} | {:error, :timeout}
  def remaining(deadline) when is_integer(deadline) do
    case deadline - System.monotonic_time(:millisecond) do
      remaining when remaining > 0 -> {:ok, remaining}
      _elapsed -> {:error, :timeout}
    end
  end

  @doc """
  Splits `data` into the bytes to return now and the bytes to keep.

  Returning a short read is always allowed; returning a long one is not. The
  split is what makes the cap ours rather than the driver's.
  """
  @spec split(binary(), pos_integer()) :: {binary(), binary()}
  def split(data, max) when is_binary(data) and is_integer(max) and max > 0 do
    case data do
      <<chunk::binary-size(^max), rest::binary>> -> {chunk, rest}
      _within_cap -> {data, <<>>}
    end
  end

  @doc """
  Maps an OTP socket error onto the closed `t:reason/0` set.

  Anything unrecognized becomes `{:transport, :unknown}` rather than travelling
  onward: the discarded term is where endpoints, option lists, and peer text
  hide.
  """
  @spec classify(term()) :: reason()
  def classify(:timeout), do: :timeout
  def classify(:closed), do: :closed
  def classify({:tls_alert, {alert, _description}}) when is_atom(alert), do: {:tls, alert}
  def classify({:options, _option}), do: {:transport, :invalid_options}
  def classify(reason) when is_atom(reason), do: {:transport, reason}
  def classify(_unrecognized), do: {:transport, :unknown}
end
