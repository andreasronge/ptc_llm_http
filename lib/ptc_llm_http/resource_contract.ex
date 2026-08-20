defmodule PtcLlmHttp.ResourceContract do
  @moduledoc """
  Versioned package resource contract for consumer integration checks.

  The projection deliberately omits role names, ratios, process identifiers,
  and mutable counters. Those details remain package-owned.
  """

  alias PtcLlmHttp.Limits

  @doc "Returns the current data-only resource contract."
  @spec current() :: map()
  def current do
    %{
      version: "resource-v1",
      process_budget_heap_words: %{
        minimum: Limits.process_budget_min(),
        maximum: Limits.process_budget_max()
      },
      process_partition_version: "process-v1",
      runtime_control_formula_version: "runtime-control-v1"
    }
  end
end
