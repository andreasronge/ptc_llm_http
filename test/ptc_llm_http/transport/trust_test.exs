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

  test "gives up at the deadline and takes the loader with it" do
    # The deadline is long enough that the loader has certainly been scheduled
    # and has announced itself; it is short enough to keep the test quick. Its
    # length is not what is being asserted.
    assert {:error, :timeout} = Trust.load(blocking_loader(self()), deadline(300))

    assert_receive {:loading, loader}, 5_000
    reference = Process.monitor(loader)
    assert_receive {:DOWN, ^reference, :process, ^loader, _killed}, 5_000
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
