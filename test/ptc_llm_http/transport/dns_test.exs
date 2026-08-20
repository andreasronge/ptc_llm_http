defmodule PtcLlmHttp.Transport.DnsTest do
  use ExUnit.Case, async: true

  alias PtcLlmHttp.{Target, Transport}
  alias PtcLlmHttp.Transport.Dns

  test "literal loopback never invokes the resolver" do
    target = target("http://127.0.0.1", :literal_loopback)
    resolver = fn _host -> raise "resolver must not run" end
    assert Dns.resolve(target, resolver) == {:ok, {127, 0, 0, 1}}
  end

  test "authorizes every answer and pins a deterministic address" do
    target = target("https://internal.example", {:allow_cidrs, ["10.0.0.0/8"]})

    assert Dns.resolve(target, fn "internal.example" ->
             {:ok, [{10, 0, 0, 9}, {10, 0, 0, 2}]}
           end) == {:ok, {10, 0, 0, 2}}

    assert Dns.resolve(target, fn _host ->
             {:ok, [{10, 0, 0, 2}, {169, 254, 169, 254}]}
           end) == {:error, :address_rejected}
  end

  test "rejects empty, malformed, and cap-plus-one answer sets" do
    target = target("https://internal.example", {:allow_cidrs, ["10.0.0.0/8"]})

    for answers <- [[], [{999, 0, 0, 1}], List.duplicate({10, 0, 0, 1}, 9)] do
      assert Dns.resolve(target, fn _host -> {:ok, answers} end) ==
               {:error, :address_rejected}
    end
  end

  test "plain loopback HTTP resolution does not require TLS trust" do
    target = target("http://127.0.0.1", :literal_loopback)

    assert {:ok, %{address: {127, 0, 0, 1}, trust: []}} =
             Transport.resolve(%{
               target: target,
               resolver: fn _host -> flunk("literal resolution must not call the resolver") end,
               trust: []
             })
  end

  defp target(base_url, policy) do
    {:ok, target} =
      Target.new(
        kind: :openai_compat,
        base_url: base_url,
        model: "model",
        capacity_group: "group",
        connect_policy: policy,
        max_encoded_request_bytes: 1_024,
        max_wire_response_bytes: 1_024,
        tools: false,
        streaming: false,
        structured_output: :unsupported,
        cache_mode: :unsupported,
        upstream_routing: :opaque,
        usage_guarantees: %{tokens: false, cost: false}
      )

    target
  end
end
