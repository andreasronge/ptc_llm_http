defmodule PtcLlmHttp.Codecs.OpenAI do
  @moduledoc false

  alias Jason.OrderedObject
  alias PtcLlmHttp.{Error, Limits, Request, Response, Target, Usage}
  alias PtcLlmHttp.Http.Response, as: HttpResponse

  @maximum_json_depth Limits.json_depth()
  @maximum_json_nodes Limits.json_nodes()

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

  @spec decode(Target.t(), non_neg_integer(), HttpResponse.t()) ::
          {:ok, Response.t()} | {:error, Error.t()}
  def decode(target, encoded_request_bytes, response) do
    facts = HttpResponse.facts(response)

    if facts.status in 200..299 do
      decode_success(target, encoded_request_bytes, response, facts)
    else
      decode_http_error(response, facts)
    end
  rescue
    _external_input -> {:error, malformed_error(facts_status(response))}
  end

  defp supported(%{kind: :openai_compat, codec_version: "openai-compat-v1"} = target, request) do
    cond do
      request.cache and target.cache_mode == :unsupported ->
        {:error, Error.build!(:unsupported_capability, :encode, :request, :not_sent)}

      request.cache ->
        {:error, Error.build!(:unsupported_capability, :encode, :request, :not_sent)}

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
    OrderedObject.new(fields)
  end

  defp message_object(%{role: role, content: content}) do
    OrderedObject.new([{"role", Atom.to_string(role)}, {"content", content}])
  end

  defp optional_field(fields, _name, nil), do: fields
  defp optional_field(fields, name, value), do: fields ++ [{name, value}]

  defp bounded_encoded_size(%OrderedObject{values: values}, maximum) do
    bounded_members_size(values, maximum, 2, true)
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

  defp decode_success(target, encoded_request_bytes, response, facts) do
    status = facts.status

    with :ok <- json_content_type(facts.content_type),
         {:ok, decoded} <- decode_json(HttpResponse.body(response), status),
         :ok <- bounded_json(decoded),
         {:ok, content} <- content(decoded),
         {:ok, usage} <- usage(decoded, Target.codec_options(target).usage_guarantees) do
      metadata = %{
        status: status,
        encoded_request_bytes: encoded_request_bytes,
        response_bytes: facts.wire_bytes,
        informational_responses: facts.informational_responses,
        trailer_fields: facts.trailer_fields
      }

      {:ok, Response.new(content, usage, metadata)}
    else
      {:error, :too_large} -> {:error, result_too_large_error(status)}
      {:error, %Error{}} = error -> error
      _invalid -> {:error, malformed_error(status)}
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

  defp content(%{
         "choices" => [
           %{"index" => 0, "message" => %{"role" => "assistant", "content" => content} = message}
         ]
       })
       when is_binary(content) do
    if String.valid?(content) and tool_calls_absent?(message),
      do: {:ok, content},
      else: {:error, :invalid_content}
  end

  defp content(_decoded), do: {:error, :invalid_choices}

  defp tool_calls_absent?(message),
    do: Map.get(message, "tool_calls") in [nil, []] and not Map.has_key?(message, "function_call")

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
         optional_non_negative_number?(cost) and token_total_valid?(prompt, completion, total) do
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
end
