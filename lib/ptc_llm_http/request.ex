defmodule PtcLlmHttp.Request do
  @moduledoc """
  Validated provider-neutral request for bounded calls and text streams.

  Requests may contain text messages, strict function tools, assistant tool-call
  replay, tool results, and one strict structured-output schema. Inspection is
  wholly redacted because prompts, schemas, and tool arguments may be private.
  """

  alias PtcLlmHttp.{Error, JsonSchema, Limits}

  @maximum_messages Limits.messages()
  @maximum_tools Limits.tools()
  @maximum_tool_calls Limits.tool_calls()
  @maximum_text_bytes Limits.encoded_request_bytes()
  @maximum_tool_name_bytes Limits.tool_name_bytes()
  @maximum_tool_id_bytes Limits.tool_call_id_bytes()
  @maximum_description_bytes Limits.tool_description_bytes()
  @maximum_argument_bytes Limits.tool_argument_bytes()
  @maximum_schema_name_bytes Limits.schema_name_bytes()
  @minimum_integer_parameter Limits.integer_parameter_min()
  @maximum_integer_parameter Limits.integer_parameter_max()

  @enforce_keys [
    :system,
    :messages,
    :tools,
    :response_schema,
    :max_tokens,
    :temperature,
    :seed,
    :cache
  ]
  defstruct @enforce_keys

  @opaque t :: %__MODULE__{}
  @keys [
    :system,
    :messages,
    :tools,
    :response_schema,
    :max_tokens,
    :temperature,
    :seed,
    :cache
  ]

  @doc "Validates a bounded request without model or transport options."
  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(options) when is_list(options) do
    with :ok <- options(options),
         {:ok, system} <- optional_text(Keyword.get(options, :system)),
         {:ok, tools} <- tools(Keyword.get(options, :tools, [])),
         {:ok, messages} <- messages(Keyword.get(options, :messages), tools),
         {:ok, response_schema} <- response_schema(Keyword.get(options, :response_schema)),
         {:ok, max_tokens} <- optional_positive_integer(Keyword.get(options, :max_tokens)),
         {:ok, temperature} <- temperature(Keyword.get(options, :temperature)),
         {:ok, seed} <- optional_integer(Keyword.get(options, :seed)),
         {:ok, cache} <- boolean(Keyword.get(options, :cache, false)) do
      {:ok,
       struct!(__MODULE__,
         system: system,
         messages: messages,
         tools: tools,
         response_schema: response_schema,
         max_tokens: max_tokens,
         temperature: temperature,
         seed: seed,
         cache: cache
       )}
    else
      _invalid -> invalid()
    end
  rescue
    _external_input -> invalid()
  end

  def new(_options), do: invalid()

  @doc false
  def facts(%__MODULE__{} = request) do
    %{
      system: request.system,
      messages: request.messages,
      tools: request.tools,
      response_schema: request.response_schema,
      max_tokens: request.max_tokens,
      temperature: request.temperature,
      seed: request.seed,
      cache: request.cache
    }
  end

  defp options(options) do
    keys = Keyword.keys(options)

    if Keyword.keyword?(options) and keys == Enum.uniq(keys) and
         Enum.all?(keys, &(&1 in @keys)) and :messages in keys do
      :ok
    else
      {:error, :invalid_options}
    end
  end

  defp tools(tools) when is_list(tools) and length(tools) <= @maximum_tools do
    Enum.reduce_while(tools, {:ok, [], MapSet.new()}, fn tool, {:ok, validated, names} ->
      with {:ok, tool} <- tool(tool),
           false <- MapSet.member?(names, tool.name) do
        {:cont, {:ok, [tool | validated], MapSet.put(names, tool.name)}}
      else
        _invalid -> {:halt, {:error, :invalid_tools}}
      end
    end)
    |> case do
      {:ok, validated, _names} -> {:ok, Enum.reverse(validated)}
      error -> error
    end
  end

  defp tools(_tools), do: {:error, :invalid_tools}

  defp tool(%{name: name, description: description, parameters: parameters} = tool)
       when map_size(tool) == 3 do
    with {:ok, name} <- tool_name(name, @maximum_tool_name_bytes),
         {:ok, description} <- optional_description(description),
         {:ok, parameters} <- JsonSchema.validate(parameters),
         true <- parameters["type"] == "object" do
      {:ok, %{name: name, description: description, parameters: parameters}}
    else
      _invalid -> {:error, :invalid_tool}
    end
  end

  defp tool(_tool), do: {:error, :invalid_tool}

  defp response_schema(nil), do: {:ok, nil}
  defp response_schema(:json_object), do: {:ok, :json_object}

  defp response_schema(%{name: name, schema: schema} = response_schema)
       when map_size(response_schema) == 2 do
    with {:ok, name} <- tool_name(name, @maximum_schema_name_bytes),
         {:ok, schema} <- JsonSchema.validate(schema),
         true <- schema["type"] == "object" do
      {:ok, %{name: name, schema: schema}}
    else
      _invalid -> {:error, :invalid_response_schema}
    end
  end

  defp response_schema(_response_schema), do: {:error, :invalid_response_schema}

  defp messages(messages, tools)
       when is_list(messages) and length(messages) in 1..@maximum_messages do
    tool_schemas = Map.new(tools, &{&1.name, &1.parameters})

    Enum.reduce_while(messages, {:ok, [], %{}, MapSet.new()}, fn message, state ->
      case message(message, state, tool_schemas) do
        {:ok, state} -> {:cont, state}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, validated, outstanding, _seen} when map_size(outstanding) == 0 ->
        {:ok, Enum.reverse(validated)}

      _invalid ->
        {:error, :invalid_messages}
    end
  end

  defp messages(_messages, _tools), do: {:error, :invalid_messages}

  defp message(
         %{role: role, content: content} = message,
         {:ok, validated, outstanding, seen},
         _tools
       )
       when map_size(message) == 2 and role in [:system, :user, :assistant] and
              map_size(outstanding) == 0 do
    with {:ok, content} <- required_text(content) do
      {:ok, {:ok, [%{role: role, content: content} | validated], outstanding, seen}}
    end
  end

  defp message(
         %{role: :assistant, content: content, tool_calls: calls} = message,
         {:ok, validated, outstanding, seen},
         tools
       )
       when map_size(message) == 3 and map_size(outstanding) == 0 and is_list(calls) and
              length(calls) in 1..@maximum_tool_calls do
    with {:ok, content} <- optional_tool_text(content),
         {:ok, calls, outstanding, seen} <- assistant_calls(calls, tools, seen) do
      normalized = %{role: :assistant, content: content, tool_calls: calls}
      {:ok, {:ok, [normalized | validated], outstanding, seen}}
    end
  end

  defp message(
         %{role: :tool, tool_call_id: id, content: content} = message,
         {:ok, validated, outstanding, seen},
         _tools
       )
       when map_size(message) == 3 do
    with {:ok, id} <- tool_id(id),
         true <- Map.has_key?(outstanding, id),
         {:ok, content} <- tool_text(content) do
      normalized = %{role: :tool, tool_call_id: id, content: content}
      {:ok, {:ok, [normalized | validated], Map.delete(outstanding, id), seen}}
    else
      _invalid -> {:error, :invalid_tool_result}
    end
  end

  defp message(_message, _state, _tools), do: {:error, :invalid_message}

  defp assistant_calls(calls, tools, seen) do
    Enum.reduce_while(calls, {:ok, [], %{}, seen}, fn call, {:ok, validated, pending, seen} ->
      with {:ok, call} <- assistant_call(call, tools),
           false <- MapSet.member?(seen, call.id),
           false <- Map.has_key?(pending, call.id) do
        {:cont,
         {:ok, [call | validated], Map.put(pending, call.id, call.name),
          MapSet.put(seen, call.id)}}
      else
        _invalid -> {:halt, {:error, :invalid_tool_calls}}
      end
    end)
    |> case do
      {:ok, validated, pending, seen} -> {:ok, Enum.reverse(validated), pending, seen}
      error -> error
    end
  end

  defp assistant_call(%{id: id, name: name, args: args} = call, tools)
       when map_size(call) == 3 and is_map(args) do
    with {:ok, id} <- tool_id(id),
         {:ok, name} <- tool_name(name, @maximum_tool_name_bytes),
         {:ok, schema} <- Map.fetch(tools, name),
         {:ok, args} <- JsonSchema.json_value(args),
         true <- JsonSchema.matches?(args, schema),
         {:ok, _encoded_size} <- JsonSchema.encoded_size(args, @maximum_argument_bytes) do
      {:ok, %{id: id, name: name, args: args}}
    else
      _invalid -> {:error, :invalid_tool_call}
    end
  end

  defp assistant_call(_call, _tools), do: {:error, :invalid_tool_call}

  defp tool_name(value, maximum)
       when is_binary(value) and byte_size(value) > 0 and byte_size(value) <= maximum do
    if String.valid?(value) and
         Enum.all?(:binary.bin_to_list(value), fn byte ->
           byte in ?A..?Z or byte in ?a..?z or byte in ?0..?9 or byte in [?_, ?-]
         end) do
      {:ok, value}
    else
      {:error, :invalid_name}
    end
  end

  defp tool_name(_value, _maximum), do: {:error, :invalid_name}

  defp tool_id(value)
       when is_binary(value) and byte_size(value) > 0 and
              byte_size(value) <= @maximum_tool_id_bytes do
    if String.valid?(value) and visible?(value), do: {:ok, value}, else: {:error, :invalid_id}
  end

  defp tool_id(_value), do: {:error, :invalid_id}

  defp optional_description(nil), do: {:ok, nil}

  defp optional_description(value)
       when is_binary(value) and byte_size(value) > 0 and
              byte_size(value) <= @maximum_description_bytes do
    if String.valid?(value), do: {:ok, value}, else: {:error, :invalid_description}
  end

  defp optional_description(_value), do: {:error, :invalid_description}

  defp optional_text(nil), do: {:ok, nil}
  defp optional_text(value), do: required_text(value)

  defp optional_tool_text(nil), do: {:ok, nil}
  defp optional_tool_text(value), do: tool_text(value)

  defp tool_text(value)
       when is_binary(value) and byte_size(value) <= @maximum_text_bytes do
    if String.valid?(value), do: {:ok, value}, else: {:error, :invalid_text}
  end

  defp tool_text(_value), do: {:error, :invalid_text}

  defp required_text(value)
       when is_binary(value) and byte_size(value) > 0 and
              byte_size(value) <= @maximum_text_bytes do
    if String.valid?(value), do: {:ok, value}, else: {:error, :invalid_text}
  end

  defp required_text(_value), do: {:error, :invalid_text}

  defp optional_positive_integer(nil), do: {:ok, nil}

  defp optional_positive_integer(value)
       when is_integer(value) and value > 0 and value <= @maximum_integer_parameter,
       do: {:ok, value}

  defp optional_positive_integer(_value), do: {:error, :invalid_max_tokens}

  defp optional_integer(nil), do: {:ok, nil}

  defp optional_integer(value)
       when is_integer(value) and value >= @minimum_integer_parameter and
              value <= @maximum_integer_parameter,
       do: {:ok, value}

  defp optional_integer(_value), do: {:error, :invalid_seed}

  defp temperature(nil), do: {:ok, nil}

  defp temperature(value) when is_number(value) and value >= 0 and value <= 2,
    do: {:ok, value}

  defp temperature(_value), do: {:error, :invalid_temperature}

  defp boolean(value) when is_boolean(value), do: {:ok, value}
  defp boolean(_value), do: {:error, :invalid_boolean}

  defp visible?(value), do: Enum.all?(:binary.bin_to_list(value), &(&1 > 31 and &1 != 127))

  defp invalid, do: {:error, Error.build!(:invalid_request, :validate, :request, :not_sent)}
end

defimpl Inspect, for: PtcLlmHttp.Request do
  def inspect(_request, _options), do: "#PtcLlmHttp.Request<redacted>"
end
