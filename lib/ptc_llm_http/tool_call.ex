defmodule PtcLlmHttp.ToolCall do
  @moduledoc """
  One normalized function-tool call returned by a provider.

  The identifier, function name, and decoded arguments are available only
  through explicit accessors. Inspection never exposes them.
  """

  @enforce_keys [:id, :name, :arguments]
  defstruct @enforce_keys

  @opaque t :: %__MODULE__{id: binary(), name: binary(), arguments: map()}

  @doc "Returns the provider tool-call identifier."
  @spec id(t()) :: binary()
  def id(%__MODULE__{id: id}), do: id

  @doc "Returns the declared function name."
  @spec name(t()) :: binary()
  def name(%__MODULE__{name: name}), do: name

  @doc "Returns the bounded, decoded argument object."
  @spec arguments(t()) :: map()
  def arguments(%__MODULE__{arguments: arguments}), do: arguments

  @doc false
  def new(id, name, arguments), do: %__MODULE__{id: id, name: name, arguments: arguments}
end

defimpl Inspect, for: PtcLlmHttp.ToolCall do
  def inspect(_tool_call, _options), do: "#PtcLlmHttp.ToolCall<redacted>"
end
