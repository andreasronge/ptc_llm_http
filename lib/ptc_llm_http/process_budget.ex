defmodule PtcLlmHttp.ProcessBudget do
  @moduledoc """
  Aggregate BEAM process-heap budget for one attempt.

  Callers choose only the inclusive aggregate. The package owns and versions
  the internal role partition, and no role bound can be disabled.

  The constructor accepts `100_000..2_073_600_000` heap words. That full
  range remains valid for IP-literal targets and for tests that inject a
  resolver and trust material. Hostname targets that use the system resolver
  and, for HTTPS, OTP's platform trust store need at least `4_000_000` words.
  That hostname aggregate is published on `PtcLlmHttp.ResourceContract.current/0`.

  Below the hostname aggregate, a cold `getaddrs` plus `cacerts_get` can kill
  the DNS role even though the constructor accepted the budget. From the
  hostname aggregate upward, the package-owned partition grants the DNS role a
  measured floor large enough for that cold load on the supported OTP/OS
  matrix and rebalances the remaining roles inside the same total. Raising the
  aggregate further grows those other roles; DNS stays at least at the floor
  and follows its percentage once that percentage exceeds the floor.

  The intended tradeoff is that the extra DNS room is taken from the other
  attempt roles rather than by multiplying every ceiling. Per-attempt package
  heap therefore remains the caller's aggregate. At the runtime maximum of
  1,024 concurrent attempts, one thousand twenty-four hostname calls expose at
  most `4_096_000_000` attempt-heap words plus the separate runtime-control
  heap.
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
