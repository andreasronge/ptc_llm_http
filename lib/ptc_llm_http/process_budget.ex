defmodule PtcLlmHttp.ProcessBudget do
  @moduledoc """
  Aggregate BEAM process-heap budget for one attempt.

  Callers choose only the inclusive aggregate. The package owns and versions
  the internal role partition, and no role bound can be disabled.
  """

  alias PtcLlmHttp.{Error, Limits}

  @minimum_heap_words Limits.process_budget_min()
  @maximum_heap_words Limits.process_budget_max()

  @enforce_keys [:total_heap_words]
  defstruct [:total_heap_words]

  @opaque t :: %__MODULE__{total_heap_words: pos_integer()}

  @doc "Constructs an aggregate attempt budget in the package-supported range."
  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(total_heap_words: words)
      when is_integer(words) and words >= @minimum_heap_words and words <= @maximum_heap_words do
    {:ok, %__MODULE__{total_heap_words: words}}
  end

  def new(_options),
    do: {:error, Error.build!(:invalid_request, :validate, :request, :not_sent)}

  @doc false
  @spec total_heap_words(t()) :: pos_integer()
  def total_heap_words(%__MODULE__{total_heap_words: words}), do: words

  @doc false
  @spec partition(t()) :: map()
  def partition(%__MODULE__{total_heap_words: words}), do: Limits.attempt_partition(words)

  @doc false
  @spec validate(term()) :: {:ok, t()} | :error
  def validate(%__MODULE__{total_heap_words: words} = budget)
      when is_integer(words) and words >= @minimum_heap_words and words <= @maximum_heap_words,
      do: {:ok, budget}

  def validate(_value), do: :error
end

defimpl Inspect, for: PtcLlmHttp.ProcessBudget do
  def inspect(_budget, _options), do: "#PtcLlmHttp.ProcessBudget<redacted>"
end
