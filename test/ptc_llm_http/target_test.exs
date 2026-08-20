defmodule PtcLlmHttp.TargetTest do
  use ExUnit.Case, async: true

  alias PtcLlmHttp.{ConnectPolicy, Credential, Error, Target}

  test "canonicalizes an HTTPS DNS target and preserves empty path segments" do
    assert {:ok, target} =
             target(
               base_url: "https://EXAMPLE.com:8443/api//v1/%25encoded",
               connect_policy: :public
             )

    assert Target.authority(target) == %{
             scheme: :https,
             host: "example.com",
             port: 8443,
             path_segments: ["api", "", "v1", "%encoded"]
           }

    assert inspect(target) == "#PtcLlmHttp.Target<redacted>"
  end

  test "admits plain HTTP only for a credential-free literal loopback target" do
    assert {:ok, target} =
             target(base_url: "http://127.0.0.1:4000/v1", connect_policy: :literal_loopback)

    assert Target.credential_compatible?(target, Credential.none())
    assert {:ok, credential} = Credential.bearer("secret")
    refute Target.credential_compatible?(target, credential)

    assert {:error, %Error{kind: :invalid_target}} =
             target(base_url: "http://example.com/v1", connect_policy: :public)
  end

  test "rejects HTTPS IP literals even under an explicit CIDR policy" do
    assert {:error, %Error{kind: :invalid_target}} =
             target(base_url: "https://192.0.2.1/v1", connect_policy: :public)

    assert {:error, %Error{kind: :invalid_target}} =
             target(
               base_url: "https://[2001:db8::1]/v1",
               connect_policy: {:allow_cidrs, ["2001:db8::/32"]}
             )
  end

  test "accepts canonical bounded CIDRs only for an HTTPS DNS name" do
    assert {:ok, _target} =
             target(
               base_url: "https://internal.example/v1",
               connect_policy: {:allow_cidrs, ["10.0.0.0/8", "fd00::/8"]}
             )

    assert {:error, %Error{kind: :invalid_target}} =
             target(
               base_url: "https://internal.example/v1",
               connect_policy: {:allow_cidrs, ["10.0.0.1/8"]}
             )

    assert {:error, %Error{kind: :invalid_target}} =
             target(
               base_url: "https://internal.example/v1",
               connect_policy: {:allow_cidrs, List.duplicate("10.0.0.0/8", 33)}
             )

    assert {:error, %Error{kind: :invalid_target}} =
             target(
               base_url: "https://internal.example/v1",
               connect_policy: {:allow_cidrs, ["0.0.0.0/0"]}
             )
  end

  test "compiled policies enforce current IANA reachability and exact CIDR edges" do
    assert ConnectPolicy.allowed?(:public, {8, 8, 8, 8})
    assert ConnectPolicy.allowed?(:public, {192, 0, 0, 9})
    refute ConnectPolicy.allowed?(:public, {10, 0, 0, 1})
    refute ConnectPolicy.allowed?(:public, {100, 64, 0, 1})
    refute ConnectPolicy.allowed?(:public, {169, 254, 169, 254})
    refute ConnectPolicy.allowed?(:public, {192, 0, 2, 1})
    refute ConnectPolicy.allowed?(:public, {198, 18, 0, 1})

    assert ConnectPolicy.allowed?(:public, {0x64, 0xFF9B, 0, 0, 0, 0, 0, 1})
    assert ConnectPolicy.allowed?(:public, {0x2001, 1, 0, 0, 0, 0, 0, 1})
    refute ConnectPolicy.allowed?(:public, {0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 1})
    refute ConnectPolicy.allowed?(:public, {0x2001, 2, 0, 0, 0, 0, 0, 1})
    refute ConnectPolicy.allowed?(:public, {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1})
    refute ConnectPolicy.allowed?(:public, {0x2002, 0, 0, 0, 0, 0, 0, 1})
    refute ConnectPolicy.allowed?(:public, {0x2D00, 0, 0, 0, 0, 0, 0, 1})
    refute ConnectPolicy.allowed?(:public, {0x3000, 0, 0, 0, 0, 0, 0, 1})
    refute ConnectPolicy.allowed?(:public, {0x3FFE, 0, 0, 0, 0, 0, 0, 1})
    refute ConnectPolicy.allowed?(:public, {0xFC00, 0, 0, 0, 0, 0, 0, 1})

    assert ConnectPolicy.allowed?(:public, {0x2001, 0x4860, 0, 0, 0, 0, 0, 1})
    assert ConnectPolicy.allowed?(:public, {0x2606, 0x4700, 0, 0, 0, 0, 0, 1})

    assert {:ok, {:allow_cidrs, cidrs}} =
             ConnectPolicy.compile({:allow_cidrs, ["10.0.0.0/24"]}, :https, "internal.example")

    assert ConnectPolicy.allowed?({:allow_cidrs, cidrs}, {10, 0, 0, 0})
    assert ConnectPolicy.allowed?({:allow_cidrs, cidrs}, {10, 0, 0, 255})
    refute ConnectPolicy.allowed?({:allow_cidrs, cidrs}, {10, 0, 1, 0})
  end

  test "rejects userinfo, query, fragment, invalid ports, and non-ASCII hostnames" do
    invalid_urls = [
      "https://user:pass@example.com/v1",
      "https://example.com/v1?secret=yes",
      "https://example.com/v1#fragment",
      "https://example.com:0/v1",
      "https://münich.example/v1"
    ]

    Enum.each(invalid_urls, fn url ->
      assert {:error, %Error{kind: :invalid_target}} = target(base_url: url)
    end)
  end

  test "rejects decoded separators, controls, malformed escapes, and traversal segments" do
    invalid_paths = [
      "/v1/%2Fadmin",
      "/v1/%5cadmin",
      "/v1/%00",
      "/v1/%0A",
      "/v1/%",
      "/v1/%2",
      "/v1/%GG",
      "/v1/.",
      "/v1/%2e%2e"
    ]

    Enum.each(invalid_paths, fn path ->
      assert {:error, %Error{kind: :invalid_target}} =
               target(base_url: "https://example.com" <> path)
    end)
  end

  test "requires raw path bytes to use the RFC 3986 pchar grammar" do
    for byte <- [" ", "\"", "<", ">", "[", "]", "^", "`", "{", "|", "}"] do
      assert {:error, %Error{kind: :invalid_target}} =
               target(base_url: "https://example.com/a#{byte}b")
    end

    assert {:ok, decoded} = target(base_url: "https://example.com/a%20b")
    assert Target.authority(decoded).path_segments == ["a b"]
  end

  test "rejects unknown or duplicate options and every bounded value at cap plus one" do
    assert {:error, %Error{kind: :invalid_target}} =
             Target.new([{:unknown, true} | target_options()])

    options = target_options()
    assert {:error, %Error{kind: :invalid_target}} = Target.new([{:model, "duplicate"} | options])

    assert {:error, %Error{kind: :invalid_target}} = target(model: :binary.copy("m", 257))

    assert {:error, %Error{kind: :invalid_target}} =
             target(capacity_group: :binary.copy("g", 129))

    assert {:error, %Error{kind: :invalid_target}} =
             target(max_encoded_request_bytes: 1_048_577)

    assert {:error, %Error{kind: :invalid_target}} =
             target(max_wire_response_bytes: 1_048_577)
  end

  test "inspection cannot reveal endpoint, model, or group sentinels" do
    assert {:ok, target} =
             target(
               base_url: "https://private-endpoint.invalid/v1",
               model: "private-model",
               capacity_group: "private-group"
             )

    inspected = inspect(target)
    assert inspected == "#PtcLlmHttp.Target<redacted>"
    refute inspected =~ "private"
  end

  defp target(overrides) do
    overrides = Map.new(overrides)

    target_options()
    |> Enum.map(fn {key, value} -> {key, Map.get(overrides, key, value)} end)
    |> then(&Target.new/1)
  end

  defp target_options do
    [
      kind: :openai_compat,
      base_url: "https://example.com/v1",
      model: "model",
      capacity_group: "default",
      connect_policy: :public,
      max_encoded_request_bytes: 1_000_000,
      max_wire_response_bytes: 1_000_000,
      tools: true,
      streaming: true,
      structured_output: :json_schema,
      cache_mode: :unsupported,
      upstream_routing: :opaque,
      usage_guarantees: %{tokens: true, cost: false}
    ]
  end
end
