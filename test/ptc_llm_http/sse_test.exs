defmodule PtcLlmHttp.SSETest do
  use ExUnit.Case, async: true

  alias PtcLlmHttp.{Limits, SSE}

  test "parses comments, CRLF, fragmented lines, and multi-line data" do
    state = SSE.new()
    collect = fn event, events -> {:cont, [event | events]} end

    assert {:ok, state, []} = SSE.feed(state, ": heart", [], collect)

    assert {:ok, state, []} =
             SSE.feed(state, "beat\r\ndata: {\r\ndata:  \"ok\":true}\r", [], collect)

    assert {:ok, state, [event]} = SSE.feed(state, "\n\r\n", [], collect)
    assert event == "{\n \"ok\":true}"
    assert {:ok, _state, []} = SSE.finish(state, [], collect)
    assert inspect(state) == "#PtcLlmHttp.SSE<redacted>"
  end

  test "strips exactly one leading UTF-8 BOM under bytewise fragmentation" do
    collect = fn event, events -> {:cont, [event | events]} end

    assert {:ok, state, []} = SSE.feed(SSE.new(), <<239>>, [], collect)
    assert {:ok, state, []} = SSE.feed(state, <<187>>, [], collect)
    assert {:ok, state, []} = SSE.feed(state, <<191, "data: first\n">>, [], collect)
    assert {:ok, _state, ["first"]} = SSE.feed(state, "\n", [], collect)
  end

  test "accepts the standard bare-CR line ending without confusing split CRLF" do
    collect = fn event, events -> {:cont, [event | events]} end
    assert {:ok, waiting, []} = SSE.feed(SSE.new(), "data: one\r", [], collect)

    assert {:ok, waiting, []} = SSE.feed(waiting, "\ndata: two\r\r", [], collect)

    assert {:ok, complete, ["next", "one\ntwo"]} =
             SSE.feed(waiting, "data: next\r\r\n", [], collect)

    assert {:ok, _state, []} = SSE.finish(complete, [], collect)

    assert {:ok, pending, []} = SSE.feed(SSE.new(), "data: last\r\r", [], collect)

    assert {:ok, _complete, ["last"]} = SSE.finish(pending, [], collect)

    halt = fn event, events -> {:halt, [event | events]} end
    assert {:ok, pending, []} = SSE.feed(SSE.new(), "data: halt\r\r", [], halt)
    assert {:halt, _state, ["halt"]} = SSE.finish(pending, [], halt)
  end

  test "rejects unsupported id/retry semantics, invalid UTF-8, and trailing partial events" do
    collect = fn event, events -> {:cont, [event | events]} end

    assert {:error, :malformed_stream} = SSE.feed(SSE.new(), "id: private\n", [], collect)
    assert {:error, :malformed_stream} = SSE.feed(SSE.new(), <<"data: ", 255, "\n">>, [], collect)
    assert {:ok, partial, []} = SSE.feed(SSE.new(), "data: incomplete", [], collect)
    assert {:error, :malformed_stream} = SSE.finish(partial, [], collect)
  end

  test "bounds each event and the cumulative event count under fragmentation" do
    collect = fn _event, count -> {:cont, count + 1} end

    assert {:error, :stream_too_large} =
             SSE.feed(SSE.new(), :binary.copy("x", Limits.sse_event_bytes() + 1), 0, collect)

    event = "data: {}\n\n"
    flood = :binary.copy(event, Limits.sse_events() + 1)
    assert {:error, :stream_too_large} = SSE.feed(SSE.new(), flood, 0, collect)

    line = "data: " <> :binary.copy("x", Limits.sse_event_bytes() - 10) <> "\r\n"
    assert {:ok, _state, 1} = SSE.feed(SSE.new(), line <> "\r\n", 0, collect)

    line_prefix_bytes = byte_size(line) - 1
    <<without_lf::binary-size(^line_prefix_bytes), "\n">> = line
    assert {:ok, state, 0} = SSE.feed(SSE.new(), without_lf, 0, collect)
    assert {:ok, state, 0} = SSE.feed(state, "\n", 0, collect)
    assert {:ok, _state, 1} = SSE.feed(state, "\r\n", 0, collect)
  end
end
