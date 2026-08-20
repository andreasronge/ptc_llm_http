defmodule PtcLlmHttp.Limits do
  @moduledoc false

  @base_url_bytes 8_192
  @model_bytes 256
  @capacity_group_bytes 128
  @max_concurrency 1_024
  @max_groups 256
  @bearer_bytes 16_376
  @encoded_request_bytes 1_048_576
  @wire_response_bytes 1_048_576
  @connect_policy_cidrs 32
  @process_budget_min 100_000
  @process_budget_max 2_073_600_000
  @cleanup_milliseconds 1_000
  @cooperative_cleanup_milliseconds 900
  @maximum_timer_milliseconds 4_294_967_295

  def base_url_bytes, do: @base_url_bytes
  def model_bytes, do: @model_bytes
  def capacity_group_bytes, do: @capacity_group_bytes
  def max_concurrency, do: @max_concurrency
  def max_groups, do: @max_groups
  def bearer_bytes, do: @bearer_bytes
  def encoded_request_bytes, do: @encoded_request_bytes
  def wire_response_bytes, do: @wire_response_bytes
  def connect_policy_cidrs, do: @connect_policy_cidrs
  def process_budget_min, do: @process_budget_min
  def process_budget_max, do: @process_budget_max
  def cleanup_milliseconds, do: @cleanup_milliseconds
  def cooperative_cleanup_milliseconds, do: @cooperative_cleanup_milliseconds
  def maximum_timer_milliseconds, do: @maximum_timer_milliseconds

  def runtime_control_words(max_concurrency, group_count) do
    160_000 + 2_560 * max_concurrency + 512 * group_count
  end

  def runtime_control_partition(total_words) do
    root = div(total_words * 10, 100)
    generation_supervisor = div(total_words * 10, 100)
    generation = div(total_words * 10, 100)
    admission = div(total_words * 30, 100)
    attempt_supervisor = div(total_words * 15, 100)

    guardian =
      total_words - root - generation_supervisor - generation - admission - attempt_supervisor

    %{
      root: root,
      guardian: guardian,
      generation_supervisor: generation_supervisor,
      generation: generation,
      admission: admission,
      attempt_supervisor: attempt_supervisor
    }
  end

  def attempt_partition(total_words) do
    attempt_tree = div(total_words * 5, 100)
    coordinator = div(total_words * 5, 100)
    callback = div(total_words * 15, 100)
    dns = div(total_words * 5, 100)
    socket = div(total_words * 20, 100)
    relay = div(total_words * 10, 100)

    codec = total_words - attempt_tree - coordinator - callback - dns - socket - relay

    %{
      attempt_tree: attempt_tree,
      coordinator: coordinator,
      codec: codec,
      callback: callback,
      dns: dns,
      socket: socket,
      relay: relay
    }
  end

  def set_max_heap(words) when is_integer(words) and words > 0 do
    Process.flag(:max_heap_size, %{size: words, kill: true, error_logger: false})
    :ok
  end
end
