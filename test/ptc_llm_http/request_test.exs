defmodule PtcLlmHttp.RequestTest do
  use ExUnit.Case, async: true

  alias PtcLlmHttp.{Error, Request}

  test "validates the text-only request surface and redacts prompt data" do
    private = "sentinel-private-prompt"

    assert {:ok, request} =
             Request.new(
               system: "be concise",
               messages: [%{role: :user, content: private}],
               max_tokens: 64,
               temperature: 0.2,
               seed: 7,
               cache: false
             )

    assert inspect(request) == "#PtcLlmHttp.Request<redacted>"
    refute inspect(request) =~ private
  end

  test "rejects unknown keys, invalid roles, malformed UTF-8, and empty histories" do
    invalid = [
      [messages: [], cache: false],
      [messages: [%{role: :tool, content: "result"}]],
      [messages: [%{role: :user, content: <<255>>}]],
      [messages: [%{role: :user, content: "ok", private: true}]],
      [messages: [%{role: :user, content: "ok"}], model: "not-owned-here"],
      [messages: [%{role: :user, content: "ok"}], max_tokens: 9_223_372_036_854_775_808],
      [messages: [%{role: :user, content: "ok"}], seed: -9_223_372_036_854_775_809]
    ]

    Enum.each(invalid, fn options ->
      assert {:error, %Error{kind: :invalid_request}} = Request.new(options)
    end)
  end
end
