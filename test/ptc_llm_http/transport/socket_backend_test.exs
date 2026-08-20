defmodule PtcLlmHttp.Transport.SocketBackendTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias PtcLlmHttp.Transport.SocketBackend

  describe "classify/1" do
    test "keeps timeout and closure as themselves" do
      assert SocketBackend.classify(:timeout) == :timeout
      assert SocketBackend.classify(:closed) == :closed
    end

    test "reduces a TLS alert to its name" do
      description = ~c"TLS client: In state wait_cert at ssl_handshake.erl:2257 ALERT"

      assert SocketBackend.classify({:tls_alert, {:bad_certificate, description}}) ==
               {:tls, :bad_certificate}
    end

    test "drops an option list rather than passing it on" do
      # OTP pairs this error with the options it rejected, private key included.
      key = {:ECPrivateKey, "secret-key-material"}

      assert SocketBackend.classify({:options, {:key, key}}) == {:transport, :invalid_options}
    end

    test "carries a POSIX reason under a transport tag" do
      assert SocketBackend.classify(:econnrefused) == {:transport, :econnrefused}
      assert SocketBackend.classify(:ehostunreach) == {:transport, :ehostunreach}
    end

    property "anything unrecognized becomes an unknown transport failure" do
      check all(reason <- one_of([binary(), list_of(binary()), tuple({integer(), binary()})])) do
        assert SocketBackend.classify(reason) == {:transport, :unknown}
      end
    end
  end

  describe "split/2" do
    test "returns short data whole" do
      assert SocketBackend.split("abc", 8) == {"abc", <<>>}
    end

    test "returns the cap and holds the rest" do
      assert SocketBackend.split("abcdef", 2) == {"ab", "cdef"}
    end

    property "never returns more than the cap, and never loses a byte" do
      check all(data <- binary(), max <- integer(1..64)) do
        {chunk, rest} = SocketBackend.split(data, max)

        assert byte_size(chunk) <= max
        assert chunk <> rest == data
      end
    end
  end

  describe "remaining/1" do
    test "reports the time left before an absolute deadline" do
      assert {:ok, remaining} =
               SocketBackend.remaining(System.monotonic_time(:millisecond) + 1_000)

      assert remaining in 1..1_000
    end

    test "treats a deadline that has arrived as a timeout" do
      assert SocketBackend.remaining(System.monotonic_time(:millisecond)) == {:error, :timeout}

      assert SocketBackend.remaining(System.monotonic_time(:millisecond) - 1) ==
               {:error, :timeout}
    end
  end
end
