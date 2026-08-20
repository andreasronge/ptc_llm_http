defmodule PtcLlmHttp.Response do
  @moduledoc """
  Normalized non-streaming response.

  Content and usage are available only through explicit accessors. Inspection
  never exposes model output or provider facts.
  """

  alias PtcLlmHttp.Usage

  @enforce_keys [:content, :tool_calls, :usage, :metadata]
  defstruct @enforce_keys

  @opaque t :: %__MODULE__{
            content: binary(),
            tool_calls: [],
            usage: Usage.t() | nil,
            metadata: map()
          }

  @doc "Returns the normalized assistant text."
  @spec content(t()) :: binary()
  def content(%__MODULE__{content: content}), do: content

  @doc "Returns provider-reported usage, or `nil` when it was optional and absent."
  @spec usage(t()) :: Usage.t() | nil
  def usage(%__MODULE__{usage: usage}), do: usage

  @doc "Returns bounded numeric transport metadata."
  @spec metadata(t()) :: map()
  def metadata(%__MODULE__{metadata: metadata}), do: metadata

  @doc false
  def new(content, usage, metadata) do
    %__MODULE__{content: content, tool_calls: [], usage: usage, metadata: metadata}
  end
end

defimpl Inspect, for: PtcLlmHttp.Response do
  def inspect(_response, _options), do: "#PtcLlmHttp.Response<redacted>"
end
