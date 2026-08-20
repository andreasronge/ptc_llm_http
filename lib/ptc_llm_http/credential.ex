defmodule PtcLlmHttp.Credential do
  @moduledoc """
  Opaque call-local authorization material.

  V1 supports no credential or one RFC 6750 bearer value. Inspection is always
  redacted. The BEAM cannot promise zeroization; the runtime instead minimizes
  copies and keeps the value out of long-lived admission state.
  """

  alias PtcLlmHttp.{Error, Limits}

  @bearer_bytes Limits.bearer_bytes()

  @enforce_keys [:kind]
  defstruct [:kind, :secret]

  @opaque t :: %__MODULE__{kind: :none | :bearer, secret: nil | binary()}

  @doc "Constructs the credential-free value."
  @spec none() :: t()
  def none, do: %__MODULE__{kind: :none, secret: nil}

  @doc "Validates and constructs a bounded RFC 6750 bearer credential."
  @spec bearer(binary()) :: {:ok, t()} | {:error, Error.t()}
  def bearer(secret)
      when is_binary(secret) and byte_size(secret) > 0 and
             byte_size(secret) <= @bearer_bytes do
    if bearer_token?(secret) do
      {:ok, %__MODULE__{kind: :bearer, secret: secret}}
    else
      invalid()
    end
  end

  def bearer(_secret), do: invalid()

  @doc false
  def kind(%__MODULE__{kind: kind}), do: kind

  @doc false
  def authorization_value(%__MODULE__{kind: :none}), do: nil
  def authorization_value(%__MODULE__{kind: :bearer, secret: secret}), do: ["Bearer ", secret]

  defp bearer_token?(secret) do
    case :binary.match(secret, "=") do
      :nomatch ->
        token_prefix?(secret)

      {index, _length} ->
        <<prefix::binary-size(^index), suffix::binary>> = secret
        prefix != "" and token_prefix?(prefix) and padding?(suffix)
    end
  end

  defp token_prefix?(value) do
    value != "" and
      Enum.all?(:binary.bin_to_list(value), fn byte ->
        byte in ?A..?Z or byte in ?a..?z or byte in ?0..?9 or byte in ~c"-._~+/"
      end)
  end

  defp padding?(value), do: Enum.all?(:binary.bin_to_list(value), &(&1 == ?=))

  defp invalid,
    do: {:error, Error.build!(:invalid_credential, :validate, :credential, :not_sent)}
end

defimpl Inspect, for: PtcLlmHttp.Credential do
  def inspect(_credential, _options), do: "#PtcLlmHttp.Credential<redacted>"
end
