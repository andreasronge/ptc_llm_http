defmodule PtcLlmHttp.Http.RequestTest do
  use ExUnit.Case, async: true

  alias PtcLlmHttp.{Credential, Target}
  alias PtcLlmHttp.Http.Request

  test "serializes one exact credential-free IPv4 request" do
    target = target("http://127.0.0.1:8080/api//a%20b")

    assert {:ok, head, "{}", encoded_bytes} =
             Request.encode(target, Credential.none(), ["echo"], "{}")

    assert head ==
             "POST /api//a%20b/echo HTTP/1.1\r\n" <>
               "Host: 127.0.0.1:8080\r\n" <>
               "Content-Type: application/json\r\n" <>
               "Accept: application/json\r\n" <>
               "Accept-Encoding: identity\r\n" <>
               "Connection: close\r\n" <>
               "User-Agent: ptc_llm_http/0.0.1\r\n" <>
               "Content-Length: 2\r\n\r\n"

    assert encoded_bytes == byte_size(head) + 2
    refute head =~ "%2520"
  end

  test "brackets IPv6, omits default ports, and emits bounded bearer authorization" do
    target = target("http://[::1]/")

    assert {:ok, ipv6_head, _body, _bytes} =
             Request.encode(target, Credential.none(), ["echo"], "[]")

    assert ipv6_head =~ "Host: [::1]\r\n"
    assert ipv6_head =~ "POST //echo HTTP/1.1\r\n"

    target = target("https://example.com:8443", connect_policy: :public)
    assert {:ok, credential} = Credential.bearer("secret+/=")

    assert {:ok, head, _body, _bytes} = Request.encode(target, credential, ["echo"], "[]")
    assert head =~ "Host: example.com:8443\r\n"
    assert head =~ "Authorization: Bearer secret+/=\r\n"
  end

  test "advertises event streams when the response is streamed" do
    target = target("http://127.0.0.1:8080")

    assert {:ok, head, _body, _bytes} =
             Request.encode(target, Credential.none(), ["echo"], "{}", :event_stream)

    assert head =~ "Accept: text/event-stream\r\n"
    refute head =~ "Accept: application/json\r\n"
  end

  test "rejects operation-segment injection and a body above the target cap" do
    target = target("http://127.0.0.1", max_encoded_request_bytes: 2)

    assert {:error, :invalid_request} =
             Request.encode(target, Credential.none(), ["bad\r\nHeader: injected"], "{}")

    assert {:error, :invalid_request} =
             Request.encode(target, Credential.none(), ["echo"], "123")
  end

  defp target(base_url, overrides \\ []) do
    options =
      [
        kind: :openai_compat,
        base_url: base_url,
        model: "model",
        capacity_group: "group",
        connect_policy: :literal_loopback,
        max_encoded_request_bytes: 1_024,
        max_wire_response_bytes: 1_024,
        tools: false,
        streaming: false,
        structured_output: :unsupported,
        cache_mode: :unsupported,
        upstream_routing: :opaque,
        usage_guarantees: %{tokens: false, cost: false}
      ]
      |> Keyword.merge(overrides)

    {:ok, target} = Target.new(options)
    target
  end
end
