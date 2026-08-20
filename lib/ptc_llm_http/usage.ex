defmodule PtcLlmHttp.Usage do
  @moduledoc """
  Provider-reported token, cache, and cost facts.

  Missing optional facts remain `nil`; this package never estimates price or
  turns missing usage into zero. Inspection is redacted.
  """

  @enforce_keys [:prompt_tokens, :completion_tokens, :total_tokens, :cached_tokens, :cost]
  defstruct @enforce_keys

  @opaque t :: %__MODULE__{
            prompt_tokens: non_neg_integer() | nil,
            completion_tokens: non_neg_integer() | nil,
            total_tokens: non_neg_integer() | nil,
            cached_tokens: non_neg_integer() | nil,
            cost: number() | nil
          }

  @doc "Returns the closed provider-reported usage projection."
  @spec facts(t()) :: map()
  def facts(%__MODULE__{} = usage) do
    %{
      prompt_tokens: usage.prompt_tokens,
      completion_tokens: usage.completion_tokens,
      total_tokens: usage.total_tokens,
      cached_tokens: usage.cached_tokens,
      cost: usage.cost
    }
  end

  @doc false
  def new(facts), do: struct!(__MODULE__, facts)
end

defimpl Inspect, for: PtcLlmHttp.Usage do
  def inspect(_usage, _options), do: "#PtcLlmHttp.Usage<redacted>"
end
