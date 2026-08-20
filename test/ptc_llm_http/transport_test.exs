defmodule PtcLlmHttp.TransportTest do
  use ExUnit.Case, async: false

  alias PtcLlmHttp.{Credential, Deadline, Error, ProcessBudget, Runtime, Target, Transport}
  alias PtcLlmHttp.Http.{Request, Response}
  alias PtcLlmHttp.Test.{Certificates, RawServer}

  test "one admitted TCP attempt sends one exact request and parses a short keep-alive response" do
    server = start_supervised!({RawServer, [transport: :tcp]})
    runtime = runtime()
    target = loopback_target(server, "/api//a%20b")
    body = ~s({"echo":"hello"})

    task = request_task(runtime, target, Credential.none(), body)
    assert :ok = RawServer.await_connection(server)

    assert {:ok, head, ^body, _bytes} =
             Request.encode(target, Credential.none(), ["echo"], body)

    assert RawServer.recv(server, byte_size(head) + byte_size(body)) == {:ok, head <> body}

    wire =
      "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" <>
        "Content-Length: 16\r\nConnection: keep-alive\r\n\r\n" <> body

    for fragment <- fragment(wire, [1, 2, 3, 5, 8, 13]),
        do: :ok = RawServer.write(server, fragment)

    assert {:ok, response} = Task.await(task, 5_000)
    assert Response.body(response) == body
    assert Response.facts(response).wire_bytes == 16
    assert RawServer.connection_count(server) == 1
    assert :ok = RawServer.await_close(server)
    assert {:ok, %{in_use: 0}} = Runtime.snapshot(runtime)
  end

  test "one admitted TLS attempt pins the approved address while preserving Host and SNI" do
    certificates = Certificates.build(names: ["localhost"])

    server =
      start_supervised!({RawServer, [transport: :tls, certificates: certificates]})

    runtime = runtime()
    target = tls_target(server)
    {:ok, credential} = Credential.bearer("private-secret")
    body = ~s({"secure":true})

    task =
      request_task(runtime, target, credential, body,
        resolver: fn "localhost" -> {:ok, [{127, 0, 0, 1}]} end,
        trust: RawServer.trust(server)
      )

    assert :ok = RawServer.await_connection(server)
    assert {:ok, head, ^body, _bytes} = Request.encode(target, credential, ["echo"], body)
    assert head =~ "Host: localhost:#{RawServer.port(server)}\r\n"
    assert head =~ "Authorization: Bearer private-secret\r\n"
    assert RawServer.recv(server, byte_size(head) + byte_size(body)) == {:ok, head <> body}

    :ok =
      RawServer.write(
        server,
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" <>
          "Transfer-Encoding: chunked\r\n\r\n" <>
          "7\r\n{\"tls\":\r\n4\r\ntrue\r\n1\r\n}\r\n0\r\n\r\n"
      )

    assert {:ok, response} = Task.await(task, 5_000)
    assert Response.body(response) == ~s({"tls":true})
    assert RawServer.connection_count(server) == 1
    assert :ok = RawServer.await_close(server)
  end

  test "malformed framing closes without redirect, retry, or a second connection" do
    server = start_supervised!({RawServer, [transport: :tcp]})
    runtime = runtime()
    target = loopback_target(server)
    body = "{}"
    task = request_task(runtime, target, Credential.none(), body)

    assert :ok = RawServer.await_connection(server)
    assert {:ok, head, ^body, _bytes} = Request.encode(target, Credential.none(), ["echo"], body)
    assert {:ok, _request} = RawServer.recv(server, byte_size(head) + byte_size(body))

    :ok =
      RawServer.write(
        server,
        "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nContent-Length: 0\r\n\r\n"
      )

    assert {:error,
            %Error{
              kind: :internal_failure,
              phase: :receive_head,
              dispatch: :possibly_sent
            }} = Task.await(task, 5_000)

    assert RawServer.connection_count(server) == 1
    assert :ok = RawServer.await_close(server)
    assert {:ok, %{in_use: 0}} = Runtime.snapshot(runtime)
  end

  test "the absolute deadline closes a held response socket before capacity is released" do
    server = start_supervised!({RawServer, [transport: :tcp]})
    runtime = runtime()
    target = loopback_target(server)
    body = "{}"
    {:ok, deadline} = Deadline.new(System.monotonic_time(:millisecond) + 150)

    task = request_task(runtime, target, Credential.none(), body, [], deadline)
    assert :ok = RawServer.await_connection(server)
    assert {:ok, head, ^body, _bytes} = Request.encode(target, Credential.none(), ["echo"], body)
    assert {:ok, _request} = RawServer.recv(server, byte_size(head) + byte_size(body))

    assert {:error,
            %Error{
              kind: :deadline_exceeded,
              phase: :receive_head,
              dispatch: :possibly_sent
            }} = Task.await(task, 3_000)

    assert :ok = RawServer.await_close(server)
    assert {:ok, %{in_use: 0}} = Runtime.snapshot(runtime)
  end

  test "caller death closes the socket and drains the physical lease" do
    server = start_supervised!({RawServer, [transport: :tcp]})
    runtime = runtime()
    target = loopback_target(server)
    body = "{}"
    parent = self()

    caller =
      spawn(fn ->
        send(parent, :caller_started)

        Transport.request(
          runtime,
          target,
          Credential.none(),
          ["echo"],
          body,
          budget(),
          deadline()
        )
      end)

    assert_receive :caller_started
    caller_monitor = Process.monitor(caller)
    assert :ok = RawServer.await_connection(server)
    assert {:ok, head, ^body, _bytes} = Request.encode(target, Credential.none(), ["echo"], body)
    assert {:ok, _request} = RawServer.recv(server, byte_size(head) + byte_size(body))

    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^caller_monitor, :process, ^caller, :killed}
    assert :ok = RawServer.await_close(server)
    assert {:ok, %{in_use: 0}} = Runtime.snapshot(runtime)
  end

  test "an announced response above the target cap closes before a flooding peer can accumulate" do
    server = start_supervised!({RawServer, [transport: :tcp]})
    runtime = runtime()
    target = loopback_target(server, "", max_wire_response_bytes: 16)
    body = "{}"
    task = request_task(runtime, target, Credential.none(), body)

    assert :ok = RawServer.await_connection(server)
    assert {:ok, head, ^body, _bytes} = Request.encode(target, Credential.none(), ["echo"], body)
    assert {:ok, _request} = RawServer.recv(server, byte_size(head) + byte_size(body))

    :ok = RawServer.write(server, "HTTP/1.1 200 OK\r\nContent-Length: 17\r\n\r\n")

    assert {:error, %Error{kind: :internal_failure}} = Task.await(task, 5_000)
    assert :ok = RawServer.await_close(server)
    assert RawServer.connection_count(server) == 1
  end

  test "an expired deadline wins before request encoding" do
    runtime = runtime()
    target = target(max_encoded_request_bytes: 1)
    {:ok, expired} = Deadline.new(System.monotonic_time(:millisecond))

    assert {:error,
            %Error{
              kind: :deadline_exceeded,
              phase: :validate,
              dispatch: :not_sent
            }} =
             Transport.request(
               runtime,
               target,
               Credential.none(),
               ["echo"],
               "too large",
               budget(),
               expired
             )
  end

  test "a refused HTTPS TCP connection remains in the connect phase" do
    runtime = runtime()
    port = unused_loopback_port()

    target =
      target(
        base_url: "https://localhost:#{port}",
        connect_policy: {:allow_cidrs, ["127.0.0.0/8"]}
      )

    assert {:error,
            %Error{
              kind: :internal_failure,
              phase: :connect,
              dispatch: :not_sent
            }} =
             Transport.request(
               runtime,
               target,
               Credential.none(),
               ["echo"],
               "{}",
               budget(),
               deadline(),
               resolver: fn "localhost" -> {:ok, [{127, 0, 0, 1}]} end,
               trust: ["unused for a refused TCP connection"]
             )
  end

  test "socket effects wait for guardian progress acknowledgement" do
    server = start_supervised!({RawServer, [transport: :tcp]})
    runtime = runtime()

    target =
      target(
        base_url: "https://localhost:#{RawServer.port(server)}",
        connect_policy: {:allow_cidrs, ["127.0.0.0/8"]}
      )

    parent = self()

    resolver = fn "localhost" ->
      send(parent, {:resolver_ready, self()})

      receive do
        :release_resolver -> {:ok, [{127, 0, 0, 1}]}
      end
    end

    task =
      request_task(runtime, target, Credential.none(), "{}",
        resolver: resolver,
        trust: ["unused by the raw peer"]
      )

    assert_receive {:resolver_ready, resolver_role}
    {:ok, %{guardian: guardian}} = Runtime.components(runtime)
    :ok = :sys.suspend(guardian)
    on_exit(fn -> if Process.alive?(guardian), do: :sys.resume(guardian) end)
    send(resolver_role, :release_resolver)

    assert {:error, :timeout} = RawServer.await_connection(server, 100)
    :ok = :sys.resume(guardian)
    assert :ok = RawServer.await_connection(server)
    :ok = RawServer.close(server)
    assert {:error, %Error{phase: :tls, dispatch: :not_sent}} = Task.await(task, 5_000)
  end

  defp request_task(runtime, target, credential, body, options \\ [], deadline \\ deadline()) do
    Task.async(fn ->
      Transport.request(
        runtime,
        target,
        credential,
        ["echo"],
        body,
        budget(),
        deadline,
        options
      )
    end)
  end

  defp runtime do
    start_supervised!({Runtime, [max_concurrency: 1, groups: %{"group" => 1}]})
  end

  defp loopback_target(server, path \\ "", overrides \\ []) do
    target(
      [
        base_url: "http://127.0.0.1:#{RawServer.port(server)}#{path}",
        connect_policy: :literal_loopback
      ] ++ overrides
    )
  end

  defp tls_target(server) do
    target(
      base_url: "https://localhost:#{RawServer.port(server)}/v1",
      connect_policy: {:allow_cidrs, ["127.0.0.0/8"]}
    )
  end

  defp target(overrides) do
    options =
      [
        kind: :openai_compat,
        base_url: "https://example.com",
        model: "model",
        capacity_group: "group",
        connect_policy: :public,
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

  defp budget do
    {:ok, budget} = ProcessBudget.new(total_heap_words: 2_000_000)
    budget
  end

  defp deadline do
    {:ok, deadline} = Deadline.new(System.monotonic_time(:millisecond) + 5_000)
    deadline
  end

  defp unused_loopback_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false])
    {:ok, {_address, port}} = :inet.sockname(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  defp fragment(binary, sizes), do: fragment(binary, sizes, sizes, [])
  defp fragment(<<>>, _sizes, _original, fragments), do: Enum.reverse(fragments)

  defp fragment(binary, [], original, fragments),
    do: fragment(binary, original, original, fragments)

  defp fragment(binary, [size | sizes], original, fragments) do
    take = min(size, byte_size(binary))
    <<fragment::binary-size(^take), rest::binary>> = binary
    fragment(rest, sizes, original, [fragment | fragments])
  end
end
