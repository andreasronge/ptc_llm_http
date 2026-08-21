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
  @header_name_bytes 128
  @header_value_bytes 16_384
  @request_header_fields 64
  @request_head_bytes 65_536
  @response_line_bytes 16_384
  @response_head_bytes 65_536
  @response_header_fields 128
  @informational_responses 8
  @chunk_line_bytes 1_024
  @trailer_bytes 16_384
  @trailer_fields 64
  @sse_event_bytes 262_144
  @sse_events 10_000
  @stream_decoded_text_bytes 262_144
  @messages 1_024
  @tools 128
  @tool_calls 128
  @tool_name_bytes 64
  @tool_call_id_bytes 256
  @tool_description_bytes 16_384
  @tool_argument_bytes 262_144
  @schema_name_bytes 64
  @schema_property_bytes 128
  @schema_enum_values 128
  @schema_properties 5_000
  @schema_depth 10
  @schema_string_characters 120_000
  @schema_total_enum_values 1_000
  @integer_parameter_min -9_223_372_036_854_775_808
  @integer_parameter_max 9_223_372_036_854_775_807
  @json_depth 64
  @json_nodes 100_000
  @dns_addresses 8
  @connect_policy_cidrs 32
  @process_budget_min 100_000
  @process_budget_max 2_073_600_000
  @process_budget_hostname 4_000_000
  @dns_role_heap_floor 2_000_000
  @attempt_tree_percent 5
  @coordinator_percent 5
  @callback_percent 15
  @dns_percent 5
  @socket_percent 20
  @relay_percent 10
  @partition_percent_base 100
  @non_dns_partition_percent 95
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
  def header_name_bytes, do: @header_name_bytes
  def header_value_bytes, do: @header_value_bytes
  def request_header_fields, do: @request_header_fields
  def request_head_bytes, do: @request_head_bytes
  def response_line_bytes, do: @response_line_bytes
  def response_head_bytes, do: @response_head_bytes
  def response_header_fields, do: @response_header_fields
  def informational_responses, do: @informational_responses
  def chunk_line_bytes, do: @chunk_line_bytes
  def trailer_bytes, do: @trailer_bytes
  def trailer_fields, do: @trailer_fields
  def sse_event_bytes, do: @sse_event_bytes
  def sse_events, do: @sse_events
  def stream_decoded_text_bytes, do: @stream_decoded_text_bytes
  def messages, do: @messages
  def tools, do: @tools
  def tool_calls, do: @tool_calls
  def tool_name_bytes, do: @tool_name_bytes
  def tool_call_id_bytes, do: @tool_call_id_bytes
  def tool_description_bytes, do: @tool_description_bytes
  def tool_argument_bytes, do: @tool_argument_bytes
  def schema_name_bytes, do: @schema_name_bytes
  def schema_property_bytes, do: @schema_property_bytes
  def schema_enum_values, do: @schema_enum_values
  def schema_properties, do: @schema_properties
  def schema_depth, do: @schema_depth
  def schema_string_characters, do: @schema_string_characters
  def schema_total_enum_values, do: @schema_total_enum_values
  def integer_parameter_min, do: @integer_parameter_min
  def integer_parameter_max, do: @integer_parameter_max
  def json_depth, do: @json_depth
  def json_nodes, do: @json_nodes
  def dns_addresses, do: @dns_addresses
  def connect_policy_cidrs, do: @connect_policy_cidrs
  def process_budget_min, do: @process_budget_min
  def process_budget_max, do: @process_budget_max
  def process_budget_hostname, do: @process_budget_hostname
  def dns_role_heap_floor, do: @dns_role_heap_floor
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
    partition = percentage_attempt_partition(total_words)

    if total_words >= @process_budget_hostname and partition.dns < @dns_role_heap_floor do
      floored_dns_attempt_partition(total_words)
    else
      partition
    end
  end

  defp percentage_attempt_partition(total_words) do
    attempt_tree = share(total_words, @attempt_tree_percent, @partition_percent_base)
    coordinator = share(total_words, @coordinator_percent, @partition_percent_base)
    callback = share(total_words, @callback_percent, @partition_percent_base)
    dns = share(total_words, @dns_percent, @partition_percent_base)
    socket = share(total_words, @socket_percent, @partition_percent_base)
    relay = share(total_words, @relay_percent, @partition_percent_base)
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

  defp floored_dns_attempt_partition(total_words) do
    rest = total_words - @dns_role_heap_floor
    attempt_tree = share(rest, @attempt_tree_percent, @non_dns_partition_percent)
    coordinator = share(rest, @coordinator_percent, @non_dns_partition_percent)
    callback = share(rest, @callback_percent, @non_dns_partition_percent)
    socket = share(rest, @socket_percent, @non_dns_partition_percent)
    relay = share(rest, @relay_percent, @non_dns_partition_percent)
    codec = rest - attempt_tree - coordinator - callback - socket - relay

    %{
      attempt_tree: attempt_tree,
      coordinator: coordinator,
      codec: codec,
      callback: callback,
      dns: @dns_role_heap_floor,
      socket: socket,
      relay: relay
    }
  end

  defp share(total, percent, base), do: div(total * percent, base)

  def set_max_heap(words) when is_integer(words) and words > 0 do
    Process.flag(:max_heap_size, %{size: words, kill: true, error_logger: false})
    :ok
  end
end
