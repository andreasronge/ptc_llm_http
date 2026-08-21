defmodule PtcLlmHttp.OpenAIStreamTest do
  use ExUnit.Case, async: false

  import PtcLlmHttp.Test.Fragmentation, only: [fragment: 2]

  alias PtcLlmHttp.Codecs.{OpenAI, OpenAIStream}
  alias PtcLlmHttp.Http.Request, as: HttpRequest
  alias PtcLlmHttp.Test.RawServer

  @version Mix.Project.config()[:version]

  alias PtcLlmHttp.{
    Credential,
    Deadline,
    Error,
    Limits,
    ProcessBudget,
    Request,
    Runtime,
    StreamComplete,
    StreamHalt,
    Target,
    Usage
  }

  test "streams exact text deltas synchronously and returns terminal usage without content" do
    server = start_supervised!({RawServer, [transport: :tcp]})
    runtime = runtime()
    target = target(server, %{tokens: true, cost: true})
    request = request()
    parent = self()

    callback = fn %{delta: delta} ->
      send(parent, {:delta, delta})
      :cont
    end

    task = Task.async(fn -> stream(runtime, target, request, callback) end)
    assert :ok = RawServer.await_connection(server)

    expected_body =
      ~s({"model":"test-model","messages":[{"role":"user","content":"hello"}],"n":1,"stream":true,"stream_options":{"include_usage":true},"max_tokens":64})

    head =
      "POST /v1/chat/completions HTTP/1.1\r\n" <>
        "Host: 127.0.0.1:#{RawServer.port(server)}\r\n" <>
        "Content-Type: application/json\r\n" <>
        "Accept: text/event-stream\r\n" <>
        "Accept-Encoding: identity\r\n" <>
        "Connection: close\r\n" <>
        "User-Agent: ptc_llm_http/#{@version}\r\n" <>
        "Content-Length: #{byte_size(expected_body)}\r\n\r\n"

    assert RawServer.recv(server, byte_size(head) + byte_size(expected_body)) ==
             {:ok, head <> expected_body}

    body =
      event(%{"choices" => [%{"index" => 0, "delta" => %{"role" => "assistant"}}]}) <>
        event(%{"choices" => [%{"index" => 0, "delta" => %{"content" => "hello "}}]}) <>
        ": heartbeat\n\n" <>
        ~s|data: {\ndata: "choices":[{"index":0,"delta":{"content":"world"}}]}\n\n| <>
        event(%{
          "choices" => [
            %{"index" => 0, "delta" => %{}, "finish_reason" => "stop"}
          ]
        }) <>
        event(%{
          "choices" => [],
          "usage" => %{
            "prompt_tokens" => 2,
            "completion_tokens" => 2,
            "total_tokens" => 4,
            "prompt_tokens_details" => %{"cached_tokens" => 1},
            "cost" => 0.25
          }
        }) <>
        "data: [DONE]\n\n"

    :ok = send_content_length(server, body)

    assert_receive {:delta, "hello "}
    assert_receive {:delta, "world"}
    assert {:ok, %StreamComplete{} = complete} = Task.await(task, 5_000)
    assert StreamComplete.delivered(complete) == %{bytes: 11, chunks: 2}

    assert Usage.facts(StreamComplete.usage(complete)) == %{
             prompt_tokens: 2,
             completion_tokens: 2,
             total_tokens: 4,
             cached_tokens: 1,
             cost: 0.25
           }

    assert StreamComplete.metadata(complete).response_bytes == byte_size(body)
    assert inspect(complete) == "#PtcLlmHttp.StreamComplete<redacted>"
    assert :ok = RawServer.await_close(server)
    assert {:ok, %{in_use: 0}} = Runtime.snapshot(runtime)
  end

  test "one event split across single-byte writes preserves UTF-8 and callback order" do
    server = start_supervised!({RawServer, [transport: :tcp]})
    runtime = runtime()
    target = target(server, %{tokens: false, cost: false})
    parent = self()
    task = Task.async(fn -> stream(runtime, target, request(), &send_delta(&1, parent)) end)

    assert :ok = RawServer.await_connection(server)
    assert {:ok, _request} = recv_request(server, target, request())

    body =
      event(%{"choices" => [%{"index" => 0, "delta" => %{"content" => "é😀"}}]}) <>
        finish_event() <> "data: [DONE]\n\n"

    head =
      "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream; charset=utf-8\r\n" <>
        "Content-Length: #{byte_size(body)}\r\n\r\n"

    for <<byte <- head <> body>>, do: :ok = RawServer.write(server, <<byte>>)

    assert_receive {:delta, "é😀"}
    assert {:ok, %StreamComplete{}} = Task.await(task, 5_000)
  end

  test "accepts a complete raw stream terminated only by bare CR delimiters" do
    server = start_supervised!({RawServer, [transport: :tcp]})
    runtime = runtime()
    target = target(server, %{tokens: false, cost: false})
    parent = self()
    task = Task.async(fn -> stream(runtime, target, request(), &send_delta(&1, parent)) end)

    assert :ok = RawServer.await_connection(server)
    assert {:ok, _request} = recv_request(server, target, request())

    body =
      "data: " <>
        Jason.encode!(%{"choices" => [%{"index" => 0, "delta" => %{"content" => "ok"}}]}) <>
        "\r\r" <>
        String.replace(finish_event(), "\n", "\r") <>
        "data: [DONE]\r\r"

    :ok = send_content_length(server, body)
    assert_receive {:delta, "ok"}
    assert {:ok, %StreamComplete{}} = Task.await(task, 5_000)
  end

  test "preserves halt and callback misuse from an event dispatched at bare-CR EOF" do
    body =
      "data: " <>
        Jason.encode!(%{"choices" => [%{"index" => 0, "delta" => %{"content" => "last"}}]}) <>
        "\r\r"

    for {callback_result, expected} <- [
          {:halt, {:halted, StreamHalt}},
          {:invalid, {:error, :callback_failed}}
        ] do
      server = start_supervised!({RawServer, [transport: :tcp]}, id: make_ref())
      runtime = runtime(make_ref())
      target = target(server, %{tokens: false, cost: false})
      parent = self()

      task =
        Task.async(fn ->
          stream(runtime, target, request(), fn %{delta: delta} ->
            send(parent, {:eof_delta, delta})
            callback_result
          end)
        end)

      assert :ok = RawServer.await_connection(server)
      assert {:ok, _request} = recv_request(server, target, request())
      :ok = send_content_length(server, body)
      assert_receive {:eof_delta, "last"}

      case expected do
        {:halted, module} -> assert {:halted, %{__struct__: ^module}} = Task.await(task, 5_000)
        {:error, kind} -> assert {:error, %Error{kind: ^kind}} = Task.await(task, 5_000)
      end
    end
  end

  test "consumer halt closes the socket and returns exact partial facts" do
    server = start_supervised!({RawServer, [transport: :tcp]})
    runtime = runtime()
    target = target(server, %{tokens: true, cost: false})
    parent = self()

    task =
      Task.async(fn ->
        stream(runtime, target, request(), fn %{delta: delta} ->
          send(parent, {:halt_delta, delta})
          :halt
        end)
      end)

    assert :ok = RawServer.await_connection(server)
    assert {:ok, _request} = recv_request(server, target, request())
    :ok = send_chunked_head(server)
    first = event(%{"choices" => [%{"index" => 0, "delta" => %{"content" => "stop"}}]})
    :ok = send_chunk(server, first)

    assert_receive {:halt_delta, "stop"}
    assert {:halted, %StreamHalt{} = halt} = Task.await(task, 5_000)
    assert StreamHalt.reason(halt) == :consumer_halted
    assert StreamHalt.usage(halt) == nil
    refute StreamHalt.usage_complete?(halt)
    assert StreamHalt.delivered(halt) == %{bytes: 4, chunks: 1}
    assert inspect(halt) == "#PtcLlmHttp.StreamHalt<redacted>"
    assert :ok = RawServer.await_close(server)
    assert {:ok, %{in_use: 0}} = Runtime.snapshot(runtime)
  end

  test "consumer halt retains only usage observed before the delivered delta" do
    server = start_supervised!({RawServer, [transport: :tcp]})
    runtime = runtime()
    target = target(server, %{tokens: true, cost: false})

    task = Task.async(fn -> stream(runtime, target, request(), fn _chunk -> :halt end) end)
    assert :ok = RawServer.await_connection(server)
    assert {:ok, _request} = recv_request(server, target, request())

    body =
      event(%{
        "choices" => [],
        "usage" => %{
          "prompt_tokens" => 3,
          "completion_tokens" => 1,
          "total_tokens" => 4
        }
      }) <>
        event(%{"choices" => [%{"index" => 0, "delta" => %{"content" => "x"}}]})

    :ok = send_content_length(server, body)
    assert {:halted, halt} = Task.await(task, 5_000)
    assert Usage.facts(StreamHalt.usage(halt)).total_tokens == 4
    refute StreamHalt.usage_complete?(halt)
  end

  test "a permanently blocked callback is backpressured and deadline cleanup kills it" do
    server = start_supervised!({RawServer, [transport: :tcp]})
    runtime = runtime()
    target = target(server, %{tokens: false, cost: false}, 1_048_576)
    parent = self()

    callback = fn %{delta: delta} ->
      send(parent, {:blocked, delta, self()})

      receive do
        :never -> :cont
      end
    end

    deadline = deadline(700)
    task = Task.async(fn -> stream(runtime, target, request(), callback, deadline) end)
    assert :ok = RawServer.await_connection(server)
    assert {:ok, _request} = recv_request(server, target, request())
    :ok = send_chunked_head(server)

    :ok =
      send_chunk(
        server,
        event(%{"choices" => [%{"index" => 0, "delta" => %{"content" => "wait"}}]})
      )

    assert_receive {:blocked, "wait", callback_pid}
    callback_ref = Process.monitor(callback_pid)

    assert {:blocked, written} = RawServer.flood(server, 8_000_000, 100)
    assert written < 8_000_000
    assert {:error, %Error{kind: :deadline_exceeded}} = Task.await(task, 5_000)
    assert_receive {:DOWN, ^callback_ref, :process, ^callback_pid, _reason}
    assert :ok = RawServer.await_close(server)
    assert {:ok, %{in_use: 0}} = Runtime.snapshot(runtime)
  end

  test "caller cancellation tears down a blocked callback and releases capacity" do
    server = start_supervised!({RawServer, [transport: :tcp]})
    runtime = runtime()
    target = target(server, %{tokens: false, cost: false})
    parent = self()

    task =
      Task.async(fn ->
        stream(runtime, target, request(), fn _chunk ->
          send(parent, {:callback_started, self()})
          receive do: (:never -> :cont)
        end)
      end)

    assert :ok = RawServer.await_connection(server)
    assert {:ok, _request} = recv_request(server, target, request())
    :ok = send_chunked_head(server)

    :ok =
      send_chunk(server, event(%{"choices" => [%{"index" => 0, "delta" => %{"content" => "x"}}]}))

    assert_receive {:callback_started, callback_pid}
    callback_ref = Process.monitor(callback_pid)
    assert Task.shutdown(task, :brutal_kill) == nil
    assert_receive {:DOWN, ^callback_ref, :process, ^callback_pid, _reason}
    assert :ok = RawServer.await_close(server)
    assert_eventually_released(runtime)
  end

  test "callback misuse, tool deltas, missing DONE, and non-SSE success are closed errors" do
    cases = [
      {fn _chunk -> :invalid end,
       event(%{"choices" => [%{"index" => 0, "delta" => %{"content" => "x"}}]}),
       :callback_failed},
      {fn _chunk -> :cont end,
       event(%{
         "choices" => [
           %{"index" => 0, "delta" => %{"tool_calls" => [%{"index" => 0}]}}
         ]
       }), :malformed_stream},
      {fn _chunk -> :cont end, finish_event(), :malformed_stream}
    ]

    for {callback, body, expected} <- cases do
      server = start_supervised!({RawServer, [transport: :tcp]}, id: make_ref())
      runtime = runtime(make_ref())
      target = target(server, %{tokens: false, cost: false})
      task = Task.async(fn -> stream(runtime, target, request(), callback) end)
      assert :ok = RawServer.await_connection(server)
      assert {:ok, _request} = recv_request(server, target, request())
      :ok = send_content_length(server, body)
      assert {:error, %Error{} = error} = Task.await(task, 5_000)
      assert error.kind == expected
      if body == finish_event(), do: assert(error.dispatch == :completed)
      assert :ok = RawServer.await_close(server)
    end

    server = start_supervised!({RawServer, [transport: :tcp]}, id: make_ref())
    runtime = runtime(make_ref())
    target = target(server, %{tokens: false, cost: false})
    task = Task.async(fn -> stream(runtime, target, request(), fn _ -> :cont end) end)
    assert :ok = RawServer.await_connection(server)
    assert {:ok, _request} = recv_request(server, target, request())
    :ok = send_content_length(server, "{}", "application/json")

    assert {:error, %Error{kind: :malformed_stream, dispatch: :possibly_sent}} =
             Task.await(task, 5_000)
  end

  test "empty-choice and OpenRouter repeated-finish usage events complete identically" do
    usage = %{
      "prompt_tokens" => 13,
      "completion_tokens" => 9,
      "total_tokens" => 22
    }

    expected_usage = %{
      prompt_tokens: 13,
      completion_tokens: 9,
      total_tokens: 22,
      cached_tokens: nil,
      cost: nil
    }

    for {reason, usage_choices, sizes} <- [
          {"stop", [], nil},
          {"stop", [openrouter_terminal_choice("stop")], [1, 2, 3, 5, 8, 13]},
          {"length", [openrouter_terminal_choice("length")], nil}
        ] do
      server = start_supervised!({RawServer, [transport: :tcp]}, id: make_ref())
      runtime = runtime(make_ref())
      target = target(server, %{tokens: true, cost: false})
      parent = self()

      task =
        Task.async(fn -> stream(runtime, target, request(), &send_delta(&1, parent)) end)

      assert :ok = RawServer.await_connection(server)
      assert {:ok, _request} = recv_request(server, target, request())

      body =
        event(%{"choices" => [%{"index" => 0, "delta" => %{"content" => "hello"}}]}) <>
          event(%{
            "choices" => [
              %{"index" => 0, "delta" => %{"content" => ""}, "finish_reason" => reason}
            ]
          }) <>
          event(%{"choices" => usage_choices, "usage" => usage}) <>
          "data: [DONE]\n\n"

      head =
        "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n" <>
          "Content-Length: #{byte_size(body)}\r\n\r\n"

      wire = head <> body

      case sizes do
        nil -> :ok = RawServer.write(server, wire)
        _fragment_sizes -> Enum.each(fragment(wire, sizes), &RawServer.write(server, &1))
      end

      assert_receive {:delta, "hello"}
      refute_receive {:delta, _extra}
      assert {:ok, %StreamComplete{} = complete} = Task.await(task, 5_000)
      assert StreamComplete.delivered(complete) == %{bytes: 5, chunks: 1}
      assert Usage.facts(StreamComplete.usage(complete)) == expected_usage
      assert :ok = RawServer.await_close(server)
      assert {:ok, %{in_use: 0}} = Runtime.snapshot(runtime)
    end
  end

  test "rejects invalid events after a supported finish reason" do
    usage = %{
      "prompt_tokens" => 13,
      "completion_tokens" => 9,
      "total_tokens" => 22
    }

    finish =
      event(%{
        "choices" => [%{"index" => 0, "delta" => %{"content" => ""}, "finish_reason" => "stop"}]
      })

    openai_usage = event(%{"choices" => [], "usage" => usage})

    openrouter_usage =
      event(%{"choices" => [openrouter_terminal_choice("stop")], "usage" => usage})

    repeated = fn attrs ->
      choice = Map.merge(%{"index" => 0, "delta" => %{"content" => ""}}, attrs)
      event(%{"choices" => [choice], "usage" => usage})
    end

    cases = [
      event(%{"choices" => [%{"index" => 0, "delta" => %{"content" => "x"}}]}),
      event(%{
        "choices" => [%{"index" => 0, "delta" => %{"tool_calls" => [%{"index" => 0}]}}]
      }),
      event(%{
        "choices" => [%{"index" => 0, "delta" => %{"function_call" => %{"name" => "f"}}}]
      }),
      repeated.(%{"delta" => %{"content" => "x"}, "finish_reason" => "stop"}),
      repeated.(%{
        "delta" => %{"tool_calls" => [%{"index" => 0}]},
        "finish_reason" => "stop"
      }),
      repeated.(%{
        "delta" => %{"function_call" => %{"name" => "f"}},
        "finish_reason" => "stop"
      }),
      event(%{
        "choices" => [
          %{"index" => 0, "delta" => %{"content" => ""}, "finish_reason" => "stop"},
          %{"index" => 1, "delta" => %{"content" => ""}, "finish_reason" => "stop"}
        ],
        "usage" => usage
      }),
      repeated.(%{"index" => 1, "finish_reason" => "stop"}),
      event(%{
        "choices" => [%{"index" => 0, "delta" => %{"content" => ""}, "finish_reason" => "stop"}]
      }),
      repeated.(%{"finish_reason" => "length"}),
      repeated.(%{}),
      repeated.(%{"finish_reason" => "tool_calls"}),
      openai_usage <> openai_usage,
      openrouter_usage <> openrouter_usage,
      openai_usage <> openrouter_usage,
      openai_usage <> "data: [DONE]\n\n" <> event(%{"choices" => []})
    ]

    prefix =
      event(%{"choices" => [%{"index" => 0, "delta" => %{"content" => "hello"}}]}) <> finish

    for suffix <- cases do
      server = start_supervised!({RawServer, [transport: :tcp]}, id: make_ref())
      runtime = runtime(make_ref())
      target = target(server, %{tokens: true, cost: false})
      task = Task.async(fn -> stream(runtime, target, request(), fn _chunk -> :cont end) end)
      assert :ok = RawServer.await_connection(server)
      assert {:ok, _request} = recv_request(server, target, request())
      :ok = send_content_length(server, prefix <> suffix)
      assert {:error, %Error{kind: :malformed_stream}} = Task.await(task, 5_000)
      assert :ok = RawServer.await_close(server)
    end
  end

  test "rejects usage attached to a non-terminal choice event" do
    usage = %{"prompt_tokens" => 1, "completion_tokens" => 1, "total_tokens" => 2}

    bodies = [
      event(%{
        "choices" => [%{"index" => 0, "delta" => %{"content" => "x"}}],
        "usage" => usage
      }),
      event(%{
        "choices" => [openrouter_terminal_choice("stop")],
        "usage" => usage
      })
    ]

    for body <- bodies do
      server = start_supervised!({RawServer, [transport: :tcp]}, id: make_ref())
      runtime = runtime(make_ref())
      target = target(server, %{tokens: true, cost: false})
      task = Task.async(fn -> stream(runtime, target, request(), fn _ -> :cont end) end)
      assert :ok = RawServer.await_connection(server)
      assert {:ok, _request} = recv_request(server, target, request())
      :ok = send_content_length(server, body)

      assert {:error, %Error{kind: :malformed_stream, dispatch: :possibly_sent}} =
               Task.await(task, 5_000)

      assert :ok = RawServer.await_close(server)
    end
  end

  test "redacts the codec stream state" do
    state = OpenAIStream.new(%{tokens: false, cost: false})
    assert inspect(state) == "#PtcLlmHttp.Codecs.OpenAIStream<redacted>"
  end

  test "callback raise, throw, and exit are redacted callback failures after cleanup" do
    callbacks = [
      fn _chunk -> raise "private callback exception" end,
      fn _chunk -> throw(:private_callback_throw) end,
      fn _chunk -> exit(:private_callback_exit) end
    ]

    for callback <- callbacks do
      server = start_supervised!({RawServer, [transport: :tcp]}, id: make_ref())
      runtime = runtime(make_ref())
      target = target(server, %{tokens: false, cost: false})
      task = Task.async(fn -> stream(runtime, target, request(), callback) end)
      assert :ok = RawServer.await_connection(server)
      assert {:ok, _request} = recv_request(server, target, request())

      :ok =
        send_content_length(
          server,
          event(%{"choices" => [%{"index" => 0, "delta" => %{"content" => "x"}}]})
        )

      assert {:error, %Error{kind: :callback_failed} = error} = Task.await(task, 5_000)
      refute inspect(error) =~ "private_callback"
      assert :ok = RawServer.await_close(server)
      assert {:ok, %{in_use: 0}} = Runtime.snapshot(runtime)
    end
  end

  test "callback heap death is classified as a resource limit and releases capacity" do
    server = start_supervised!({RawServer, [transport: :tcp]})
    runtime = runtime()
    target = target(server, %{tokens: false, cost: false})
    parent = self()
    {:ok, small_budget} = ProcessBudget.new(total_heap_words: 100_000)

    task =
      Task.async(fn ->
        PtcLlmHttp.stream(
          runtime,
          target,
          request(),
          fn _chunk ->
            send(parent, :heap_callback_started)
            Process.put(:heap_pressure, List.duplicate({:private, make_ref()}, 100_000))
            :cont
          end,
          credential: Credential.none(),
          deadline: deadline(),
          process_budget: small_budget
        )
      end)

    assert :ok = RawServer.await_connection(server)
    assert {:ok, _request} = recv_request(server, target, request())

    :ok =
      send_content_length(
        server,
        event(%{"choices" => [%{"index" => 0, "delta" => %{"content" => "x"}}]})
      )

    assert_receive :heap_callback_started

    assert {:error, %Error{kind: :resource_limit_exceeded}} = Task.await(task, 5_000)
    assert :ok = RawServer.await_close(server)
    assert {:ok, %{in_use: 0}} = Runtime.snapshot(runtime)
  end

  test "wire overflow and missing promised terminal usage are closed independently" do
    server = start_supervised!({RawServer, [transport: :tcp]})
    runtime = runtime()
    target = target(server, %{tokens: false, cost: false}, 32)
    task = Task.async(fn -> stream(runtime, target, request(), fn _ -> :cont end) end)
    assert :ok = RawServer.await_connection(server)
    assert {:ok, _request} = recv_request(server, target, request())
    :ok = send_content_length(server, :binary.copy("x", 33))
    assert {:error, %Error{kind: :response_too_large}} = Task.await(task, 5_000)

    server = start_supervised!({RawServer, [transport: :tcp]}, id: make_ref())
    runtime = runtime(make_ref())
    target = target(server, %{tokens: true, cost: false})
    task = Task.async(fn -> stream(runtime, target, request(), fn _ -> :cont end) end)
    assert :ok = RawServer.await_connection(server)
    assert {:ok, _request} = recv_request(server, target, request())
    :ok = send_content_length(server, finish_event() <> "data: [DONE]\n\n")

    assert {:error, %Error{kind: :malformed_stream, dispatch: :completed}} =
             Task.await(task, 5_000)
  end

  test "decoded text and SSE event caps fail before the overflowing callback" do
    server = start_supervised!({RawServer, [transport: :tcp]})
    runtime = runtime()
    target = target(server, %{tokens: false, cost: false}, 1_048_576)
    parent = self()

    task =
      Task.async(fn ->
        stream(runtime, target, request(), fn %{delta: delta} ->
          send(parent, {:sized_delta, byte_size(delta)})
          :cont
        end)
      end)

    assert :ok = RawServer.await_connection(server)
    assert {:ok, _request} = recv_request(server, target, request())
    piece = :binary.copy("a", div(Limits.stream_decoded_text_bytes(), 2) + 1)

    body =
      event(%{"choices" => [%{"index" => 0, "delta" => %{"content" => piece}}]}) <>
        event(%{"choices" => [%{"index" => 0, "delta" => %{"content" => piece}}]})

    :ok = send_content_length(server, body)
    assert_receive {:sized_delta, size}
    assert size == byte_size(piece)
    refute_receive {:sized_delta, _second}
    assert {:error, %Error{kind: :stream_too_large}} = Task.await(task, 5_000)

    assert {:error, :stream_too_large} =
             PtcLlmHttp.SSE.feed(
               PtcLlmHttp.SSE.new(),
               "data: " <> :binary.copy("x", Limits.sse_event_bytes()),
               nil,
               fn _event, state -> {:cont, state} end
             )
  end

  test "unsupported streaming capability and tool-bearing requests fail before connect" do
    server = start_supervised!({RawServer, [transport: :tcp]})
    runtime = runtime()
    non_streaming = target(server, %{tokens: false, cost: false}, 4_096, false)

    assert {:error, %Error{kind: :unsupported_capability, dispatch: :not_sent}} =
             stream(runtime, non_streaming, request(), fn _ -> :cont end)

    {:ok, tool_request} =
      Request.new(
        messages: [%{role: :user, content: "hello"}],
        tools: [
          %{
            name: "lookup",
            description: nil,
            parameters: %{
              "type" => "object",
              "properties" => %{"value" => %{"type" => "string"}},
              "required" => ["value"],
              "additionalProperties" => false
            }
          }
        ]
      )

    assert {:error, %Error{kind: :unsupported_capability, dispatch: :not_sent}} =
             stream(runtime, target(server, %{tokens: false, cost: false}), tool_request, fn _ ->
               :cont
             end)

    assert RawServer.connection_count(server) == 0
  end

  defp send_delta(%{delta: delta}, parent) do
    send(parent, {:delta, delta})
    :cont
  end

  defp event(value), do: "data: " <> Jason.encode!(value) <> "\n\n"

  defp openrouter_terminal_choice(reason) do
    %{
      "index" => 0,
      "delta" => %{"content" => "", "role" => "assistant"},
      "finish_reason" => reason
    }
  end

  defp finish_event do
    event(%{
      "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "stop"}]
    })
  end

  defp recv_request(server, target, request) do
    {:ok, body} = OpenAI.encode_stream(target, request)

    {:ok, head, ^body, _bytes} =
      HttpRequest.encode(
        target,
        Credential.none(),
        ["chat", "completions"],
        body,
        :event_stream
      )

    RawServer.recv(server, byte_size(head) + byte_size(body))
  end

  defp send_content_length(server, body, content_type \\ "text/event-stream") do
    RawServer.write(
      server,
      "HTTP/1.1 200 OK\r\nContent-Type: #{content_type}\r\n" <>
        "Content-Length: #{byte_size(body)}\r\n\r\n" <> body
    )
  end

  defp send_chunked_head(server) do
    RawServer.write(
      server,
      "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n"
    )
  end

  defp send_chunk(server, data) do
    RawServer.write(server, Integer.to_string(byte_size(data), 16) <> "\r\n" <> data <> "\r\n")
  end

  defp stream(runtime, target, request, callback, deadline \\ deadline()) do
    PtcLlmHttp.stream(runtime, target, request, callback,
      credential: Credential.none(),
      deadline: deadline,
      process_budget: budget()
    )
  end

  defp runtime(id \\ __MODULE__) do
    start_supervised!({Runtime, [max_concurrency: 1, groups: %{"group" => 1}]}, id: id)
  end

  defp target(server, usage, response_bytes \\ 1_048_576, streaming \\ true) do
    {:ok, target} =
      Target.new(
        kind: :openai_compat,
        base_url: "http://127.0.0.1:#{RawServer.port(server)}/v1",
        model: "test-model",
        capacity_group: "group",
        connect_policy: :literal_loopback,
        max_encoded_request_bytes: 4_096,
        max_wire_response_bytes: response_bytes,
        tools: true,
        streaming: streaming,
        structured_output: :json_schema,
        cache_mode: :unsupported,
        upstream_routing: :opaque,
        usage_guarantees: usage
      )

    target
  end

  defp request do
    {:ok, request} =
      Request.new(messages: [%{role: :user, content: "hello"}], max_tokens: 64)

    request
  end

  defp budget do
    {:ok, budget} = ProcessBudget.new(total_heap_words: 4_000_000)
    budget
  end

  defp deadline(milliseconds \\ 5_000) do
    {:ok, deadline} = Deadline.new(System.monotonic_time(:millisecond) + milliseconds)
    deadline
  end

  defp assert_eventually_released(runtime, attempts \\ 100)
  defp assert_eventually_released(_runtime, 0), do: flunk("runtime capacity was not released")

  defp assert_eventually_released(runtime, attempts) do
    receive do
      {:capacity_probe, ^runtime} -> :ok
    after
      0 -> :ok
    end

    case Runtime.snapshot(runtime) do
      {:ok, %{in_use: 0}} ->
        :ok

      _busy ->
        Process.send_after(self(), {:capacity_probe, runtime}, 10)

        receive do
          {:capacity_probe, ^runtime} -> assert_eventually_released(runtime, attempts - 1)
        end
    end
  end
end
