defmodule PtcLlmHttp.ToolStructuredTest do
  use ExUnit.Case, async: false

  alias PtcLlmHttp.Codecs.OpenAI
  alias PtcLlmHttp.Http.Request, as: HttpRequest
  alias PtcLlmHttp.Test.RawServer

  alias PtcLlmHttp.{
    Credential,
    Deadline,
    Error,
    JsonSchema,
    ProcessBudget,
    Request,
    Response,
    Runtime,
    Target,
    ToolCall
  }

  @tool_fixture Path.expand("../fixtures/openai/tool_calls.json", __DIR__)
  @structured_fixture Path.expand("../fixtures/openai/structured_output.json", __DIR__)

  test "parallel tool calls use exact wire shapes and return redacted decoded arguments" do
    server = start_supervised!({RawServer, [transport: :tcp]})
    runtime = runtime()
    target = loopback_target(server, tools: true)

    {:ok, request} =
      Request.new(
        messages: [%{role: :user, content: "weather and time"}],
        tools: tools()
      )

    body =
      ~s({"model":"test-model","messages":[{"role":"user","content":"weather and time"}],"n":1,"stream":false,"tools":[{"type":"function","function":{"name":"weather","description":"Look up weather","parameters":{"additionalProperties":false,"properties":{"city":{"type":"string"},"unit":{"enum":["c","f"],"type":"string"}},"required":["city","unit"],"type":"object"},"strict":true}},{"type":"function","function":{"name":"time","parameters":{"additionalProperties":false,"properties":{"city":{"type":"string"}},"required":["city"],"type":"object"},"strict":true}}]})

    task = Task.async(fn -> call(runtime, target, request) end)
    assert :ok = RawServer.await_connection(server)
    assert_exact_request(server, target, body)
    response_body = File.read!(@tool_fixture)
    :ok = send_response(server, response_body)

    assert {:ok, response} = Task.await(task, 5_000)
    assert Response.content(response) == ""
    assert [weather, time] = Response.tool_calls(response)
    assert ToolCall.id(weather) == "call_weather"
    assert ToolCall.name(weather) == "weather"
    assert ToolCall.arguments(weather) == %{"city" => "Stockholm", "unit" => "c"}
    assert ToolCall.arguments(time) == %{"city" => "Stockholm"}
    assert inspect(weather) == "#PtcLlmHttp.ToolCall<redacted>"
    refute inspect(weather) =~ "Stockholm"
    assert :ok = RawServer.await_close(server)
    assert {:ok, %{in_use: 0}} = Runtime.snapshot(runtime)
  end

  test "assistant tool replay and tool results preserve exact order and argument JSON" do
    {:ok, request} =
      Request.new(
        messages: [
          %{role: :user, content: "weather and time"},
          %{
            role: :assistant,
            content: nil,
            tool_calls: [
              %{
                id: "call_weather",
                name: "weather",
                args: %{"unit" => "c", "city" => "Stockholm"}
              },
              %{id: "call_time", name: "time", args: %{"city" => "Stockholm"}}
            ]
          },
          %{role: :tool, tool_call_id: "call_weather", content: "12 C"},
          %{role: :tool, tool_call_id: "call_time", content: "09:30"}
        ],
        tools: tools()
      )

    body =
      ~S({"model":"test-model","messages":[{"role":"user","content":"weather and time"},{"role":"assistant","content":null,"tool_calls":[{"id":"call_weather","type":"function","function":{"name":"weather","arguments":"{\"city\":\"Stockholm\",\"unit\":\"c\"}"}},{"id":"call_time","type":"function","function":{"name":"time","arguments":"{\"city\":\"Stockholm\"}"}}]},{"role":"tool","tool_call_id":"call_weather","content":"12 C"},{"role":"tool","tool_call_id":"call_time","content":"09:30"}],"n":1,"stream":false,"tools":[{"type":"function","function":{"name":"weather","description":"Look up weather","parameters":{"additionalProperties":false,"properties":{"city":{"type":"string"},"unit":{"enum":["c","f"],"type":"string"}},"required":["city","unit"],"type":"object"},"strict":true}},{"type":"function","function":{"name":"time","parameters":{"additionalProperties":false,"properties":{"city":{"type":"string"}},"required":["city"],"type":"object"},"strict":true}}]})

    assert {:ok, ^body} = OpenAI.encode(codec_target(tools: true), request)
  end

  test "empty assistant and tool content can be replayed without inventing text" do
    assert {:ok, _request} =
             Request.new(
               messages: [
                 %{
                   role: :assistant,
                   content: "",
                   tool_calls: [
                     %{
                       id: "call_weather",
                       name: "weather",
                       args: %{"city" => "Stockholm", "unit" => "c"}
                     }
                   ]
                 },
                 %{role: :tool, tool_call_id: "call_weather", content: ""}
               ],
               tools: tools()
             )
  end

  test "a schema-bearing request can return tools before its final structured result" do
    server = start_supervised!({RawServer, [transport: :tcp]})
    runtime = runtime()
    target = loopback_target(server, tools: true, structured_output: :json_schema)

    {:ok, request} =
      Request.new(
        messages: [%{role: :user, content: "weather"}],
        tools: tools(),
        response_schema: %{name: "weather_result", schema: weather_result_schema()}
      )

    task = Task.async(fn -> call(runtime, target, request) end)
    assert :ok = RawServer.await_connection(server)
    {:ok, body} = OpenAI.encode(target, request)
    assert_exact_request(server, target, body)
    :ok = send_response(server, File.read!(@tool_fixture))

    assert {:ok, response} = Task.await(task, 5_000)
    assert [weather, time] = Response.tool_calls(response)
    assert ToolCall.name(weather) == "weather"
    assert ToolCall.name(time) == "time"
  end

  test "strict structured output is sent exactly, validated, and canonicalized" do
    server = start_supervised!({RawServer, [transport: :tcp]})
    runtime = runtime()
    target = loopback_target(server, structured_output: :json_schema)

    {:ok, request} =
      Request.new(
        messages: [%{role: :user, content: "weather"}],
        response_schema: %{name: "weather_result", schema: weather_result_schema()}
      )

    body =
      ~s({"model":"test-model","messages":[{"role":"user","content":"weather"}],"n":1,"stream":false,"response_format":{"type":"json_schema","json_schema":{"name":"weather_result","strict":true,"schema":{"additionalProperties":false,"properties":{"city":{"type":"string"},"temperature":{"type":"integer"}},"required":["city","temperature"],"type":"object"}}}})

    task = Task.async(fn -> call(runtime, target, request) end)
    assert :ok = RawServer.await_connection(server)
    assert_exact_request(server, target, body)
    :ok = send_response(server, File.read!(@structured_fixture))

    assert {:ok, response} = Task.await(task, 5_000)
    assert Response.content(response) == ~s({"city":"Stockholm","temperature":12})
    assert Response.tool_calls(response) == []
  end

  test "json-object mode requires an object and canonicalizes it" do
    server = start_supervised!({RawServer, [transport: :tcp]})
    runtime = runtime()
    target = loopback_target(server, structured_output: :json_object)

    {:ok, request} =
      Request.new(messages: [%{role: :user, content: "object"}], response_schema: :json_object)

    task = Task.async(fn -> call(runtime, target, request) end)
    assert :ok = RawServer.await_connection(server)

    {:ok, body} = OpenAI.encode(target, request)
    assert body =~ ~s("response_format":{"type":"json_object"})
    assert_exact_request(server, target, body)

    response =
      ~S({"choices":[{"index":0,"message":{"role":"assistant","content":"{\"b\":2,\"a\":1}"}}]})

    :ok = send_response(server, response)

    assert {:ok, normalized} = Task.await(task, 5_000)
    assert Response.content(normalized) == ~s({"a":1,"b":2})
  end

  test "request validation rejects unsupported schemas and broken tool-message ordering" do
    invalid = [
      [
        messages: [%{role: :user, content: "x"}],
        response_schema: %{
          name: "x",
          schema: %{
            "type" => "object",
            "properties" => %{},
            "required" => [],
            "additionalProperties" => true
          }
        }
      ],
      [
        messages: [%{role: :user, content: "x"}],
        response_schema: %{name: "x", schema: Map.put(weather_result_schema(), "minimum", 0)}
      ],
      [messages: [%{role: :tool, tool_call_id: "missing", content: "x"}], tools: tools()],
      [
        messages: [
          %{
            role: :assistant,
            content: nil,
            tool_calls: [
              %{id: "id", name: "weather", args: %{"city" => "Stockholm", "unit" => "kelvin"}}
            ]
          }
        ],
        tools: tools()
      ],
      [
        messages: [
          %{role: :assistant, content: nil, tool_calls: [%{id: "id", name: "unknown", args: %{}}]}
        ],
        tools: tools()
      ]
    ]

    Enum.each(invalid, fn options ->
      assert {:error, %Error{kind: :invalid_request, dispatch: :not_sent}} = Request.new(options)
    end)
  end

  test "tool argument null, malformed, scalar, schema mismatch, and overflow are closed errors" do
    cases = [
      {nil, :invalid_tool_arguments},
      {"{", :invalid_tool_arguments},
      {"[]", :invalid_tool_arguments},
      {~s({"city":"Stockholm","unit":"kelvin"}), :invalid_tool_arguments},
      {:binary.copy(" ", 262_145), :provider_result_too_large}
    ]

    Enum.each(cases, fn {arguments, expected_kind} ->
      server = start_supervised!({RawServer, [transport: :tcp]}, id: make_ref())
      runtime = runtime(make_ref())
      target = loopback_target(server, tools: true, max_wire_response_bytes: 300_000)
      {:ok, request} = Request.new(messages: [%{role: :user, content: "weather"}], tools: tools())
      task = Task.async(fn -> call(runtime, target, request, 15_000) end)

      assert :ok = RawServer.await_connection(server)
      {:ok, body} = OpenAI.encode(target, request)
      assert_exact_request(server, target, body)

      response =
        Jason.encode!(%{
          "choices" => [
            %{
              "index" => 0,
              "message" => %{
                "role" => "assistant",
                "content" => nil,
                "tool_calls" => [
                  %{
                    "id" => "call_weather",
                    "type" => "function",
                    "function" => %{"name" => "weather", "arguments" => arguments}
                  }
                ]
              }
            }
          ]
        })

      :ok = send_response(server, response)

      assert {:error, %Error{kind: ^expected_kind, phase: :decode, dispatch: :completed}} =
               Task.await(task, 20_000)
    end)
  end

  test "returned tool-call count and identifier cap breaches are result-too-large errors" do
    valid_call = %{
      "id" => "call_weather",
      "type" => "function",
      "function" => %{"name" => "weather", "arguments" => ~s({"city":"Stockholm","unit":"c"})}
    }

    cases = [
      List.duplicate(valid_call, 129),
      [%{valid_call | "id" => String.duplicate("i", 257)}]
    ]

    Enum.each(cases, fn tool_calls ->
      server = start_supervised!({RawServer, [transport: :tcp]}, id: make_ref())
      runtime = runtime(make_ref())
      target = loopback_target(server, tools: true, max_wire_response_bytes: 100_000)
      {:ok, request} = Request.new(messages: [%{role: :user, content: "weather"}], tools: tools())
      task = Task.async(fn -> call(runtime, target, request) end)

      assert :ok = RawServer.await_connection(server)
      {:ok, body} = OpenAI.encode(target, request)
      assert_exact_request(server, target, body)

      response =
        Jason.encode!(%{
          "choices" => [
            %{
              "index" => 0,
              "message" => %{"role" => "assistant", "content" => nil, "tool_calls" => tool_calls}
            }
          ]
        })

      :ok = send_response(server, response)

      assert {:error, %Error{kind: :provider_result_too_large, phase: :decode}} =
               Task.await(task, 5_000)
    end)
  end

  test "model refusal is a closed model-scoped error and discards private text" do
    server = start_supervised!({RawServer, [transport: :tcp]})
    runtime = runtime()
    target = loopback_target(server, structured_output: :json_schema)

    {:ok, request} =
      Request.new(
        messages: [%{role: :user, content: "weather"}],
        response_schema: %{name: "weather", schema: weather_result_schema()}
      )

    task = Task.async(fn -> call(runtime, target, request) end)
    assert :ok = RawServer.await_connection(server)
    {:ok, body} = OpenAI.encode(target, request)
    assert_exact_request(server, target, body)

    private = "sentinel-private-refusal"

    response =
      Jason.encode!(%{
        "choices" => [
          %{
            "index" => 0,
            "message" => %{"role" => "assistant", "content" => nil, "refusal" => private}
          }
        ]
      })

    :ok = send_response(server, response)

    assert {:error,
            %Error{
              kind: :model_refusal,
              phase: :decode,
              scope: :model,
              dispatch: :completed,
              http_status: 200
            } = error} = Task.await(task, 5_000)

    refute inspect(error) =~ private
  end

  test "replay argument sizing rejects the target cap before body serialization" do
    large = :binary.copy("x", 32_000)

    {:ok, request} =
      Request.new(
        messages: [
          %{
            role: :assistant,
            content: nil,
            tool_calls: [
              %{id: "one", name: "blob", args: %{"value" => large}},
              %{id: "two", name: "blob", args: %{"value" => large}}
            ]
          },
          %{role: :tool, tool_call_id: "one", content: ""},
          %{role: :tool, tool_call_id: "two", content: ""}
        ],
        tools: [
          %{
            name: "blob",
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

    :erlang.trace(self(), true, [:call])
    :erlang.trace_pattern({JsonSchema, :ordered, 1}, true, [:local])

    on_exit(fn ->
      :erlang.trace_pattern({JsonSchema, :ordered, 1}, false, [:local])
      :erlang.trace(self(), false, [:call])
    end)

    assert {:error, %Error{kind: :invalid_request, dispatch: :not_sent}} =
             OpenAI.encode(codec_target(tools: true, max_encoded_request_bytes: 1_024), request)

    refute_received {:trace, _pid, :call, {JsonSchema, :ordered, _arguments}}
  end

  test "schema and tool constructors enforce OpenAI aggregate boundaries" do
    assert :error = JsonSchema.validate(%{"type" => "string", "enum" => nil})
    assert :error = JsonSchema.validate(%{"type" => "string", "description" => nil})

    assert {:error, %Error{kind: :invalid_request}} =
             Request.new(
               messages: [%{role: :user, content: "x"}],
               tools: [tool(String.duplicate("n", 65))]
             )

    properties =
      for index <- 1..5_001, into: %{} do
        {"p#{index}", %{"type" => "string"}}
      end

    assert :error = JsonSchema.validate(object_schema(properties))

    enum_properties =
      for index <- 1..8, into: %{} do
        {"p#{index}", %{"type" => "integer", "enum" => Enum.to_list(1..128)}}
      end

    assert :error = JsonSchema.validate(object_schema(enum_properties))

    long_properties =
      for index <- 1..501, into: %{} do
        {String.pad_trailing("p#{index}", 120, "x"), %{"type" => "string"}}
      end

    assert :error = JsonSchema.validate(object_schema(long_properties))
    assert :error = JsonSchema.validate(nested_array_schema(10))
    assert {:ok, _schema} = JsonSchema.validate(nested_array_schema(9))
    assert :error = JsonSchema.validate(nested_object_schema(10))
    assert {:ok, _schema} = JsonSchema.validate(nested_object_schema(9))
  end

  test "numeric enum uniqueness and matching use JSON mathematical equality" do
    assert :error = JsonSchema.validate(%{"type" => "number", "enum" => [1, 1.0]})
    assert {:ok, schema} = JsonSchema.validate(%{"type" => "number", "enum" => [1]})
    assert JsonSchema.matches?(1.0, schema)
  end

  defp tool(name) do
    %{
      name: name,
      description: nil,
      parameters: object_schema(%{})
    }
  end

  defp object_schema(properties) do
    %{
      "type" => "object",
      "properties" => properties,
      "required" => Map.keys(properties),
      "additionalProperties" => false
    }
  end

  defp nested_array_schema(0), do: %{"type" => "string"}

  defp nested_array_schema(depth),
    do: %{"type" => "array", "items" => nested_array_schema(depth - 1)}

  defp nested_object_schema(0), do: %{"type" => "string"}

  defp nested_object_schema(depth) do
    object_schema(%{"child" => nested_object_schema(depth - 1)})
  end

  test "JSON preflight sizes nested argument escaping exactly" do
    values = [
      %{"plain" => "value"},
      %{"escapes" => "\"\\\b\t\n\f\r" <> <<0, 1, 31>> <> "é😀"},
      %{"nested" => [%{"number" => -12.5}, nil, true, false]}
    ]

    Enum.each(values, fn value ->
      encoded = Jason.encode!(JsonSchema.ordered(value))
      encoded_as_string = Jason.encode!(encoded)

      assert JsonSchema.encoded_size(value, byte_size(encoded)) == {:ok, byte_size(encoded)}

      assert JsonSchema.encoded_as_string_size(value, byte_size(encoded_as_string)) ==
               {:ok, byte_size(encoded_as_string)}

      assert :error = JsonSchema.encoded_size(value, byte_size(encoded) - 1)
      assert :error = JsonSchema.encoded_as_string_size(value, byte_size(encoded_as_string) - 1)
    end)
  end

  test "minimal-budget text calls do not carry full request history into I/O roles" do
    server = start_supervised!({RawServer, [transport: :tcp]})
    runtime = runtime()
    target = loopback_target(server)
    messages = List.duplicate(%{role: :user, content: "bounded history"}, 1_024)
    {:ok, request} = Request.new(messages: messages)
    {:ok, minimum_budget} = ProcessBudget.new(total_heap_words: 100_000)
    task = Task.async(fn -> call(runtime, target, request, 5_000, minimum_budget) end)

    assert :ok = RawServer.await_connection(server)
    {:ok, body} = OpenAI.encode(target, request)
    assert_exact_request(server, target, body)

    :ok =
      send_response(
        server,
        ~s({"choices":[{"index":0,"message":{"role":"assistant","content":"ok"}}]})
      )

    assert {:ok, response} = Task.await(task, 5_000)
    assert Response.content(response) == "ok"
  end

  test "target capability mismatches and structured response mismatches fail closed" do
    server = start_supervised!({RawServer, [transport: :tcp]})
    runtime = runtime()
    {:ok, tool_request} = Request.new(messages: [%{role: :user, content: "x"}], tools: tools())

    assert {:error, %Error{kind: :unsupported_capability, dispatch: :not_sent}} =
             call(runtime, loopback_target(server), tool_request)

    {:ok, schema_request} =
      Request.new(
        messages: [%{role: :user, content: "x"}],
        response_schema: %{name: "weather", schema: weather_result_schema()}
      )

    assert {:error, %Error{kind: :unsupported_capability, dispatch: :not_sent}} =
             call(runtime, loopback_target(server), schema_request)

    target = loopback_target(server, structured_output: :json_schema)
    task = Task.async(fn -> call(runtime, target, schema_request) end)
    assert :ok = RawServer.await_connection(server)
    {:ok, body} = OpenAI.encode(target, schema_request)
    assert_exact_request(server, target, body)

    mismatched =
      ~S({"choices":[{"index":0,"message":{"role":"assistant","content":"{\"city\":\"Stockholm\",\"temperature\":\"warm\"}"}}]})

    :ok = send_response(server, mismatched)

    assert {:error, %Error{kind: :malformed_provider_response, phase: :decode}} =
             Task.await(task, 5_000)
  end

  defp tools do
    [
      %{
        name: "weather",
        description: "Look up weather",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "city" => %{"type" => "string"},
            "unit" => %{"type" => "string", "enum" => ["c", "f"]}
          },
          "required" => ["city", "unit"],
          "additionalProperties" => false
        }
      },
      %{
        name: "time",
        description: nil,
        parameters: %{
          "type" => "object",
          "properties" => %{"city" => %{"type" => "string"}},
          "required" => ["city"],
          "additionalProperties" => false
        }
      }
    ]
  end

  defp weather_result_schema do
    %{
      "type" => "object",
      "properties" => %{
        "city" => %{"type" => "string"},
        "temperature" => %{"type" => "integer"}
      },
      "required" => ["city", "temperature"],
      "additionalProperties" => false
    }
  end

  defp assert_exact_request(server, target, body) do
    assert {:ok, head, ^body, _encoded_bytes} =
             HttpRequest.encode(target, Credential.none(), ["chat", "completions"], body)

    assert RawServer.recv(server, byte_size(head) + byte_size(body)) == {:ok, head <> body}
  end

  defp send_response(server, body) do
    RawServer.write(
      server,
      "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" <>
        "Content-Length: #{byte_size(body)}\r\n\r\n" <> body
    )
  end

  defp call(runtime, target, request, timeout \\ 5_000, process_budget \\ budget()) do
    {:ok, deadline} = Deadline.new(System.monotonic_time(:millisecond) + timeout)

    PtcLlmHttp.call(runtime, target, request,
      credential: Credential.none(),
      deadline: deadline,
      process_budget: process_budget
    )
  end

  defp runtime(id \\ __MODULE__) do
    start_supervised!({Runtime, [max_concurrency: 1, groups: %{"group" => 1}]}, id: id)
  end

  defp loopback_target(server, overrides \\ []) do
    target_options =
      Keyword.merge(
        [
          kind: :openai_compat,
          base_url: "http://127.0.0.1:#{RawServer.port(server)}/v1",
          model: "test-model",
          capacity_group: "group",
          connect_policy: :literal_loopback,
          max_encoded_request_bytes: 1_048_576,
          max_wire_response_bytes: 4_096,
          tools: false,
          streaming: false,
          structured_output: :unsupported,
          cache_mode: :unsupported,
          upstream_routing: :opaque,
          usage_guarantees: %{tokens: false, cost: false}
        ],
        overrides
      )

    {:ok, target} = Target.new(target_options)
    target
  end

  defp codec_target(overrides) do
    target_options =
      Keyword.merge(
        [
          kind: :openai_compat,
          base_url: "https://example.com/v1",
          model: "test-model",
          capacity_group: "group",
          connect_policy: :public,
          max_encoded_request_bytes: 1_048_576,
          max_wire_response_bytes: 4_096,
          tools: false,
          streaming: false,
          structured_output: :unsupported,
          cache_mode: :unsupported,
          upstream_routing: :opaque,
          usage_guarantees: %{tokens: false, cost: false}
        ],
        overrides
      )

    {:ok, target} = Target.new(target_options)
    target
  end

  defp budget do
    {:ok, budget} = ProcessBudget.new(total_heap_words: 2_000_000)
    budget
  end
end
