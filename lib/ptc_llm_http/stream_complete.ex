defmodule PtcLlmHttp.StreamComplete do
  @moduledoc """
  Terminal facts for a successfully completed text stream.

  Generated text is never accumulated here and inspection is redacted.
  """

  alias PtcLlmHttp.Usage

  @enforce_keys [:usage, :delivered_bytes, :delivered_chunks, :metadata]
  defstruct @enforce_keys

  @opaque t :: %__MODULE__{
            usage: Usage.t() | nil,
            delivered_bytes: non_neg_integer(),
            delivered_chunks: non_neg_integer(),
            metadata: map()
          }

  @doc "Returns provider-reported terminal usage, or `nil` when optional and absent."
  @spec usage(t()) :: Usage.t() | nil
  def usage(%__MODULE__{usage: usage}), do: usage

  @doc "Returns delivered decoded-text byte and chunk counts."
  @spec delivered(t()) :: %{bytes: non_neg_integer(), chunks: non_neg_integer()}
  def delivered(%__MODULE__{} = complete),
    do: %{bytes: complete.delivered_bytes, chunks: complete.delivered_chunks}

  @doc "Returns bounded numeric transport metadata."
  @spec metadata(t()) :: map()
  def metadata(%__MODULE__{metadata: metadata}), do: metadata

  @doc false
  def new(usage, delivered_bytes, delivered_chunks, metadata) do
    %__MODULE__{
      usage: usage,
      delivered_bytes: delivered_bytes,
      delivered_chunks: delivered_chunks,
      metadata: metadata
    }
  end
end

defimpl Inspect, for: PtcLlmHttp.StreamComplete do
  def inspect(_complete, _options), do: "#PtcLlmHttp.StreamComplete<redacted>"
end
