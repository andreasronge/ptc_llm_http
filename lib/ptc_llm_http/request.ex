defmodule PtcLlmHttp.Request do
  @moduledoc """
  Validated provider-neutral text request.

  Slice 4 accepts only text messages. Tool calls and structured output have
  separate capability contracts and are added by later slices. Inspection is
  wholly redacted because every request can contain private prompt data.
  """

  alias PtcLlmHttp.{Error, Limits}

  @maximum_messages Limits.messages()
  @maximum_text_bytes Limits.encoded_request_bytes()
  @minimum_integer_parameter Limits.integer_parameter_min()
  @maximum_integer_parameter Limits.integer_parameter_max()

  @enforce_keys [:system, :messages, :max_tokens, :temperature, :seed, :cache]
  defstruct @enforce_keys

  @opaque t :: %__MODULE__{}
  @keys [:system, :messages, :max_tokens, :temperature, :seed, :cache]

  @doc "Validates a text-only request without provider, model, or transport options."
  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(options) when is_list(options) do
    with :ok <- options(options),
         {:ok, system} <- optional_text(Keyword.get(options, :system)),
         {:ok, messages} <- messages(Keyword.get(options, :messages)),
         {:ok, max_tokens} <- optional_positive_integer(Keyword.get(options, :max_tokens)),
         {:ok, temperature} <- temperature(Keyword.get(options, :temperature)),
         {:ok, seed} <- optional_integer(Keyword.get(options, :seed)),
         {:ok, cache} <- boolean(Keyword.get(options, :cache, false)) do
      {:ok,
       struct!(__MODULE__,
         system: system,
         messages: messages,
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

  defp messages(messages)
       when is_list(messages) and length(messages) in 1..@maximum_messages do
    Enum.reduce_while(messages, {:ok, []}, fn message, {:ok, validated} ->
      case message(message) do
        {:ok, value} -> {:cont, {:ok, [value | validated]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, validated} -> {:ok, Enum.reverse(validated)}
      error -> error
    end
  end

  defp messages(_messages), do: {:error, :invalid_messages}

  defp message(%{role: role, content: content} = message)
       when map_size(message) == 2 and role in [:system, :user, :assistant] do
    with {:ok, content} <- required_text(content), do: {:ok, %{role: role, content: content}}
  end

  defp message(_message), do: {:error, :invalid_message}

  defp optional_text(nil), do: {:ok, nil}
  defp optional_text(value), do: required_text(value)

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

  defp invalid, do: {:error, Error.build!(:invalid_request, :validate, :request, :not_sent)}
end

defimpl Inspect, for: PtcLlmHttp.Request do
  def inspect(_request, _options), do: "#PtcLlmHttp.Request<redacted>"
end
