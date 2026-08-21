defmodule PtcLlmHttp.Codecs.OpenAI do
  @moduledoc false

  alias Jason.OrderedObject
  alias PtcLlmHttp.{Error, JsonSchema, Limits, Request, Response, Target, ToolCall, Usage}
  alias PtcLlmHttp.Http.Response, as: HttpResponse

  @maximum_json_depth Limits.json_depth()
  @maximum_json_nodes Limits.json_nodes()
  @maximum_tool_calls Limits.tool_calls()
  @maximum_tool_name_bytes Limits.tool_name_bytes()
  @maximum_tool_id_bytes Limits.tool_call_id_bytes()
  @maximum_argument_bytes Limits.tool_argument_bytes()

  @provider_codes %{
    "credit_balance_exhausted" => :credit_balance_exhausted,
    "organization_spend_limit_exceeded" => :organization_spend_limit_exceeded,
    "organization_usage_limit_exceeded" => :organization_usage_limit_exceeded,
    "project_spend_limit_exceeded" => :project_spend_limit_exceeded
  }

  @spec encode(Target.t(), Request.t()) :: {:ok, binary()} | {:error, Error.t()}
  def encode(target, request) do
    target_options = Target.codec_options(target)
    request_facts = Request.facts(request)

    with :ok <- supported(target_options, request_facts),
         object = body_object(target_options.model, request_facts),
         {:ok, expected_bytes} <-
           bounded_encoded_size(object, target_options.max_encoded_request_bytes),
         object = materialize_json_strings(object),
         {:ok, body} <- Jason.encode(object),
         true <- byte_size(body) == expected_bytes do
      {:ok, body}
    else
      {:error, %Error{}} = error -> error
      _invalid -> {:error, request_error()}
    end
  rescue
    _external_input -> {:error, request_error()}
  end

  @doc false
  @spec decode_context(Request.t()) :: %{
          tools: map(),
          response_schema: nil | :json_object | map()
        }
  def decode_context(request) do
    request = Request.facts(request)

    %{
      tools: Map.new(request.tools, &{&1.name, &1.parameters}),
      response_schema: request.response_schema
    }
  end

  @spec decode(Target.t(), map(), non_neg_integer(), HttpResponse.t()) ::
          {:ok, Response.t()} | {:error, Error.t()}
  def decode(target, decode_context, encoded_request_bytes, response) do
    facts = HttpResponse.facts(response)

    if facts.status in 200..299 do
      decode_success(target, decode_context, encoded_request_bytes, response, facts)
    else
      decode_http_error(response, facts)
    end
  rescue
    _external_input -> {:error, malformed_error(facts_status(response))}
  end

  defp supported(%{kind: :openai_compat, codec_version: "openai-compat-v1"} = target, request) do
    cond do
      target.upstream_routing == :single_provider ->
        {:error, Error.build!(:unsupported_capability, :encode, :model, :not_sent)}

      request.cache and target.cache_mode == :unsupported ->
        {:error, Error.build!(:unsupported_capability, :encode, :request, :not_sent)}

      request.cache ->
        {:error, Error.build!(:unsupported_capability, :encode, :request, :not_sent)}

      request.tools != [] and not target.tools ->
        {:error, Error.build!(:unsupported_capability, :encode, :model, :not_sent)}

      is_map(request.response_schema) and target.structured_output != :json_schema ->
        {:error, Error.build!(:unsupported_capability, :encode, :model, :not_sent)}

      request.response_schema == :json_object and target.structured_output != :json_object ->
        {:error, Error.build!(:unsupported_capability, :encode, :model, :not_sent)}

      true ->
        :ok
    end
  end

  defp supported(_target, _request),
    do: {:error, Error.build!(:unsupported_capability, :encode, :model, :not_sent)}

  defp body_object(model, request) do
    messages =
      case request.system do
        nil -> request.messages
        system -> [%{role: :system, content: system} | request.messages]
      end

    fields = [
      {"model", model},
      {"messages", Enum.map(messages, &message_object/1)},
      {"n", 1},
      {"stream", false}
    ]

    fields = optional_field(fields, "max_tokens", request.max_tokens)
    fields = optional_field(fields, "temperature", request.temperature)
    fields = optional_field(fields, "seed", request.seed)
    fields = optional_tools(fields, request.tools)
    fields = optional_response_format(fields, request.response_schema)
    OrderedObject.new(fields)
  end

  defp message_object(%{role: :assistant, content: content, tool_calls: calls}) do
    OrderedObject.new([
      {"role", "assistant"},
      {"content", content},
      {"tool_calls", Enum.map(calls, &assistant_call_object/1)}
    ])
  end

  defp message_object(%{role: :tool, tool_call_id: id, content: content}) do
    OrderedObject.new([{"role", "tool"}, {"tool_call_id", id}, {"content", content}])
  end

  defp message_object(%{role: role, content: content}) do
    OrderedObject.new([{"role", Atom.to_string(role)}, {"content", content}])
  end

  defp assistant_call_object(call) do
    OrderedObject.new([
      {"id", call.id},
      {"type", "function"},
      {"function",
       OrderedObject.new([{"name", call.name}, {"arguments", {:json_string, call.args}}])}
    ])
  end

  defp optional_tools(fields, []), do: fields

  defp optional_tools(fields, tools) do
    encoded_tools =
      Enum.map(tools, fn tool ->
        function_fields = [{"name", tool.name}]
        function_fields = optional_field(function_fields, "description", tool.description)

        function =
          OrderedObject.new(
            function_fields ++
              [{"parameters", {:json_value, tool.parameters}}, {"strict", true}]
          )

        OrderedObject.new([{"type", "function"}, {"function", function}])
      end)

    fields ++ [{"tools", encoded_tools}]
  end

  defp optional_response_format(fields, nil), do: fields

  defp optional_response_format(fields, :json_object) do
    fields ++ [{"response_format", OrderedObject.new([{"type", "json_object"}])}]
  end

  defp optional_response_format(fields, response_schema) do
    json_schema =
      OrderedObject.new([
        {"name", response_schema.name},
        {"strict", true},
        {"schema", {:json_value, response_schema.schema}}
      ])

    fields ++
      [
        {"response_format",
         OrderedObject.new([{"type", "json_schema"}, {"json_schema", json_schema}])}
      ]
  end

  defp optional_field(fields, _name, nil), do: fields
  defp optional_field(fields, name, value), do: fields ++ [{name, value}]

  defp bounded_encoded_size(%OrderedObject{values: values}, maximum) do
    bounded_members_size(values, maximum, 2, true)
  end

  defp bounded_encoded_size({:json_string, value}, maximum) do
    case JsonSchema.encoded_as_string_size(value, maximum) do
      {:ok, size} -> {:ok, size}
      :error -> {:error, :too_large}
    end
  end

  defp bounded_encoded_size({:json_value, value}, maximum) do
    case JsonSchema.encoded_size(value, maximum) do
      {:ok, size} -> {:ok, size}
      :error -> {:error, :too_large}
    end
  end

  defp bounded_encoded_size(values, maximum) when is_list(values) do
    bounded_items_size(values, maximum, 2, true)
  end

  defp bounded_encoded_size(value, maximum) when is_binary(value),
    do: bounded_json_string_size(value, maximum, 2)

  defp bounded_encoded_size(nil, maximum), do: fixed_size(4, maximum)
  defp bounded_encoded_size(true, maximum), do: fixed_size(4, maximum)
  defp bounded_encoded_size(false, maximum), do: fixed_size(5, maximum)

  defp bounded_encoded_size(value, maximum) when is_integer(value),
    do: fixed_size(integer_size(value), maximum)

  defp bounded_encoded_size(value, maximum) when is_float(value) do
    case Jason.encode(value) do
      {:ok, encoded} -> fixed_size(byte_size(encoded), maximum)
      {:error, _reason} -> {:error, :invalid_number}
    end
  end

  defp bounded_members_size([], maximum, size, _first?) when size <= maximum, do: {:ok, size}

  defp bounded_members_size([{key, value} | rest], maximum, size, first?) do
    separator = if first?, do: 0, else: 1

    with {:ok, size} <- add_size(size, separator, maximum),
         {:ok, key_size} <- bounded_encoded_size(key, maximum - size),
         {:ok, size} <- add_size(size, key_size + 1, maximum),
         {:ok, value_size} <- bounded_encoded_size(value, maximum - size),
         {:ok, size} <- add_size(size, value_size, maximum) do
      bounded_members_size(rest, maximum, size, false)
    end
  end

  defp bounded_items_size([], maximum, size, _first?) when size <= maximum, do: {:ok, size}

  defp bounded_items_size([value | rest], maximum, size, first?) do
    separator = if first?, do: 0, else: 1

    with {:ok, size} <- add_size(size, separator, maximum),
         {:ok, value_size} <- bounded_encoded_size(value, maximum - size),
         {:ok, size} <- add_size(size, value_size, maximum) do
      bounded_items_size(rest, maximum, size, false)
    end
  end

  defp add_size(size, addition, maximum) when size + addition <= maximum,
    do: {:ok, size + addition}

  defp add_size(_size, _addition, _maximum), do: {:error, :too_large}

  defp fixed_size(size, maximum) when size <= maximum, do: {:ok, size}
  defp fixed_size(_size, _maximum), do: {:error, :too_large}

  defp integer_size(value) when value < 0, do: 1 + positive_integer_size(-value, 1)
  defp integer_size(value), do: positive_integer_size(value, 1)

  defp positive_integer_size(value, size) when value < 10, do: size
  defp positive_integer_size(value, size), do: positive_integer_size(div(value, 10), size + 1)

  defp bounded_json_string_size(<<>>, maximum, size), do: fixed_size(size, maximum)

  defp bounded_json_string_size(<<byte, rest::binary>>, maximum, size) do
    encoded_bytes =
      cond do
        byte in [?\b, ?\t, ?\n, ?\f, ?\r] -> 2
        byte < 0x20 -> 6
        byte in [?\", ?\\] -> 2
        true -> 1
      end

    with {:ok, next_size} <- add_size(size, encoded_bytes, maximum) do
      bounded_json_string_size(rest, maximum, next_size)
    end
  end

  defp materialize_json_strings(%OrderedObject{values: values}) do
    values
    |> Enum.map(fn {key, value} -> {key, materialize_json_strings(value)} end)
    |> OrderedObject.new()
  end

  defp materialize_json_strings(values) when is_list(values),
    do: Enum.map(values, &materialize_json_strings/1)

  defp materialize_json_strings({:json_string, value}),
    do: Jason.encode!(JsonSchema.ordered(value))

  defp materialize_json_strings({:json_value, value}), do: JsonSchema.ordered(value)

  defp materialize_json_strings(value), do: value

  defp decode_success(target, decode_context, encoded_request_bytes, response, facts) do
    status = facts.status

    with :ok <- json_content_type(facts.content_type),
         {:ok, decoded} <- decode_json(HttpResponse.body(response), status),
         :ok <- bounded_json(decoded),
         {:ok, content, tool_calls} <- result(decoded, decode_context),
         {:ok, usage} <- usage(decoded, Target.codec_options(target).usage_guarantees) do
      metadata = %{
        status: status,
        encoded_request_bytes: encoded_request_bytes,
        response_bytes: facts.wire_bytes,
        informational_responses: facts.informational_responses,
        trailer_fields: facts.trailer_fields
      }

      {:ok, Response.new(content, tool_calls, usage, metadata)}
    else
      {:error, :too_large} -> {:error, result_too_large_error(status)}
      {:error, :invalid_tool_arguments} -> {:error, tool_arguments_error(status)}
      {:error, :model_refusal} -> {:error, model_refusal_error(status)}
      {:error, error} -> decode_error(error, status)
    end
  end

  defp decode_http_error(response, facts) do
    provider_code =
      with :ok <- json_content_type(facts.content_type),
           {:ok, decoded} <- Jason.decode(HttpResponse.body(response)),
           :ok <- bounded_json(decoded),
           %{"error" => %{"code" => code}} when is_binary(code) <- decoded do
        if facts.status == 429, do: Map.get(@provider_codes, code)
      else
        _unknown -> nil
      end

    {:error,
     Error.build!(:http_status, :decode, :provider, :completed, facts.status, provider_code)}
  end

  defp result(decoded, %{response_schema: nil} = request) do
    ordinary_result(decoded, request)
  end

  defp result(decoded, %{response_schema: response_schema} = request) do
    case ordinary_result(decoded, request) do
      {:ok, content, tool_calls} -> structured_or_tools(content, tool_calls, response_schema)
      {:error, reason} -> {:error, reason}
    end
  end

  defp structured_or_tools(content, [_ | _] = tool_calls, _response_schema),
    do: {:ok, content, tool_calls}

  defp structured_or_tools(content, [], response_schema) do
    with {:ok, value} <- Jason.decode(content),
         :ok <- bounded_json(value),
         true <- is_map(value),
         true <- structured_match?(value, response_schema),
         {:ok, canonical} <- Jason.encode(JsonSchema.ordered(value)) do
      {:ok, canonical, []}
    else
      {:error, :too_large} -> {:error, :too_large}
      _invalid -> {:error, :invalid_structured_output}
    end
  end

  defp structured_match?(_value, :json_object), do: true

  defp structured_match?(value, response_schema),
    do: JsonSchema.matches?(value, response_schema.schema)

  defp ordinary_result(
         %{
           "choices" => [
             %{
               "index" => 0,
               "message" => %{"role" => "assistant", "content" => content} = message
             }
           ]
         },
         request
       ) do
    with :ok <- refusal(message),
         false <- Map.has_key?(message, "function_call"),
         {:ok, tool_calls} <- tool_calls(Map.get(message, "tool_calls"), request.tools),
         {:ok, content} <- result_content(content, tool_calls) do
      {:ok, content, tool_calls}
    else
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :invalid_content}
    end
  end

  defp ordinary_result(_decoded, _request), do: {:error, :invalid_choices}

  defp refusal(%{"refusal" => nil}), do: :ok

  defp refusal(%{"refusal" => refusal}) when is_binary(refusal) and byte_size(refusal) > 0,
    do: {:error, :model_refusal}

  defp refusal(%{"refusal" => _invalid}), do: {:error, :invalid_refusal}
  defp refusal(_message), do: :ok

  defp result_content(content, []) when is_binary(content) do
    if String.valid?(content), do: {:ok, content}, else: {:error, :invalid_content}
  end

  defp result_content(content, [_ | _]) when is_nil(content), do: {:ok, ""}

  defp result_content(content, [_ | _]) when is_binary(content) do
    if String.valid?(content), do: {:ok, content}, else: {:error, :invalid_content}
  end

  defp result_content(_content, _tool_calls), do: {:error, :invalid_content}

  defp tool_calls(nil, _declared), do: {:ok, []}
  defp tool_calls([], _declared), do: {:ok, []}

  defp tool_calls(calls, declared)
       when is_list(calls) and length(calls) in 1..@maximum_tool_calls do
    Enum.reduce_while(calls, {:ok, [], MapSet.new(), 0}, fn call,
                                                            {:ok, normalized, ids, total_bytes} ->
      case tool_call(call, declared, ids, total_bytes) do
        {:ok, tool_call, ids, total_bytes} ->
          {:cont, {:ok, [tool_call | normalized], ids, total_bytes}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, normalized, _ids, _bytes} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp tool_calls(calls, _declared) when is_list(calls) and length(calls) > @maximum_tool_calls,
    do: {:error, :too_large}

  defp tool_calls(_calls, _declared), do: {:error, :invalid_tool_calls}

  defp tool_call(
         %{
           "id" => id,
           "type" => "function",
           "function" => %{"name" => name, "arguments" => arguments} = function
         } = call,
         declared,
         ids,
         total_bytes
       )
       when map_size(call) == 3 and map_size(function) == 2 and is_binary(arguments) do
    with :ok <- bounded_identifier(id, @maximum_tool_id_bytes),
         :ok <- tool_name(name),
         :ok <- unique_id(id, ids),
         {:ok, schema} <- declared_schema(name, declared),
         :ok <- argument_size(arguments, total_bytes),
         {:ok, decoded} <- decode_arguments(arguments, schema) do
      {:ok, ToolCall.new(id, name, decoded), MapSet.put(ids, id),
       total_bytes + byte_size(arguments)}
    else
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :invalid_tool_calls}
    end
  end

  defp tool_call(
         %{
           "id" => _id,
           "type" => "function",
           "function" => %{"name" => _name, "arguments" => arguments} = function
         } = call,
         _declared,
         _ids,
         _total_bytes
       )
       when map_size(call) == 3 and map_size(function) == 2 and not is_binary(arguments),
       do: {:error, :invalid_tool_arguments}

  defp tool_call(
         %{
           "id" => _id,
           "type" => "function",
           "function" => %{"name" => _name} = function
         } = call,
         _declared,
         _ids,
         _total_bytes
       )
       when map_size(call) == 3 and map_size(function) == 1,
       do: {:error, :invalid_tool_arguments}

  defp tool_call(_call, _declared, _ids, _total_bytes),
    do: {:error, :invalid_tool_calls}

  defp unique_id(id, ids) do
    if MapSet.member?(ids, id), do: {:error, :invalid_tool_calls}, else: :ok
  end

  defp declared_schema(name, declared) do
    case Map.fetch(declared, name) do
      {:ok, schema} -> {:ok, schema}
      :error -> {:error, :invalid_tool_calls}
    end
  end

  defp argument_size(arguments, total_bytes) do
    if byte_size(arguments) <= @maximum_argument_bytes and
         total_bytes + byte_size(arguments) <= @maximum_argument_bytes,
       do: :ok,
       else: {:error, :too_large}
  end

  defp decode_arguments(arguments, schema) do
    with {:ok, decoded} <- Jason.decode(arguments),
         true <- is_map(decoded),
         :ok <- bounded_json(decoded),
         true <- JsonSchema.matches?(decoded, schema) do
      {:ok, decoded}
    else
      {:error, :too_large} -> {:error, :too_large}
      _invalid -> {:error, :invalid_tool_arguments}
    end
  end

  defp bounded_identifier(value, maximum)
       when is_binary(value) and byte_size(value) > 0 and byte_size(value) <= maximum do
    if String.valid?(value) and Enum.all?(:binary.bin_to_list(value), &(&1 > 31 and &1 != 127)),
      do: :ok,
      else: :error
  end

  defp bounded_identifier(value, maximum) when is_binary(value) and byte_size(value) > maximum,
    do: {:error, :too_large}

  defp bounded_identifier(_value, _maximum), do: :error

  defp tool_name(value) when is_binary(value) and byte_size(value) <= @maximum_tool_name_bytes do
    if byte_size(value) > 0 and
         Enum.all?(:binary.bin_to_list(value), fn byte ->
           byte in ?A..?Z or byte in ?a..?z or byte in ?0..?9 or byte in [?_, ?-]
         end),
       do: :ok,
       else: :error
  end

  defp tool_name(value) when is_binary(value) and byte_size(value) > @maximum_tool_name_bytes,
    do: {:error, :too_large}

  defp tool_name(_value), do: :error

  defp usage(decoded, guarantees) do
    with {:ok, usage} <- optional_usage(Map.get(decoded, "usage")),
         true <- usage_guarantees?(usage, guarantees) do
      {:ok, usage}
    else
      _invalid -> {:error, :invalid_usage}
    end
  end

  defp optional_usage(nil), do: {:ok, nil}

  defp optional_usage(%{} = usage) do
    prompt = Map.get(usage, "prompt_tokens")
    completion = Map.get(usage, "completion_tokens")
    total = Map.get(usage, "total_tokens")
    cost = Map.get(usage, "cost")
    cached = get_in(usage, ["prompt_tokens_details", "cached_tokens"])

    if optional_non_negative_integer?(prompt) and optional_non_negative_integer?(completion) and
         optional_non_negative_integer?(total) and optional_non_negative_integer?(cached) and
         optional_non_negative_number?(cost) and token_total_valid?(prompt, completion, total) and
         cached_tokens_valid?(cached, prompt) do
      {:ok,
       Usage.new(
         prompt_tokens: prompt,
         completion_tokens: completion,
         total_tokens: total,
         cached_tokens: cached,
         cost: cost
       )}
    else
      {:error, :invalid_usage}
    end
  end

  defp optional_usage(_usage), do: {:error, :invalid_usage}

  defp usage_guarantees?(nil, %{tokens: false, cost: false}), do: true
  defp usage_guarantees?(nil, _guarantees), do: false

  defp usage_guarantees?(usage, guarantees) do
    usage = Usage.facts(usage)

    (not guarantees.tokens or
       Enum.all?(
         [usage.prompt_tokens, usage.completion_tokens, usage.total_tokens],
         &is_integer/1
       )) and
      (not guarantees.cost or is_number(usage.cost))
  end

  defp token_total_valid?(nil, nil, nil), do: true

  defp token_total_valid?(prompt, completion, total)
       when is_integer(prompt) and is_integer(completion) and is_integer(total),
       do: prompt + completion == total

  defp token_total_valid?(_prompt, _completion, _total), do: false

  defp cached_tokens_valid?(nil, _prompt), do: true

  defp cached_tokens_valid?(cached, prompt)
       when is_integer(cached) and is_integer(prompt),
       do: cached <= prompt

  defp cached_tokens_valid?(_cached, _prompt), do: false

  defp optional_non_negative_integer?(nil), do: true
  defp optional_non_negative_integer?(value), do: is_integer(value) and value >= 0

  defp optional_non_negative_number?(nil), do: true
  defp optional_non_negative_number?(value), do: is_number(value) and value >= 0

  defp decode_json(body, status) do
    case Jason.decode(body) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _reason} -> {:error, malformed_error(status)}
    end
  end

  defp bounded_json(value) do
    case count_json(value, 0, 0) do
      {:ok, _nodes} -> :ok
      {:error, _limit} -> {:error, :too_large}
    end
  end

  defp count_json(_value, depth, _nodes) when depth > @maximum_json_depth,
    do: {:error, :depth}

  defp count_json(_value, _depth, nodes) when nodes >= @maximum_json_nodes,
    do: {:error, :nodes}

  defp count_json(value, depth, nodes) when is_map(value) do
    Enum.reduce_while(value, {:ok, nodes + 1}, fn {key, item}, {:ok, count} ->
      with {:ok, count} <- count_json(key, depth + 1, count),
           {:ok, count} <- count_json(item, depth + 1, count) do
        {:cont, {:ok, count}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp count_json(value, depth, nodes) when is_list(value) do
    Enum.reduce_while(value, {:ok, nodes + 1}, fn item, {:ok, count} ->
      case count_json(item, depth + 1, count) do
        {:ok, count} -> {:cont, {:ok, count}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp count_json(_scalar, _depth, nodes), do: {:ok, nodes + 1}

  defp json_content_type(value) when is_binary(value) do
    media_type =
      value
      |> :binary.split(";", [:global])
      |> hd()
      |> String.trim()
      |> String.downcase()

    if media_type == "application/json", do: :ok, else: {:error, :invalid_content_type}
  end

  defp json_content_type(_value), do: {:error, :invalid_content_type}

  defp facts_status(response) do
    response |> HttpResponse.facts() |> Map.fetch!(:status)
  rescue
    _invalid -> 200
  end

  defp request_error,
    do: Error.build!(:invalid_request, :encode, :request, :not_sent)

  defp malformed_error(status),
    do: Error.build!(:malformed_provider_response, :decode, :provider, :completed, status, nil)

  defp result_too_large_error(status),
    do: Error.build!(:provider_result_too_large, :decode, :provider, :completed, status, nil)

  defp tool_arguments_error(status),
    do: Error.build!(:invalid_tool_arguments, :decode, :provider, :completed, status, nil)

  defp model_refusal_error(status),
    do: Error.build!(:model_refusal, :decode, :model, :completed, status, nil)

  defp decode_error(error, status) do
    case Error.validate(error) do
      {:ok, error} -> {:error, error}
      :error -> {:error, malformed_error(status)}
    end
  end
end
