defmodule PtcLlmHttp.Http.TokenTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias PtcLlmHttp.Http.Token

  @tchar ~c"!#$%&'*+-.^_`|~" ++
           ~c"0123456789" ++
           ~c"abcdefghijklmnopqrstuvwxyz" ++
           ~c"ABCDEFGHIJKLMNOPQRSTUVWXYZ"

  describe "token?/1" do
    test "rejects the empty string" do
      # The production is `1*tchar`. Both call sites bound length separately,
      # but a caller reaching for the rule by name must get the rule.
      refute Token.token?("")
    end

    test "accepts the field names the wire actually carries" do
      assert Token.token?("Content-Length")
      assert Token.token?("content-type")
      assert Token.token?("X-Request-Id")
    end

    test "rejects the separators a field name must not contain" do
      separators = [":", ";", ",", "/", "(", ")", "<", ">", "@", "?", "=", " ", "\t"]
      separators = separators ++ ["\\", "\"", "[", "]", "{", "}"]

      for separator <- separators do
        refute Token.token?("name" <> separator), "accepted #{inspect(separator)}"
      end
    end

    test "rejects obs-text and control bytes" do
      refute Token.token?(<<"name", 0x80>>)
      refute Token.token?(<<"name", 0xFF>>)
      refute Token.token?(<<"name", 0x00>>)
      refute Token.token?(<<"name", 0x7F>>)
    end

    property "accepts exactly the non-empty strings of token characters" do
      check all(bytes <- list_of(integer(0..255))) do
        value = :binary.list_to_bin(bytes)
        expected = bytes != [] and Enum.all?(bytes, &(&1 in @tchar))

        assert Token.token?(value) == expected
      end
    end
  end

  describe "byte?/1" do
    property "agrees with token?/1 on every single byte" do
      check all(byte <- integer(0..255)) do
        assert Token.byte?(byte) == Token.token?(<<byte>>)
      end
    end
  end
end
