defmodule PtcLlmHttp.OpenAITextTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias PtcLlmHttp.Codecs.OpenAI
  alias PtcLlmHttp.Http.Request, as: HttpRequest
  alias PtcLlmHttp.Test.RawServer

  alias PtcLlmHttp.{
    Credential,
    Deadline,
    Error,
    ProcessBudget,
    Request,
    Response,
    Runtime,
    Target,
    Usage
  }

  @success_fixture Path.expand("../fixtures/openai/text_success.json", __DIR__)
  @rate_limit_fixture Path.expand("../fixtures/openai/rate_limit.json", __DIR__)

  test "one public text call emits the exact chat-completions request and normalizes usage" do
    server = start_supervised!({RawServer, [transport: :tcp]})
    runtime = runtime()
    target = loopback_target(server, %{tokens: true, cost: true})
    request = text_request()

    body =
      ~s({"model":"test-model","messages":[{"role":"system","content":"be concise"},{"role":"user","content":"hello"},{"role":"assistant","content":"hi"},{"role":"user","content":"continue"}],"n":1,"stream":false,"max_tokens":64,"temperature":0.2,"seed":7})

    task = Task.async(fn -> call(runtime, target, request) end)
    assert :ok = RawServer.await_connection(server)

    assert {:ok, head, ^body, _encoded_bytes} =
             HttpRequest.encode(target, Credential.none(), ["chat", "completions"], body)

    assert RawServer.recv(server, byte_size(head) + byte_size(body)) == {:ok, head <> body}

    response_body = File.read!(@success_fixture)
    :ok = send_response(server, 200, response_body)

    assert {:ok, response} = Task.await(task, 5_000)
    assert Response.content(response) == "private answer"

    assert response |> Response.usage() |> Usage.facts() == %{
             prompt_tokens: 11,
             completion_tokens: 3,
             total_tokens: 14,
             cached_tokens: 4,
             cost: 0.0007
           }

    assert Response.metadata(response) == %{
             status: 200,
             encoded_request_bytes: byte_size(body),
             response_bytes: byte_size(response_body),
             informational_responses: 0,
             trailer_fields: 0
           }

    inspected = inspect(response)
    assert inspected == "#PtcLlmHttp.Response<redacted>"
    refute inspected =~ "private answer"
    assert RawServer.connection_count(server) == 1
    assert :ok = RawServer.await_close(server)
    assert {:ok, %{in_use: 0}} = Runtime.snapshot(runtime)
  end

  test "a documented provider code is retained while raw provider text is discarded" do
    server = start_supervised!({RawServer, [transport: :tcp]})
    runtime = runtime()
    target = loopback_target(server, %{tokens: false, cost: false})
    request = text_request()
    task = Task.async(fn -> call(runtime, target, request) end)

    assert :ok = RawServer.await_connection(server)
    assert {:ok, _request_bytes} = recv_request(server, target, request)
    body = File.read!(@rate_limit_fixture)
    :ok = send_response(server, 429, body)

    assert {:error,
            %Error{
              kind: :http_status,
              phase: :decode,
              scope: :provider,
              dispatch: :completed,
              http_status: 429,
              provider_code: :credit_balance_exhausted
            } = error} = Task.await(task, 5_000)

    refute inspect(error) =~ "private provider detail"
    assert RawServer.connection_count(server) == 1
  end

  test "provider quota codes are retained only for the documented 429 status" do
    server = start_supervised!({RawServer, [transport: :tcp]})
    runtime = runtime()
    target = loopback_target(server, %{tokens: false, cost: false})
    request = text_request()
    task = Task.async(fn -> call(runtime, target, request) end)

    assert :ok = RawServer.await_connection(server)
    assert {:ok, _request_bytes} = recv_request(server, target, request)
    :ok = send_response(server, 500, File.read!(@rate_limit_fixture))

    assert {:error, %Error{kind: :http_status, http_status: 500, provider_code: nil}} =
             Task.await(task, 5_000)
  end

  test "encoded request sizing rejects cap plus one before JSON is accumulated" do
    {:ok, request} =
      Request.new(messages: [%{role: :user, content: "quote=\" newline=\n control=\u0001"}])

    target = codec_target(4_096)
    assert {:ok, body} = OpenAI.encode(target, request)
    assert byte_size(body) > byte_size("quote=\" newline=\n control=\u0001")

    capped_target = codec_target(byte_size(body) - 1)

    assert {:error, %Error{kind: :invalid_request, dispatch: :not_sent}} =
             OpenAI.encode(capped_target, request)

    assert {:ok, ^body} = OpenAI.encode(codec_target(byte_size(body)), request)
  end

  property "JSON size preflight agrees with Jason for every supported request field" do
    check all(
            suffix <- string(:utf8, max_length: 64),
            system <- one_of([constant(nil), string(:utf8, min_length: 1, max_length: 32)]),
            max_tokens <- member_of([nil, 1, 9_223_372_036_854_775_807]),
            temperature <- member_of([nil, 0, 0.5, 2]),
            seed <- member_of([nil, -9_223_372_036_854_775_808, 0, 9_223_372_036_854_775_807])
          ) do
      # Prefix every generated value with all JSON short escapes, quote,
      # backslash, a six-byte control escape, and ordinary multibyte UTF-8.
      content = "\"\\\b\t\n\f\r" <> <<0, 1, 31>> <> "é😀" <> suffix

      assert {:ok, request} =
               Request.new(
                 system: system,
                 messages: [%{role: :user, content: content}],
                 max_tokens: max_tokens,
                 temperature: temperature,
                 seed: seed
               )

      assert {:ok, body} = OpenAI.encode(codec_target(1_048_576), request)
      exact_bytes = byte_size(body)

      assert {:ok, ^body} = OpenAI.encode(codec_target(exact_bytes), request)

      assert {:error, %Error{kind: :invalid_request, dispatch: :not_sent}} =
               OpenAI.encode(codec_target(exact_bytes - 1), request)
    end
  end

  test "missing promised usage and a non-JSON success are closed provider errors" do
    for {content_type, body} <- [
          {"application/json",
           ~s({"choices":[{"index":0,"message":{"role":"assistant","content":"ok"}}]})},
          {"text/html", "<h1>private upstream error</h1>"}
        ] do
      server = start_supervised!({RawServer, [transport: :tcp]}, id: make_ref())
      runtime = runtime(make_ref())
      target = loopback_target(server, %{tokens: true, cost: false})
      request = text_request()
      task = Task.async(fn -> call(runtime, target, request) end)

      assert :ok = RawServer.await_connection(server)
      assert {:ok, _request_bytes} = recv_request(server, target, request)
      :ok = send_response(server, 200, body, content_type)

      assert {:error,
              %Error{
                kind: :malformed_provider_response,
                phase: :decode,
                dispatch: :completed,
                http_status: 200
              }} = Task.await(task, 5_000)
    end
  end

  test "unsupported cache mode and expired deadlines fail before a connection" do
    server = start_supervised!({RawServer, [transport: :tcp]})
    runtime = runtime()
    target = loopback_target(server, %{tokens: false, cost: false})
    {:ok, cached_request} = Request.new(messages: [%{role: :user, content: "hello"}], cache: true)

    assert {:error, %Error{kind: :unsupported_capability, dispatch: :not_sent}} =
             call(runtime, target, cached_request)

    {:ok, expired} = Deadline.new(System.monotonic_time(:millisecond))

    assert {:error, %Error{kind: :deadline_exceeded, dispatch: :not_sent}} =
             call(runtime, target, text_request(), expired)

    assert RawServer.connection_count(server) == 0
  end

  defp recv_request(server, target, request) do
    {:ok, body} = OpenAI.encode(target, request)

    {:ok, head, ^body, _bytes} =
      HttpRequest.encode(target, Credential.none(), ["chat", "completions"], body)

    RawServer.recv(server, byte_size(head) + byte_size(body))
  end

  defp send_response(server, status, body, content_type \\ "application/json") do
    RawServer.write(
      server,
      "HTTP/1.1 #{status} Result\r\nContent-Type: #{content_type}\r\n" <>
        "Content-Length: #{byte_size(body)}\r\n\r\n" <> body
    )
  end

  defp call(runtime, target, request, deadline \\ deadline()) do
    PtcLlmHttp.call(runtime, target, request,
      credential: Credential.none(),
      deadline: deadline,
      process_budget: budget()
    )
  end

  defp runtime(id \\ __MODULE__) do
    start_supervised!({Runtime, [max_concurrency: 1, groups: %{"group" => 1}]}, id: id)
  end

  defp loopback_target(server, usage_guarantees) do
    {:ok, target} =
      Target.new(
        kind: :openai_compat,
        base_url: "http://127.0.0.1:#{RawServer.port(server)}/v1",
        model: "test-model",
        capacity_group: "group",
        connect_policy: :literal_loopback,
        max_encoded_request_bytes: 4_096,
        max_wire_response_bytes: 4_096,
        tools: false,
        streaming: false,
        structured_output: :unsupported,
        cache_mode: :unsupported,
        upstream_routing: :opaque,
        usage_guarantees: usage_guarantees
      )

    target
  end

  defp codec_target(maximum) do
    {:ok, target} =
      Target.new(
        kind: :openai_compat,
        base_url: "https://example.com/v1",
        model: "test-model",
        capacity_group: "group",
        connect_policy: :public,
        max_encoded_request_bytes: maximum,
        max_wire_response_bytes: 4_096,
        tools: false,
        streaming: false,
        structured_output: :unsupported,
        cache_mode: :unsupported,
        upstream_routing: :opaque,
        usage_guarantees: %{tokens: false, cost: false}
      )

    target
  end

  defp text_request do
    {:ok, request} =
      Request.new(
        system: "be concise",
        messages: [
          %{role: :user, content: "hello"},
          %{role: :assistant, content: "hi"},
          %{role: :user, content: "continue"}
        ],
        max_tokens: 64,
        temperature: 0.2,
        seed: 7,
        cache: false
      )

    request
  end

  defp budget do
    {:ok, budget} = ProcessBudget.new(total_heap_words: 2_000_000)
    budget
  end

  defp deadline do
    {:ok, deadline} = Deadline.new(System.monotonic_time(:millisecond) + 5_000)
    deadline
  end
end
