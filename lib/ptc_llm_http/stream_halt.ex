defmodule PtcLlmHttp.StreamHalt do
  @moduledoc """
  Terminal facts for a consumer-halted text stream.

  Partial generated text is never retained and inspection is redacted.
  """

  alias PtcLlmHttp.Usage

  @enforce_keys [
    :reason,
    :usage,
    :usage_complete?,
    :delivered_bytes,
    :delivered_chunks,
    :metadata
  ]
  defstruct @enforce_keys

  @opaque t :: %__MODULE__{
            reason: :consumer_halted,
            usage: Usage.t() | nil,
            usage_complete?: false,
            delivered_bytes: non_neg_integer(),
            delivered_chunks: non_neg_integer(),
            metadata: map()
          }

  @doc "Returns the closed halt reason."
  @spec reason(t()) :: :consumer_halted
  def reason(%__MODULE__{reason: reason}), do: reason

  @doc "Returns usage observed before the halt, if any."
  @spec usage(t()) :: Usage.t() | nil
  def usage(%__MODULE__{usage: usage}), do: usage

  @doc "Returns `false`; a halted stream never has authoritative terminal usage."
  @spec usage_complete?(t()) :: false
  def usage_complete?(%__MODULE__{usage_complete?: complete?}), do: complete?

  @doc "Returns delivered decoded-text byte and chunk counts."
  @spec delivered(t()) :: %{bytes: non_neg_integer(), chunks: non_neg_integer()}
  def delivered(%__MODULE__{} = halt),
    do: %{bytes: halt.delivered_bytes, chunks: halt.delivered_chunks}

  @doc "Returns bounded numeric transport metadata observed before halt."
  @spec metadata(t()) :: map()
  def metadata(%__MODULE__{metadata: metadata}), do: metadata

  @doc false
  def new(usage, delivered_bytes, delivered_chunks, metadata) do
    %__MODULE__{
      reason: :consumer_halted,
      usage: usage,
      usage_complete?: false,
      delivered_bytes: delivered_bytes,
      delivered_chunks: delivered_chunks,
      metadata: metadata
    }
  end
end

defimpl Inspect, for: PtcLlmHttp.StreamHalt do
  def inspect(_halt, _options), do: "#PtcLlmHttp.StreamHalt<redacted>"
end
