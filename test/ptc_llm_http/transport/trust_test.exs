defmodule PtcLlmHttp.Transport.TrustTest do
  use ExUnit.Case, async: true

  alias PtcLlmHttp.Transport.Trust

  test "returns a non-empty platform authority list without spawning helpers" do
    :erlang.trace(self(), true, [:procs, :set_on_spawn])
    on_exit(fn -> :erlang.trace(self(), false, [:procs, :set_on_spawn]) end)

    assert Trust.system_authorities(fn -> ["authority"] end) == {:ok, ["authority"]}
    refute_receive {:trace, _pid, :spawn, _child, _mfa}
  end

  test "turns missing, invalid, raised, and exited stores into one closed failure" do
    assert Trust.system_authorities(fn -> [] end) == {:error, :no_trust_store}
    assert Trust.system_authorities(fn -> :invalid end) == {:error, :no_trust_store}
    assert Trust.system_authorities(fn -> raise "unreadable" end) == {:error, :no_trust_store}
    assert Trust.system_authorities(fn -> exit(:unavailable) end) == {:error, :no_trust_store}
  end
end
