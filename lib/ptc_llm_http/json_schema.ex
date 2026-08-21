defmodule PtcLlmHttp.JsonSchema do
  @moduledoc false

  alias Jason.OrderedObject
  alias PtcLlmHttp.Limits

  @types ~w(object array string number integer boolean null)
  @common_keys ~w(type description enum)
  @object_keys ~w(properties required additionalProperties)
  @array_keys ~w(items)
  @maximum_schema_depth Limits.schema_depth()
  @maximum_json_depth Limits.json_depth()
  @maximum_nodes Limits.json_nodes()
  @maximum_property_bytes Limits.schema_property_bytes()
  @maximum_description_bytes Limits.tool_description_bytes()
  @maximum_enum_values Limits.schema_enum_values()
  @maximum_properties Limits.schema_properties()
  @maximum_string_characters Limits.schema_string_characters()
  @maximum_total_enum_values Limits.schema_total_enum_values()

  @spec validate(term()) :: {:ok, map()} | :error
  def validate(schema) do
    with {:ok, schema, facts} <- schema(schema, 0, %{properties: 0, enum_values: 0}),
         {:ok, nodes} <- count_value(schema, 0, 0),
         true <- nodes <= @maximum_nodes,
         {:ok, characters} <- string_characters(schema, 0),
         true <- characters <= @maximum_string_characters,
         true <- facts.properties <= @maximum_properties,
         true <- facts.enum_values <= @maximum_total_enum_values do
      {:ok, schema}
    else
      _invalid -> :error
    end
  rescue
    _external_input -> :error
  end

  @spec matches?(term(), map()) :: boolean()
  def matches?(value, schema) do
    match_value?(value, schema) and enum_matches?(value, schema)
  rescue
    _external_input -> false
  end

  @spec json_value(term()) :: {:ok, term()} | :error
  def json_value(value) do
    case count_value(value, 0, 0) do
      {:ok, nodes} when nodes <= @maximum_nodes -> {:ok, value}
      _invalid -> :error
    end
  rescue
    _external_input -> :error
  end

  @spec encoded_size(term(), non_neg_integer()) :: {:ok, non_neg_integer()} | :error
  def encoded_size(value, maximum) when is_integer(maximum) and maximum >= 0 do
    measure(value, 0, maximum, false)
  rescue
    _external_input -> :error
  end

  def encoded_size(_value, _maximum), do: :error

  @spec encoded_as_string_size(term(), non_neg_integer()) ::
          {:ok, non_neg_integer()} | :error
  def encoded_as_string_size(value, maximum) when is_integer(maximum) and maximum >= 0 do
    with {:ok, size} <- add_emitted(0, <<?">>, maximum, false),
         {:ok, size} <- measure(value, size, maximum, true) do
      add_emitted(size, <<?">>, maximum, false)
    end
  rescue
    _external_input -> :error
  end

  def encoded_as_string_size(_value, _maximum), do: :error

  @spec ordered(term()) :: term()
  def ordered(value) when is_map(value) do
    value
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {key, item} -> {key, ordered(item)} end)
    |> OrderedObject.new()
  end

  def ordered(value) when is_list(value), do: Enum.map(value, &ordered/1)
  def ordered(value), do: value

  defp schema(schema, depth, facts)
       when is_map(schema) and map_size(schema) > 0 and depth < @maximum_schema_depth do
    with {:ok, schema} <- normalize_known_keys(schema),
         {:ok, type} <- fetch_type(schema),
         :ok <- exact_schema_keys(schema, type),
         {:ok, description} <- optional_description(schema),
         {:ok, normalized, facts} <- type_schema(type, schema, depth, facts),
         {:ok, enum} <- optional_enum(schema, type),
         {:ok, facts} <- add_enum_facts(facts, enum),
         result <- optional_put(normalized, "description", description),
         result <- optional_put(result, "enum", enum) do
      {:ok, result, facts}
    end
  end

  defp schema(_schema, _depth, _facts), do: :error

  defp normalize_known_keys(schema) do
    Enum.reduce_while(schema, {:ok, %{}}, fn
      {key, value}, {:ok, normalized} when is_binary(key) ->
        if key in (@common_keys ++ @object_keys ++ @array_keys) and
             not Map.has_key?(normalized, key),
           do: {:cont, {:ok, Map.put(normalized, key, value)}},
           else: {:halt, :error}

      {key, value}, {:ok, normalized} when is_atom(key) ->
        string_key = Atom.to_string(key)

        if string_key in (@common_keys ++ @object_keys ++ @array_keys) and
             not Map.has_key?(normalized, string_key),
           do: {:cont, {:ok, Map.put(normalized, string_key, value)}},
           else: {:halt, :error}

      _entry, _acc ->
        {:halt, :error}
    end)
  end

  defp fetch_type(%{"type" => type}) when type in @types, do: {:ok, type}
  defp fetch_type(_schema), do: :error

  defp exact_schema_keys(schema, "object"), do: exact_keys(schema, @common_keys ++ @object_keys)
  defp exact_schema_keys(schema, "array"), do: exact_keys(schema, @common_keys ++ @array_keys)
  defp exact_schema_keys(schema, _scalar), do: exact_keys(schema, @common_keys)

  defp exact_keys(schema, allowed) do
    if Enum.all?(Map.keys(schema), &(&1 in allowed)), do: :ok, else: :error
  end

  defp type_schema("object", schema, depth, facts) do
    properties = Map.get(schema, "properties")
    required = Map.get(schema, "required")

    with true <- is_map(properties),
         true <- facts.properties + map_size(properties) <= @maximum_properties,
         true <- Map.get(schema, "additionalProperties") == false,
         {:ok, required} <- required(required, Map.keys(properties)),
         facts = %{facts | properties: facts.properties + map_size(properties)},
         {:ok, properties, facts} <- properties(properties, depth + 1, facts) do
      {:ok,
       %{
         "type" => "object",
         "properties" => properties,
         "required" => required,
         "additionalProperties" => false
       }, facts}
    else
      _invalid -> :error
    end
  end

  defp type_schema("array", %{"items" => items}, depth, facts) do
    with {:ok, items, facts} <- schema(items, depth + 1, facts) do
      {:ok, %{"type" => "array", "items" => items}, facts}
    end
  end

  defp type_schema("array", _schema, _depth, _nodes), do: :error

  defp type_schema(type, _schema, _depth, facts), do: {:ok, %{"type" => type}, facts}

  defp properties(properties, depth, facts) do
    properties
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while({:ok, %{}, facts}, fn
      {name, child}, {:ok, normalized, count}
      when is_binary(name) and byte_size(name) > 0 and
             byte_size(name) <= @maximum_property_bytes ->
        if String.valid?(name) and visible?(name) do
          case schema(child, depth, count) do
            {:ok, child, next_count} ->
              {:cont, {:ok, Map.put(normalized, name, child), next_count}}

            :error ->
              {:halt, :error}
          end
        else
          {:halt, :error}
        end

      _property, _acc ->
        {:halt, :error}
    end)
  end

  defp required(required, property_names) when is_list(required) do
    if Enum.all?(required, &is_binary/1) and length(required) == length(Enum.uniq(required)) and
         Enum.sort(required) == Enum.sort(property_names) do
      {:ok, Enum.sort(required)}
    else
      :error
    end
  end

  defp required(_required, _property_names), do: :error

  defp optional_description(schema) do
    case Map.fetch(schema, "description") do
      :error -> {:ok, nil}
      {:ok, value} -> description(value)
    end
  end

  defp description(value)
       when is_binary(value) and byte_size(value) > 0 and
              byte_size(value) <= @maximum_description_bytes do
    if String.valid?(value), do: {:ok, value}, else: :error
  end

  defp description(_value), do: :error

  defp optional_enum(schema, type) do
    case Map.fetch(schema, "enum") do
      :error -> {:ok, nil}
      {:ok, values} -> enum(values, type)
    end
  end

  defp enum(values, type)
       when is_list(values) and length(values) in 1..@maximum_enum_values do
    if unique_json_values?(values) and
         Enum.all?(values, &scalar_type?(&1, type)) do
      {:ok, values}
    else
      :error
    end
  end

  defp enum(_values, _type), do: :error

  defp add_enum_facts(facts, nil), do: {:ok, facts}

  defp add_enum_facts(facts, values) do
    total = facts.enum_values + length(values)
    if total <= @maximum_total_enum_values, do: {:ok, %{facts | enum_values: total}}, else: :error
  end

  defp string_characters(value, count) when is_map(value) do
    Enum.reduce_while(value, {:ok, count}, fn {key, item}, {:ok, count} ->
      with {:ok, count} <- add_characters(key, count),
           {:ok, count} <- string_characters(item, count) do
        {:cont, {:ok, count}}
      else
        :error -> {:halt, :error}
      end
    end)
  end

  defp string_characters(value, count) when is_list(value) do
    Enum.reduce_while(value, {:ok, count}, fn item, {:ok, count} ->
      case string_characters(item, count) do
        {:ok, count} -> {:cont, {:ok, count}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp string_characters(value, count) when is_binary(value), do: add_characters(value, count)
  defp string_characters(_value, count), do: {:ok, count}

  defp add_characters(value, count) do
    next = count + String.length(value)
    if next <= @maximum_string_characters, do: {:ok, next}, else: :error
  end

  defp optional_put(map, _key, nil), do: map
  defp optional_put(map, key, value), do: Map.put(map, key, value)

  defp match_value?(value, %{"type" => "object", "properties" => properties})
       when is_map(value) do
    Map.keys(value) |> Enum.all?(&is_binary/1) and
      Enum.sort(Map.keys(value)) == Enum.sort(Map.keys(properties)) and
      Enum.all?(properties, fn {name, child} -> matches?(Map.fetch!(value, name), child) end)
  end

  defp match_value?(value, %{"type" => "array", "items" => items}) when is_list(value),
    do: Enum.all?(value, &matches?(&1, items))

  defp match_value?(value, %{"type" => type}), do: scalar_type?(value, type)

  defp enum_matches?(value, %{"enum" => values}),
    do: Enum.any?(values, &json_equal?(&1, value))

  defp enum_matches?(_value, _schema), do: true

  defp scalar_type?(value, "string"), do: is_binary(value) and String.valid?(value)
  defp scalar_type?(value, "number"), do: is_number(value)
  defp scalar_type?(value, "integer") when is_float(value), do: value == trunc(value)
  defp scalar_type?(value, "integer"), do: is_integer(value)
  defp scalar_type?(value, "boolean"), do: is_boolean(value)
  defp scalar_type?(nil, "null"), do: true
  defp scalar_type?(_value, _type), do: false

  defp count_value(_value, depth, _nodes) when depth > @maximum_json_depth, do: :error
  defp count_value(_value, _depth, nodes) when nodes >= @maximum_nodes, do: :error

  defp count_value(value, depth, nodes) when is_map(value) do
    Enum.reduce_while(value, {:ok, nodes + 1}, fn
      {key, item}, {:ok, count} when is_binary(key) ->
        case count_value(item, depth + 1, count) do
          {:ok, next_count} -> {:cont, {:ok, next_count}}
          :error -> {:halt, :error}
        end

      _entry, _acc ->
        {:halt, :error}
    end)
  end

  defp count_value(value, depth, nodes) when is_list(value) do
    Enum.reduce_while(value, {:ok, nodes + 1}, fn item, {:ok, count} ->
      case count_value(item, depth + 1, count) do
        {:ok, next_count} -> {:cont, {:ok, next_count}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp count_value(value, _depth, nodes)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value) do
    if not is_binary(value) or String.valid?(value), do: {:ok, nodes + 1}, else: :error
  end

  defp count_value(_value, _depth, _nodes), do: :error

  defp measure(value, size, maximum, outer?) when is_map(value) do
    with {:ok, size} <- add_emitted(size, "{", maximum, outer?) do
      value
      |> Enum.sort_by(&elem(&1, 0))
      |> measure_members(size, maximum, outer?, true)
    end
  end

  defp measure(value, size, maximum, outer?) when is_list(value) do
    with {:ok, size} <- add_emitted(size, "[", maximum, outer?) do
      measure_items(value, size, maximum, outer?, true)
    end
  end

  defp measure(value, size, maximum, outer?) when is_binary(value) do
    with {:ok, size} <- add_emitted(size, <<?">>, maximum, outer?),
         {:ok, size} <- measure_string(value, size, maximum, outer?) do
      add_emitted(size, <<?">>, maximum, outer?)
    end
  end

  defp measure(nil, size, maximum, outer?), do: add_emitted(size, "null", maximum, outer?)
  defp measure(true, size, maximum, outer?), do: add_emitted(size, "true", maximum, outer?)
  defp measure(false, size, maximum, outer?), do: add_emitted(size, "false", maximum, outer?)

  defp measure(value, size, maximum, outer?) when is_integer(value),
    do: add_emitted(size, Integer.to_string(value), maximum, outer?)

  defp measure(value, size, maximum, outer?) when is_float(value) do
    case Jason.encode(value) do
      {:ok, encoded} -> add_emitted(size, encoded, maximum, outer?)
      {:error, _reason} -> :error
    end
  end

  defp measure(_value, _size, _maximum, _outer?), do: :error

  defp measure_members([], size, maximum, outer?, _first?) do
    add_emitted(size, "}", maximum, outer?)
  end

  defp measure_members([{key, value} | rest], size, maximum, outer?, first?)
       when is_binary(key) do
    separator = if first?, do: "", else: ","

    with {:ok, size} <- add_emitted(size, separator, maximum, outer?),
         {:ok, size} <- measure(key, size, maximum, outer?),
         {:ok, size} <- add_emitted(size, ":", maximum, outer?),
         {:ok, size} <- measure(value, size, maximum, outer?) do
      measure_members(rest, size, maximum, outer?, false)
    end
  end

  defp measure_members(_members, _size, _maximum, _outer?, _first?), do: :error

  defp measure_items([], size, maximum, outer?, _first?) do
    add_emitted(size, "]", maximum, outer?)
  end

  defp measure_items([value | rest], size, maximum, outer?, first?) do
    separator = if first?, do: "", else: ","

    with {:ok, size} <- add_emitted(size, separator, maximum, outer?),
         {:ok, size} <- measure(value, size, maximum, outer?) do
      measure_items(rest, size, maximum, outer?, false)
    end
  end

  defp measure_string(<<>>, size, _maximum, _outer?), do: {:ok, size}

  defp measure_string(<<byte, rest::binary>>, size, maximum, outer?) do
    emitted =
      case byte do
        ?\b -> "\\b"
        ?\t -> "\\t"
        ?\n -> "\\n"
        ?\f -> "\\f"
        ?\r -> "\\r"
        ?" -> "\\\""
        ?\\ -> "\\\\"
        byte when byte < 0x20 -> "\\u00" <> Base.encode16(<<byte>>, case: :lower)
        byte -> <<byte>>
      end

    with {:ok, size} <- add_emitted(size, emitted, maximum, outer?) do
      measure_string(rest, size, maximum, outer?)
    end
  end

  defp add_emitted(size, <<>>, _maximum, _outer?), do: {:ok, size}

  defp add_emitted(size, <<byte, rest::binary>>, maximum, outer?) do
    addition = if outer? and byte in [?", ?\\], do: 2, else: 1

    if size + addition <= maximum do
      add_emitted(size + addition, rest, maximum, outer?)
    else
      :error
    end
  end

  defp unique_json_values?(values) do
    Enum.reduce_while(values, [], fn value, seen ->
      if Enum.any?(seen, &json_equal?(&1, value)),
        do: {:halt, false},
        else: {:cont, [value | seen]}
    end) != false
  end

  defp json_equal?(left, right) when is_number(left) and is_number(right), do: left == right

  defp json_equal?(left, right) when is_list(left) and is_list(right) do
    length(left) == length(right) and
      Enum.zip(left, right) |> Enum.all?(fn {a, b} -> json_equal?(a, b) end)
  end

  defp json_equal?(left, right) when is_map(left) and is_map(right) do
    Map.keys(left) == Map.keys(right) and
      Enum.all?(left, fn {key, value} -> json_equal?(value, Map.fetch!(right, key)) end)
  end

  defp json_equal?(left, right), do: left === right

  defp visible?(value), do: Enum.all?(:binary.bin_to_list(value), &(&1 > 31 and &1 != 127))
end
