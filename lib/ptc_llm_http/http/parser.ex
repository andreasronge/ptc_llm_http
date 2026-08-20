defmodule PtcLlmHttp.Http.Parser do
  @moduledoc false

  alias PtcLlmHttp.Http.Response
  alias PtcLlmHttp.Limits
  alias PtcLlmHttp.Transport.SocketBackend

  @token_special ~c"!#$%&'*+-.^_`|~"
  @maximum_header_fields Limits.response_header_fields()
  @maximum_trailer_fields Limits.trailer_fields()
  @allowed_trailers ["content-digest"]

  @type reason ::
          :connection_closed
          | :deadline_exceeded
          | :malformed_http
          | :response_too_large
          | :transport_failure
          | :unsupported_content_encoding
          | :unsupported_framing
          | :unsupported_redirect
          | :unsupported_transfer_encoding

  @spec parse(module(), struct(), integer(), pos_integer(), (atom(), atom() -> any())) ::
          {:ok, Response.t(), struct()} | {:error, reason(), struct()}
  def parse(backend, socket, deadline, maximum_body_bytes, progress)
      when is_atom(backend) and is_struct(socket) and is_integer(deadline) and
             is_integer(maximum_body_bytes) and maximum_body_bytes > 0 and
             is_function(progress, 2) do
    state = %{
      backend: backend,
      socket: socket,
      deadline: deadline,
      buffer: <<>>,
      maximum_body_bytes: maximum_body_bytes,
      progress: progress
    }

    parse_head(state, 0, 0)
  end

  defp parse_head(state, informational, head_bytes) do
    with {:ok, status_line, state, status_bytes} <-
           read_line(
             state,
             Limits.response_line_bytes(),
             Limits.response_head_bytes() - head_bytes,
             state.maximum_body_bytes
           ),
         {:ok, status} <- parse_status_line(status_line),
         {:ok, headers, state, header_bytes} <-
           read_headers(state, %{}, 0, head_bytes + status_bytes) do
      complete_or_continue(
        state,
        status,
        headers,
        informational,
        head_bytes + status_bytes + header_bytes
      )
    else
      {:error, reason, failed_state} -> {:error, reason, failed_state.socket}
      {:error, reason} -> {:error, reason, state.socket}
    end
  end

  defp complete_or_continue(state, status, headers, informational, head_bytes)
       when status in 100..199 do
    next = informational + 1

    cond do
      status == 101 ->
        {:error, :unsupported_framing, state.socket}

      next > Limits.informational_responses() ->
        {:error, :malformed_http, state.socket}

      field_values(headers, "content-length") != [] ->
        {:error, :malformed_http, state.socket}

      field_values(headers, "transfer-encoding") != [] ->
        {:error, :unsupported_transfer_encoding, state.socket}

      true ->
        parse_head(state, next, head_bytes)
    end
  end

  defp complete_or_continue(state, status, headers, informational, _head_bytes) do
    with :ok <- final_status(status),
         :ok <- content_encoding(headers),
         :ok <- no_upgrade(headers),
         {:ok, content_type} <- single_value(headers, "content-type"),
         {:ok, framing} <- framing(status, headers),
         :ok <- state.progress.(:receive_body, :possibly_sent),
         {:ok, body, trailer_fields, state} <- read_body(state, framing) do
      response = %Response{
        status: status,
        body: body,
        content_type: content_type,
        wire_bytes: byte_size(body),
        informational_responses: informational,
        trailer_fields: trailer_fields
      }

      {:ok, response, state.socket}
    else
      {:error, reason, failed_state} -> {:error, reason, failed_state.socket}
      {:error, reason} -> {:error, reason, state.socket}
    end
  end

  defp final_status(status) when status in 300..399, do: {:error, :unsupported_redirect}
  defp final_status(status) when status in 200..599, do: :ok
  defp final_status(_status), do: {:error, :malformed_http}

  defp parse_status_line(<<"HTTP/1.1 ", a, b, c, " ", reason::binary>>)
       when a in ?0..?9 and b in ?0..?9 and c in ?0..?9 do
    status = (a - ?0) * 100 + (b - ?0) * 10 + (c - ?0)

    if status in 100..599 and reason_phrase?(reason),
      do: {:ok, status},
      else: {:error, :malformed_http}
  end

  defp parse_status_line(_line), do: {:error, :malformed_http}

  defp reason_phrase?(reason) do
    Enum.all?(:binary.bin_to_list(reason), fn byte ->
      byte == ?\t or byte in 32..126 or byte in 128..255
    end)
  end

  defp read_headers(state, headers, count, head_bytes) do
    with true <- count <= @maximum_header_fields,
         {:ok, line, state, line_bytes} <-
           read_line(
             state,
             Limits.response_line_bytes(),
             Limits.response_head_bytes() - head_bytes,
             state.maximum_body_bytes
           ) do
      case line do
        "" ->
          {:ok, headers, state, line_bytes}

        _field when count == @maximum_header_fields ->
          {:error, :malformed_http, state}

        _field ->
          read_header_field(line, state, headers, count, head_bytes, line_bytes)
      end
    else
      false -> {:error, :malformed_http, state}
      error -> error
    end
  end

  defp read_header_field(line, state, headers, count, head_bytes, line_bytes) do
    case parse_field(line) do
      {:ok, name, value} ->
        headers = Map.update(headers, name, [value], &[value | &1])
        continue_headers(state, headers, count, head_bytes, line_bytes)

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp continue_headers(state, headers, count, head_bytes, line_bytes) do
    case read_headers(state, headers, count + 1, head_bytes + line_bytes) do
      {:ok, parsed, final_state, rest_bytes} ->
        {:ok, parsed, final_state, line_bytes + rest_bytes}

      error ->
        error
    end
  end

  defp parse_field(line) do
    case :binary.match(line, ":") do
      {index, 1} when index > 0 ->
        <<name::binary-size(^index), ":", raw_value::binary>> = line
        value = trim_ows(raw_value)

        if byte_size(name) <= Limits.header_name_bytes() and
             byte_size(value) <= Limits.header_value_bytes() and token?(name) and
             field_value?(value) do
          {:ok, ascii_downcase(name), value}
        else
          {:error, :malformed_http}
        end

      _missing_or_empty ->
        {:error, :malformed_http}
    end
  end

  defp token?(value) do
    Enum.all?(:binary.bin_to_list(value), fn byte ->
      byte in ?A..?Z or byte in ?a..?z or byte in ?0..?9 or byte in @token_special
    end)
  end

  defp field_value?(value) do
    Enum.all?(:binary.bin_to_list(value), fn byte ->
      byte == ?\t or byte in 32..126 or byte in 128..255
    end)
  end

  defp trim_ows(value), do: value |> trim_left_ows() |> trim_right_ows()
  defp trim_left_ows(<<byte, rest::binary>>) when byte in [?\s, ?\t], do: trim_left_ows(rest)
  defp trim_left_ows(value), do: value

  defp trim_right_ows(<<>>), do: <<>>

  defp trim_right_ows(value) do
    if :binary.last(value) in [?\s, ?\t],
      do: value |> binary_part(0, byte_size(value) - 1) |> trim_right_ows(),
      else: value
  end

  defp ascii_downcase(value) do
    for <<byte <- value>>, into: <<>> do
      if byte in ?A..?Z, do: <<byte + 32>>, else: <<byte>>
    end
  end

  defp field_values(headers, name), do: Map.get(headers, name, [])

  defp single_value(headers, name) do
    case field_values(headers, name) do
      [] -> {:ok, nil}
      [value] -> {:ok, value}
      _duplicates -> {:error, :malformed_http}
    end
  end

  defp content_encoding(headers) do
    case field_values(headers, "content-encoding") do
      [] -> :ok
      _unsupported -> {:error, :unsupported_content_encoding}
    end
  end

  defp no_upgrade(headers) do
    if field_values(headers, "upgrade") == [] and not connection_upgrade?(headers),
      do: :ok,
      else: {:error, :unsupported_framing}
  end

  defp connection_upgrade?(headers) do
    headers
    |> field_values("connection")
    |> Enum.any?(fn value ->
      value
      |> :binary.split(",", [:global])
      |> Enum.any?(&(ascii_downcase(trim_ows(&1)) == "upgrade"))
    end)
  end

  defp framing(status, headers) when status in [204, 304] do
    lengths = field_values(headers, "content-length")
    transfers = field_values(headers, "transfer-encoding")

    cond do
      transfers != [] ->
        {:error, :unsupported_transfer_encoding}

      status == 204 and lengths != [] ->
        {:error, :malformed_http}

      status == 304 and length(lengths) > 1 ->
        {:error, :malformed_http}

      status == 304 and lengths != [] and not valid_decimal?(hd(lengths)) ->
        {:error, :malformed_http}

      true ->
        {:ok, :none}
    end
  end

  defp framing(_status, headers) do
    lengths = field_values(headers, "content-length")
    transfers = field_values(headers, "transfer-encoding")

    cond do
      lengths != [] and transfers != [] ->
        {:error, :unsupported_framing}

      length(transfers) > 1 ->
        {:error, :unsupported_transfer_encoding}

      transfers != [] ->
        transfer_framing(hd(transfers))

      length(lengths) > 1 ->
        {:error, :unsupported_framing}

      lengths != [] ->
        content_length_framing(hd(lengths))

      true ->
        {:error, :unsupported_framing}
    end
  end

  defp transfer_framing(value) do
    if ascii_downcase(trim_ows(value)) == "chunked",
      do: {:ok, :chunked},
      else: {:error, :unsupported_transfer_encoding}
  end

  defp content_length_framing(value) do
    if valid_decimal?(value) do
      case bounded_decimal(value, Limits.wire_response_bytes()) do
        {:ok, length} -> {:ok, {:content_length, length}}
        {:error, :too_large} -> {:error, :response_too_large}
      end
    else
      {:error, :malformed_http}
    end
  end

  defp valid_decimal?(value),
    do: value != "" and Enum.all?(:binary.bin_to_list(value), &(&1 in ?0..?9))

  defp bounded_decimal(value, maximum) do
    normalized = trim_leading_zeroes(value)
    maximum_text = Integer.to_string(maximum)

    cond do
      byte_size(normalized) < byte_size(maximum_text) -> {:ok, String.to_integer(normalized)}
      byte_size(normalized) > byte_size(maximum_text) -> {:error, :too_large}
      normalized <= maximum_text -> {:ok, String.to_integer(normalized)}
      true -> {:error, :too_large}
    end
  end

  defp trim_leading_zeroes(<<"0", rest::binary>>) when rest != "",
    do: trim_leading_zeroes(rest)

  defp trim_leading_zeroes(value), do: value

  defp read_body(state, :none), do: {:ok, <<>>, 0, state}

  defp read_body(state, {:content_length, length}) do
    if length > state.maximum_body_bytes do
      {:error, :response_too_large, state}
    else
      case take_exact(state, length, []) do
        {:ok, chunks, state} -> {:ok, IO.iodata_to_binary(Enum.reverse(chunks)), 0, state}
        error -> error
      end
    end
  end

  defp read_body(state, :chunked), do: read_chunks(state, [], 0)

  defp read_chunks(state, chunks, total) do
    remaining = state.maximum_body_bytes - total

    with {:ok, line, state, _line_bytes} <-
           read_line(state, Limits.chunk_line_bytes(), Limits.chunk_line_bytes(), remaining),
         {:ok, size} <- parse_chunk_line(line, remaining) do
      read_chunk(state, chunks, total, size)
    else
      {:error, reason, failed_state} -> {:error, reason, failed_state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp read_chunk(state, chunks, _total, 0) do
    case read_trailers(state, 0, 0) do
      {:ok, trailer_fields, state} ->
        {:ok, IO.iodata_to_binary(Enum.reverse(chunks)), trailer_fields, state}

      error ->
        error
    end
  end

  defp read_chunk(state, chunks, total, size) do
    with {:ok, data, state} <- take_exact_binary(state, size),
         {:ok, "\r\n", state} <- take_exact_binary(state, 2) do
      read_chunks(state, [data | chunks], total + size)
    else
      {:ok, _invalid_terminator, failed_state} -> {:error, :malformed_http, failed_state}
      error -> error
    end
  end

  defp parse_chunk_line(line, remaining) do
    {size_text, extensions} = split_extensions(line)
    size_text = trim_right_ows(size_text)

    with true <- size_text != "" and hex?(size_text),
         true <- valid_extensions?(extensions),
         {:ok, size} <- bounded_hex(size_text, remaining) do
      {:ok, size}
    else
      {:error, :too_large} -> {:error, :response_too_large}
      _invalid -> {:error, :malformed_http}
    end
  end

  defp split_extensions(line) do
    case :binary.match(line, ";") do
      {index, 1} ->
        <<size::binary-size(^index), extensions::binary>> = line
        {size, extensions}

      :nomatch ->
        {line, <<>>}
    end
  end

  defp hex?(value) do
    Enum.all?(:binary.bin_to_list(value), fn byte ->
      byte in ?0..?9 or byte in ?A..?F or byte in ?a..?f
    end)
  end

  defp bounded_hex(value, maximum) do
    normalized = trim_leading_hex_zeroes(value)
    maximum_text = maximum |> Integer.to_string(16) |> String.upcase()
    normalized = ascii_upcase(normalized)

    cond do
      byte_size(normalized) < byte_size(maximum_text) ->
        {integer, ""} = Integer.parse(normalized, 16)
        {:ok, integer}

      byte_size(normalized) > byte_size(maximum_text) ->
        {:error, :too_large}

      normalized <= maximum_text ->
        {integer, ""} = Integer.parse(normalized, 16)
        {:ok, integer}

      true ->
        {:error, :too_large}
    end
  end

  defp trim_leading_hex_zeroes(<<"0", rest::binary>>) when rest != "",
    do: trim_leading_hex_zeroes(rest)

  defp trim_leading_hex_zeroes(value), do: value

  defp ascii_upcase(value) do
    for <<byte <- value>>, into: <<>> do
      if byte in ?a..?f, do: <<byte - 32>>, else: <<byte>>
    end
  end

  defp valid_extensions?(<<>>), do: true
  defp valid_extensions?(extensions), do: parse_extensions(extensions) == :ok

  defp parse_extensions(<<";", rest::binary>>) do
    with {:ok, after_name} <- rest |> trim_left_ows() |> take_token(),
         {:ok, after_value} <- after_name |> trim_left_ows() |> optional_extension_value() do
      continue_extensions(trim_left_ows(after_value))
    end
  end

  defp parse_extensions(_extensions), do: {:error, :invalid_extension}

  defp continue_extensions(<<>>), do: :ok
  defp continue_extensions(<<";", _more::binary>> = extensions), do: parse_extensions(extensions)
  defp continue_extensions(_invalid), do: {:error, :invalid_extension}

  defp take_token(value), do: take_token(value, 0)

  defp take_token(<<byte, rest::binary>>, count) when count >= 0 do
    if token_byte?(byte),
      do: take_token(rest, count + 1),
      else: token_result(value(byte, rest), count)
  end

  defp take_token(<<>>, count), do: token_result(<<>>, count)

  defp token_result(_rest, 0), do: {:error, :invalid_token}
  defp token_result(rest, _count), do: {:ok, rest}

  defp value(byte, rest), do: <<byte, rest::binary>>

  defp token_byte?(byte),
    do: byte in ?A..?Z or byte in ?a..?z or byte in ?0..?9 or byte in @token_special

  defp optional_extension_value(<<"=", rest::binary>>),
    do: extension_value(trim_left_ows(rest))

  defp optional_extension_value(rest), do: {:ok, rest}

  defp extension_value(<<"\"", rest::binary>>), do: quoted_extension(rest)
  defp extension_value(rest), do: take_token(rest)

  defp quoted_extension(<<"\"", rest::binary>>), do: {:ok, rest}

  defp quoted_extension(<<"\\", byte, rest::binary>>)
       when byte == ?\t or byte in 32..126 or byte in 128..255,
       do: quoted_extension(rest)

  defp quoted_extension(<<byte, rest::binary>>)
       when byte == ?\t or byte == ?\s or byte == ?! or byte in 35..91 or byte in 93..126 or
              byte in 128..255,
       do: quoted_extension(rest)

  defp quoted_extension(_invalid), do: {:error, :invalid_quoted_extension}

  defp read_trailers(state, count, bytes) do
    with true <- count <= @maximum_trailer_fields,
         {:ok, line, state, line_bytes} <-
           read_line(
             state,
             Limits.response_line_bytes(),
             Limits.trailer_bytes() - bytes,
             0
           ) do
      case line do
        "" ->
          {:ok, count, state}

        _field when count == @maximum_trailer_fields ->
          {:error, :malformed_http, state}

        _field ->
          with {:ok, name, _value} <- parse_field(line),
               true <- name in @allowed_trailers do
            read_trailers(state, count + 1, bytes + line_bytes)
          else
            _invalid -> {:error, :malformed_http, state}
          end
      end
    else
      false -> {:error, :malformed_http, state}
      error -> error
    end
  end

  defp take_exact_binary(state, bytes) do
    case take_exact(state, bytes, []) do
      {:ok, chunks, state} -> {:ok, IO.iodata_to_binary(Enum.reverse(chunks)), state}
      error -> error
    end
  end

  defp take_exact(state, 0, chunks), do: {:ok, chunks, state}

  defp take_exact(%{buffer: buffer} = state, bytes, chunks) when byte_size(buffer) > 0 do
    take = min(bytes, byte_size(buffer))
    <<chunk::binary-size(^take), rest::binary>> = buffer
    take_exact(%{state | buffer: rest}, bytes - take, [chunk | chunks])
  end

  defp take_exact(state, bytes, chunks) do
    maximum = min(bytes, SocketBackend.max_chunk())

    case recv(state, maximum) do
      {:ok, chunk, state} -> take_exact(state, bytes - byte_size(chunk), [chunk | chunks])
      {:error, reason, state} -> {:error, reason, state}
    end
  end

  defp read_line(state, line_maximum, aggregate_remaining, arrival_remaining)
       when aggregate_remaining > 0 do
    case :binary.match(state.buffer, "\r\n") do
      {index, 2} ->
        total = index + 2

        if total <= line_maximum and total <= aggregate_remaining do
          <<line::binary-size(^index), "\r\n", rest::binary>> = state.buffer

          if complete_line_octets?(line),
            do: {:ok, line, %{state | buffer: rest}, total},
            else: {:error, :malformed_http, state}
        else
          {:error, :malformed_http, state}
        end

      :nomatch ->
        continue_line(state, line_maximum, aggregate_remaining, arrival_remaining)
    end
  end

  defp read_line(state, _line_maximum, _aggregate_remaining, _arrival_remaining),
    do: {:error, :malformed_http, state}

  defp continue_line(state, line_maximum, aggregate_remaining, arrival_remaining) do
    current = byte_size(state.buffer)

    cond do
      not partial_line_octets?(state.buffer) ->
        {:error, :malformed_http, state}

      current >= line_maximum or current >= aggregate_remaining ->
        {:error, :malformed_http, state}

      true ->
        parser_need = min(line_maximum - current + 1, aggregate_remaining - current + 1)

        maximum =
          Enum.min([parser_need, max(arrival_remaining + 1, 1), SocketBackend.max_chunk()])

        case recv(state, maximum) do
          {:ok, chunk, state} ->
            read_line(
              %{state | buffer: state.buffer <> chunk},
              line_maximum,
              aggregate_remaining,
              arrival_remaining
            )

          {:error, reason, state} ->
            {:error, reason, state}
        end
    end
  end

  defp complete_line_octets?(line),
    do: :binary.match(line, "\r") == :nomatch and :binary.match(line, "\n") == :nomatch

  defp partial_line_octets?(buffer) do
    :binary.match(buffer, "\n") == :nomatch and
      case :binary.matches(buffer, "\r") do
        [] -> true
        [{index, 1}] -> index == byte_size(buffer) - 1
        _multiple -> false
      end
  end

  defp recv(state, maximum) when maximum > 0 do
    case state.backend.recv_up_to(state.socket, maximum, state.deadline) do
      {:ok, <<>>, socket} -> {:error, :transport_failure, %{state | socket: socket}}
      {:ok, chunk, socket} -> {:ok, chunk, %{state | socket: socket}}
      {:error, :timeout} -> {:error, :deadline_exceeded, state}
      {:error, :closed} -> {:error, :connection_closed, state}
      {:error, _reason} -> {:error, :transport_failure, state}
    end
  end
end
