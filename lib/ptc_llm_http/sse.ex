defmodule PtcLlmHttp.SSE do
  @moduledoc false

  alias PtcLlmHttp.Limits

  @enforce_keys [:buffer, :data, :event_bytes, :events, :started?]
  defstruct @enforce_keys

  @opaque t :: %__MODULE__{
            buffer: binary(),
            data: [binary()],
            event_bytes: non_neg_integer(),
            events: non_neg_integer(),
            started?: boolean()
          }

  @type reason ::
          :malformed_stream | :stream_too_large | :callback_misuse | :internal_failure

  @spec new() :: t()
  def new,
    do: %__MODULE__{buffer: <<>>, data: [], event_bytes: 0, events: 0, started?: false}

  @spec feed(t(), binary(), term(), (binary(), term() -> term())) ::
          {:ok, t(), term()} | {:halt, t(), term()} | {:error, reason()}
  def feed(%__MODULE__{} = state, bytes, accumulator, on_event)
      when is_binary(bytes) and is_function(on_event, 2) do
    consume_bytes(state, bytes, accumulator, on_event)
  end

  def feed(_state, _bytes, _accumulator, _on_event), do: {:error, :malformed_stream}

  @spec finish(t(), term(), (binary(), term() -> term())) ::
          {:ok, t(), term()} | {:halt, t(), term()} | {:error, reason()}
  def finish(%__MODULE__{} = state, accumulator, on_event) when is_function(on_event, 2) do
    case resolve_eof_cr(state, accumulator, on_event) do
      {:ok, %__MODULE__{buffer: <<>>, data: [], event_bytes: 0} = state, accumulator} ->
        {:ok, state, accumulator}

      {:ok, _partial, _accumulator} ->
        {:error, :malformed_stream}

      {:halt, state, accumulator} ->
        {:halt, state, accumulator}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp consume_lines(state, accumulator, on_event) do
    case take_line(state.buffer) do
      {:ok, line, rest, line_bytes} ->
        consume_line(state, accumulator, on_event, line, rest, line_bytes)

      :incomplete ->
        incomplete_line(state, accumulator)
    end
  end

  defp consume_line(state, accumulator, on_event, line, rest, line_bytes) do
    {line, state} = strip_initial_bom(line, state)

    cond do
      not String.valid?(line) ->
        {:error, :malformed_stream}

      state.event_bytes + line_bytes > Limits.sse_event_bytes() ->
        {:error, :stream_too_large}

      true ->
        state = %{state | buffer: rest, event_bytes: state.event_bytes + line_bytes}

        consume_parsed_line(line, state, accumulator, on_event)
    end
  end

  defp strip_initial_bom(<<239, 187, 191, rest::binary>>, %{started?: false} = state),
    do: {rest, %{state | started?: true}}

  defp strip_initial_bom(line, %{started?: false} = state),
    do: {line, %{state | started?: true}}

  defp strip_initial_bom(line, state), do: {line, state}

  defp take_line(buffer) do
    case :binary.match(buffer, ["\r", "\n"]) do
      {index, 1} -> take_line_at(buffer, index)
      :nomatch -> :incomplete
    end
  end

  defp take_line_at(buffer, index) do
    case binary_part(buffer, index, byte_size(buffer) - index) do
      "\r" ->
        :incomplete

      <<"\r\n", _rest::binary>> ->
        split_line(buffer, index, 2)

      <<"\r", _rest::binary>> ->
        split_line(buffer, index, 1)

      <<"\n", _rest::binary>> ->
        split_line(buffer, index, 1)
    end
  end

  defp split_line(buffer, index, delimiter_bytes) do
    line = binary_part(buffer, 0, index)
    offset = index + delimiter_bytes
    rest = binary_part(buffer, offset, byte_size(buffer) - offset)
    {:ok, line, rest, offset}
  end

  defp consume_bytes(state, <<>>, accumulator, _on_event), do: incomplete_line(state, accumulator)

  defp consume_bytes(%{buffer: buffer} = state, bytes, accumulator, on_event)
       when byte_size(buffer) > 0 do
    if String.ends_with?(buffer, "\r") do
      resolve_pending_cr(state, bytes, accumulator, on_event)
    else
      append_next_piece(state, bytes, accumulator, on_event)
    end
  end

  defp consume_bytes(state, bytes, accumulator, on_event),
    do: append_next_piece(state, bytes, accumulator, on_event)

  defp resolve_pending_cr(state, <<"\n", rest::binary>>, accumulator, on_event),
    do: append_piece(state, "\n", rest, accumulator, on_event)

  defp resolve_pending_cr(state, bytes, accumulator, on_event) do
    size = byte_size(state.buffer)
    line = binary_part(state.buffer, 0, size - 1)

    case consume_line(state, accumulator, on_event, line, <<>>, size) do
      {:ok, state, accumulator} -> consume_bytes(state, bytes, accumulator, on_event)
      other -> other
    end
  end

  defp append_next_piece(state, bytes, accumulator, on_event) do
    case :binary.match(bytes, ["\r", "\n"]) do
      {index, 1} ->
        delimiter_bytes = delimiter_bytes(bytes, index)
        take = index + delimiter_bytes
        <<piece::binary-size(^take), rest::binary>> = bytes
        append_piece(state, piece, rest, accumulator, on_event)

      :nomatch ->
        append_piece(state, bytes, <<>>, accumulator, on_event)
    end
  end

  defp delimiter_bytes(bytes, index) do
    case binary_part(bytes, index, byte_size(bytes) - index) do
      <<"\r\n", _rest::binary>> -> 2
      _single_delimiter -> 1
    end
  end

  defp append_piece(state, piece, rest, accumulator, on_event) do
    retained = state.event_bytes + byte_size(state.buffer) + byte_size(piece)

    if retained > Limits.sse_event_bytes() do
      {:error, :stream_too_large}
    else
      case consume_lines(%{state | buffer: state.buffer <> piece}, accumulator, on_event) do
        {:ok, state, accumulator} -> consume_bytes(state, rest, accumulator, on_event)
        other -> other
      end
    end
  end

  defp resolve_eof_cr(%{buffer: buffer} = state, accumulator, on_event) do
    if String.ends_with?(buffer, "\r") do
      size = byte_size(buffer)
      line = binary_part(buffer, 0, size - 1)

      consume_line(state, accumulator, on_event, line, <<>>, size)
    else
      {:ok, state, accumulator}
    end
  end

  defp consume_parsed_line("", %{data: []} = state, accumulator, on_event) do
    consume_lines(%{state | event_bytes: 0}, accumulator, on_event)
  end

  defp consume_parsed_line("", state, accumulator, on_event) do
    if state.events == Limits.sse_events() do
      {:error, :stream_too_large}
    else
      data = state.data |> Enum.reverse() |> Enum.join("\n")
      next = %{state | data: [], event_bytes: 0, events: state.events + 1}

      case on_event.(data, accumulator) do
        {:cont, accumulator} ->
          consume_lines(next, accumulator, on_event)

        {:halt, accumulator} ->
          {:halt, next, accumulator}

        {:error, reason}
        when reason in [:malformed_stream, :stream_too_large, :callback_misuse, :internal_failure] ->
          {:error, reason}

        _invalid ->
          {:error, :malformed_stream}
      end
    end
  end

  defp consume_parsed_line(<<":", _comment::binary>>, state, accumulator, on_event),
    do: consume_lines(state, accumulator, on_event)

  defp consume_parsed_line(line, state, accumulator, on_event) do
    {field, value} = split_field(line)

    case field do
      "data" ->
        consume_lines(
          %{state | data: [strip_one_space(value) | state.data]},
          accumulator,
          on_event
        )

      field when field in ["id", "retry"] ->
        {:error, :malformed_stream}

      _ignored_standard_extension ->
        consume_lines(state, accumulator, on_event)
    end
  end

  defp incomplete_line(state, accumulator) do
    if byte_size(state.buffer) + state.event_bytes > Limits.sse_event_bytes(),
      do: {:error, :stream_too_large},
      else: {:ok, state, accumulator}
  end

  defp split_field(line) do
    case :binary.match(line, ":") do
      {index, 1} ->
        <<field::binary-size(^index), ":", value::binary>> = line
        {field, value}

      :nomatch ->
        {line, <<>>}
    end
  end

  defp strip_one_space(<<" ", rest::binary>>), do: rest
  defp strip_one_space(value), do: value
end

defimpl Inspect, for: PtcLlmHttp.SSE do
  def inspect(_state, _options), do: "#PtcLlmHttp.SSE<redacted>"
end
