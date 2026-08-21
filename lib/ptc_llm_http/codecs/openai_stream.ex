defmodule PtcLlmHttp.Codecs.OpenAIStream do
  @moduledoc false

  alias PtcLlmHttp.Codecs.OpenAI
  alias PtcLlmHttp.{Limits, SSE, Usage}
  alias PtcLlmHttp.Runtime.Role

  @enforce_keys [
    :sse,
    :usage_guarantees,
    :usage,
    :finished?,
    :done?,
    :delivered_bytes,
    :delivered_chunks,
    :callback_role,
    :callback
  ]
  defstruct @enforce_keys

  @opaque t :: %__MODULE__{
            sse: SSE.t(),
            usage_guarantees: %{tokens: boolean(), cost: boolean()},
            usage: Usage.t() | nil,
            finished?: boolean(),
            done?: boolean(),
            delivered_bytes: non_neg_integer(),
            delivered_chunks: non_neg_integer(),
            callback_role: pid() | nil,
            callback: (map() -> :cont | :halt) | nil
          }

  @doc false
  def new(usage_guarantees) do
    %__MODULE__{
      sse: SSE.new(),
      usage_guarantees: usage_guarantees,
      usage: nil,
      finished?: false,
      done?: false,
      delivered_bytes: 0,
      delivered_chunks: 0,
      callback_role: nil,
      callback: nil
    }
  end

  @doc false
  def feed(%__MODULE__{} = state, bytes, callback_role, callback) do
    state = %{state | callback_role: callback_role, callback: callback}
    on_event = fn data, stream -> event(data, stream, callback_role, callback) end

    case SSE.feed(state.sse, bytes, state, on_event) do
      {:ok, sse, state} -> {:cont, %{state | sse: sse}}
      {:halt, sse, state} -> {:halt, %{state | sse: sse}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  def finish(%__MODULE__{} = state) do
    on_event = fn data, stream -> event(data, stream, state.callback_role, state.callback) end

    case SSE.finish(state.sse, state, on_event) do
      {:ok, sse, state} ->
        if state.done? and state.finished? and
             OpenAI.stream_usage_complete?(state.usage, state.usage_guarantees) do
          {:ok, %{state | sse: sse}}
        else
          {:error, :malformed_stream}
        end

      {:halt, sse, state} ->
        {:halt, %{state | sse: sse}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  def facts(%__MODULE__{} = state) do
    %{
      usage: state.usage,
      delivered_bytes: state.delivered_bytes,
      delivered_chunks: state.delivered_chunks
    }
  end

  defp event(_data, %{done?: true}, _callback_role, _callback),
    do: {:error, :malformed_stream}

  defp event("[DONE]", state, _callback_role, _callback) do
    if state.finished?, do: {:cont, %{state | done?: true}}, else: {:error, :malformed_stream}
  end

  defp event(data, state, callback_role, callback) do
    with {:ok, decoded} <- Jason.decode(data),
         true <- is_map(decoded),
         :ok <- OpenAI.stream_json(decoded),
         {:ok, state} <- retain_usage(decoded, state),
         :ok <- event_order(state, decoded),
         {:ok, delta, finished?} <- text_delta(decoded),
         {:ok, state} <- update_finished(state, finished?),
         {:ok, state, action} <- deliver_delta(state, delta, callback_role, callback) do
      {action, state}
    else
      {:error, reason} when reason in [:stream_too_large, :callback_misuse] -> {:error, reason}
      _invalid -> {:error, :malformed_stream}
    end
  end

  defp retain_usage(%{"choices" => [], "usage" => value}, %{usage: nil} = state)
       when not is_nil(value) do
    case OpenAI.stream_usage(value) do
      {:ok, usage} -> {:ok, %{state | usage: usage}}
      _invalid -> {:error, :malformed_stream}
    end
  end

  defp retain_usage(%{"usage" => value}, _state) when not is_nil(value),
    do: {:error, :malformed_stream}

  defp retain_usage(_decoded, state), do: {:ok, state}

  defp event_order(%{finished?: true}, %{"choices" => []}), do: :ok
  defp event_order(%{finished?: true}, _decoded), do: {:error, :event_after_finish}
  defp event_order(_state, _decoded), do: :ok

  defp text_delta(%{"choices" => []} = decoded) do
    if Map.has_key?(decoded, "usage"), do: {:ok, nil, false}, else: {:error, :invalid_event}
  end

  defp text_delta(%{
         "choices" => [
           %{"index" => 0, "delta" => delta} = choice
         ]
       })
       when is_map(delta) do
    with false <- Map.has_key?(delta, "tool_calls"),
         false <- Map.has_key?(delta, "function_call"),
         {:ok, content} <- delta_content(delta),
         {:ok, finished?} <- finish_reason(Map.get(choice, "finish_reason")) do
      {:ok, content, finished?}
    else
      _unsupported_or_invalid -> {:error, :invalid_event}
    end
  end

  defp text_delta(_decoded), do: {:error, :invalid_event}

  defp delta_content(%{"content" => content}) when is_binary(content) do
    if String.valid?(content), do: {:ok, content}, else: {:error, :invalid_content}
  end

  defp delta_content(%{"content" => nil}), do: {:ok, nil}

  defp delta_content(delta),
    do: if(Map.has_key?(delta, "content"), do: {:error, :invalid_content}, else: {:ok, nil})

  defp finish_reason(nil), do: {:ok, false}
  defp finish_reason(reason) when reason in ["stop", "length", "content_filter"], do: {:ok, true}
  defp finish_reason(_reason), do: {:error, :invalid_finish_reason}

  defp update_finished(%{finished?: true} = state, false), do: {:ok, state}
  defp update_finished(%{finished?: true}, true), do: {:error, :duplicate_finish}
  defp update_finished(state, finished?), do: {:ok, %{state | finished?: finished?}}

  defp deliver_delta(state, nil, _callback_role, _callback), do: {:ok, state, :cont}
  defp deliver_delta(state, "", _callback_role, _callback), do: {:ok, state, :cont}

  defp deliver_delta(state, delta, callback_role, callback) do
    bytes = state.delivered_bytes + byte_size(delta)

    if bytes > Limits.stream_decoded_text_bytes() do
      {:error, :stream_too_large}
    else
      operation = fn ->
        result =
          try do
            callback.(%{delta: delta})
          catch
            _kind, _discarded_reason -> :callback_misuse
          end

        if result in [:cont, :halt], do: {:ok, result}, else: {:ok, :callback_misuse}
      end

      next = %{state | delivered_bytes: bytes, delivered_chunks: state.delivered_chunks + 1}

      case Role.call(callback_role, operation) do
        {:ok, :cont} -> {:ok, next, :cont}
        {:ok, :halt} -> {:ok, next, :halt}
        {:ok, :callback_misuse} -> {:error, :callback_misuse}
        _role_unavailable -> {:error, :internal_failure}
      end
    end
  end
end

defimpl Inspect, for: PtcLlmHttp.Codecs.OpenAIStream do
  def inspect(_state, _options), do: "#PtcLlmHttp.Codecs.OpenAIStream<redacted>"
end
