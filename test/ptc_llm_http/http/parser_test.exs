defmodule PtcLlmHttp.Http.ParserTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias PtcLlmHttp.Http.{Parser, Response}
  alias PtcLlmHttp.Test.HttpParserBackend

  @backend HttpParserBackend

  test "parses a coalesced content-length response without waiting for close" do
    wire = response("hello")
    assert {:ok, parsed, _socket} = parse([wire], 100)
    assert Response.body(parsed) == "hello"

    assert Response.facts(parsed) == %{
             status: 200,
             content_type: "application/json; charset=utf-8",
             wire_bytes: 5,
             informational_responses: 0,
             trailer_fields: 0
           }

    assert inspect(parsed) == "#PtcLlmHttp.Http.Response<redacted>"
    refute inspect(parsed) =~ "hello"
  end

  test "accepts bounded informational responses and ordinary chunked framing" do
    wire =
      "HTTP/1.1 100 Continue\r\nX-Interim: one\r\n\r\n" <>
        "HTTP/1.1 103 Early Hints\r\nLink: </x>; rel=preload\r\n\r\n" <>
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" <>
        "Transfer-Encoding: ChUnKeD\r\n\r\n" <>
        "2;foo=bar\r\nhe\r\n3; quoted=\"x\\\"y\"\r\nllo\r\n" <>
        "0\r\nContent-Digest: sha-256=:abc:\r\n\r\n"

    assert {:ok, parsed, _socket} = parse(fragment_every_byte(wire), 100)
    assert Response.body(parsed) == "hello"
    assert Response.facts(parsed).informational_responses == 2
    assert Response.facts(parsed).trailer_fields == 1
  end

  property "fragmentation at arbitrary byte boundaries preserves the response" do
    check all(
            body <- binary(max_length: 256),
            sizes <- list_of(integer(1..32), min_length: 1, max_length: 32)
          ) do
      wire = response(body)
      fragments = fragment(wire, sizes)

      assert {:ok, parsed, _socket} = parse(fragments, 256)
      assert Response.body(parsed) == body
    end
  end

  test "rejects ambiguous, unsupported, and close-delimited framing" do
    cases = [
      {"HTTP/1.1 200 OK\r\nContent-Length: 0\r\nContent-Length: 0\r\n\r\n", :unsupported_framing},
      {"HTTP/1.1 200 OK\r\nContent-Length: 0\r\nTransfer-Encoding: chunked\r\n\r\n",
       :unsupported_framing},
      {"HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip, chunked\r\n\r\n",
       :unsupported_transfer_encoding},
      {"HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: 0\r\n\r\n",
       :unsupported_content_encoding},
      {"HTTP/1.1 200 OK\r\n\r\nbody-until-close", :unsupported_framing},
      {"HTTP/1.1 200 OK\r\nConnection: upgrade\r\nUpgrade: websocket\r\n" <>
         "Content-Length: 0\r\n\r\n", :unsupported_framing},
      {"HTTP/1.1 302 Found\r\nContent-Length: 0\r\n\r\n", :unsupported_redirect}
    ]

    Enum.each(cases, fn {wire, reason} ->
      assert {:error, ^reason, _socket} = parse([wire], 100)
    end)
  end

  test "rejects malformed lines, chunks, terminators, and forbidden trailers" do
    cases = [
      "HTTP/1.1 200 OK\nContent-Length: 0\n\n",
      "HTTP/1.1 200 OK\r\n folded: bad\r\nContent-Length: 0\r\n\r\n",
      chunked("Z\r\n"),
      chunked("1\r\naX\r\n0\r\n\r\n"),
      chunked("0\r\nContent-Length: 1\r\n\r\n"),
      chunked("1;=bad\r\na\r\n0\r\n\r\n")
    ]

    Enum.each(cases, fn wire ->
      assert {:error, :malformed_http, _socket} = parse(fragment_every_byte(wire), 100)
    end)
  end

  test "rejects every forbidden trailer category" do
    forbidden = [
      "Content-Length",
      "Content-Range",
      "Content-Encoding",
      "Authorization",
      "WWW-Authenticate",
      "Authentication-Info",
      "Proxy-Authenticate",
      "Proxy-Authentication-Info",
      "Location",
      "Retry-After",
      "Allow",
      "Expect",
      "Range",
      "If-Match",
      "X-Unspecified"
    ]

    Enum.each(forbidden, fn name ->
      wire = chunked("0\r\n#{name}: forbidden\r\n\r\n")
      assert {:error, :malformed_http, _socket} = parse([wire], 100)
    end)
  end

  test "detects announced and incremental cap-plus-one overflow before retaining it" do
    assert {:error, :response_too_large, _socket} = parse([response(:binary.copy("x", 21))], 20)

    wire = chunked("15\r\n" <> :binary.copy("x", 21) <> "\r\n0\r\n\r\n")
    socket = HttpParserBackend.socket(fragment_every_byte(wire), self())

    assert {:error, :response_too_large, _socket} =
             Parser.parse(@backend, socket, deadline(), 20, fn _phase, _dispatch -> :ok end)

    requests = drain_requests([])
    assert requests != []
    assert Enum.all?(requests, &(&1 <= 21))
  end

  test "reports an early peer close as incomplete" do
    wire = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nabc"
    assert {:error, :connection_closed, _socket} = parse([wire], 100)
  end

  defp parse(chunks, maximum) do
    socket = HttpParserBackend.socket(chunks)
    Parser.parse(@backend, socket, deadline(), maximum, fn _phase, _dispatch -> :ok end)
  end

  defp response(body) do
    "HTTP/1.1 200 OK\r\nContent-Type: application/json; charset=utf-8\r\n" <>
      "Content-Length: #{byte_size(body)}\r\n\r\n" <> body
  end

  defp chunked(body) do
    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" <>
      "Transfer-Encoding: chunked\r\n\r\n" <> body
  end

  defp fragment_every_byte(binary), do: for(<<byte <- binary>>, do: <<byte>>)

  defp fragment(binary, sizes), do: fragment(binary, sizes, sizes, [])
  defp fragment(<<>>, _sizes, _original, fragments), do: Enum.reverse(fragments)

  defp fragment(binary, [], original, fragments),
    do: fragment(binary, original, original, fragments)

  defp fragment(binary, [size | sizes], original, fragments) do
    take = min(size, byte_size(binary))
    <<fragment::binary-size(^take), rest::binary>> = binary
    fragment(rest, sizes, original, [fragment | fragments])
  end

  defp drain_requests(requests) do
    receive do
      {:parser_read, maximum} -> drain_requests([maximum | requests])
    after
      0 -> requests
    end
  end

  defp deadline, do: System.monotonic_time(:millisecond) + 5_000
end
