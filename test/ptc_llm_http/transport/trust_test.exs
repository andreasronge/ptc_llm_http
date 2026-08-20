defmodule PtcLlmHttp.Transport.TrustTest do
  use ExUnit.Case, async: true

  alias PtcLlmHttp.Transport.Trust

  defp deadline(milliseconds), do: System.monotonic_time(:millisecond) + milliseconds

  # A loader that announces itself and then never finishes, which is what a
  # trust store that will not answer looks like from here.
  defp blocking_loader(announce_to) do
    fn ->
      send(announce_to, {:loading, self()})

      receive do
        :never -> {:ok, :unreachable}
      end
    end
  end

  # The same, for tests that must not depend on the loader having reached its
  # first line before the deadline killed it.
  defp silent_loader do
    fn ->
      receive do
        :never -> {:ok, :unreachable}
      end
    end
  end

  test "returns what the loader returned" do
    assert Trust.load(fn -> {:ok, [:authority]} end, deadline(5_000)) == {:ok, [:authority]}

    assert Trust.load(fn -> {:error, :no_trust_store} end, deadline(5_000)) ==
             {:error, :no_trust_store}
  end

  test "gives up at the deadline and takes any loader it started with it" do
    # The loader records itself where the test can read it afterwards rather
    # than messaging: on a starved scheduler it may be killed before it runs at
    # all, and "nothing it started survives" is the contract either way. A
    # message-based barrier cannot be used here, because what is under test is
    # the deadline itself.
    started = :ets.new(:loader, [:public])

    loader = fn ->
      :ets.insert(started, {:loader, self()})

      receive do
        :never -> {:ok, :unreachable}
      end
    end

    assert {:error, :timeout} = Trust.load(loader, deadline(500))

    case :ets.lookup(started, :loader) do
      [{:loader, pid}] ->
        reference = Process.monitor(pid)
        assert_receive {:DOWN, ^reference, :process, ^pid, _killed}, 5_000

      [] ->
        :ok
    end
  end

  test "reports a loader that exits without answering" do
    # A normal exit does not travel down a link, so this is the case the
    # guardian's monitor exists for.
    assert Trust.load(fn -> exit(:normal) end, deadline(5_000)) == {:error, :no_trust_store}
  end

  test "leaves nothing in the caller's mailbox after giving up" do
    assert {:error, :timeout} = Trust.load(silent_loader(), deadline(50))

    assert Process.info(self(), :message_queue_len) == {:message_queue_len, 0}
  end

  test "stops the loader when the caller dies first" do
    test_process = self()

    caller =
      spawn(fn ->
        Trust.load(blocking_loader(test_process), deadline(30_000))
      end)

    assert_receive {:loading, loader}, 5_000
    reference = Process.monitor(loader)

    Process.exit(caller, :kill)

    assert_receive {:DOWN, ^reference, :process, ^loader, _killed}, 5_000
  end

  test "reports a loader that died without answering" do
    assert Trust.load(fn -> exit(:no_store_here) end, deadline(5_000)) ==
             {:error, :no_trust_store}
  end

  test "never starts a loader once the deadline has passed" do
    assert {:error, :timeout} =
             Trust.load(blocking_loader(self()), System.monotonic_time(:millisecond) - 1)

    refute_receive {:loading, _loader}, 100
  end
end
