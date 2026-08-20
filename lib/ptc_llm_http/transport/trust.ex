defmodule PtcLlmHttp.Transport.Trust do
  @moduledoc false

  # Runs one blocking trust lookup under a deadline the caller can walk away
  # from, and cannot be hurt by.
  #
  # Reading a platform trust store touches the filesystem, and the first read in
  # a node's life is the slow one. Doing it inline would let a store that never
  # answers hold an attempt open past the time it was given, and doing it in a
  # linked task would let it take the caller down. So the work runs in a loader
  # process, and a guardian sits between the two:
  #
  #     caller ──monitors──▶ guardian ──links, monitors──▶ loader
  #        ▲                    │
  #        └────monitored by────┘
  #
  # Every exit path is covered by that shape. The caller times out and kills the
  # guardian, whose link takes the loader with it. The caller dies first and the
  # guardian, which is monitoring it, kills the loader. The loader finishes and
  # the guardian forwards its answer, then exits.
  #
  # The guardian forwards rather than letting the loader reply directly, and
  # that is the point of it existing at all: every message the caller can
  # receive then comes from one process, so the answer and the guardian's `DOWN`
  # arrive in that order, and a caller that has seen the `DOWN` knows nothing
  # else is coming.

  alias PtcLlmHttp.Transport.SocketBackend

  @type result :: {:ok, term()} | {:error, atom()}

  @doc """
  Runs `loader` in a cancellable process and returns its result.

  `{:error, :timeout}` if the deadline passes first, `{:error, :no_trust_store}`
  if the loader dies without answering. Nothing is left running, and nothing is
  left in the caller's mailbox.
  """
  @spec load((-> result()), SocketBackend.deadline()) :: result()
  def load(loader, deadline) when is_function(loader, 0) do
    with {:ok, timeout} <- SocketBackend.remaining(deadline) do
      caller = self()
      reply = make_ref()
      {guardian, monitor} = spawn_monitor(fn -> guard(caller, reply, loader) end)

      receive do
        {^reply, result} ->
          Process.demonitor(monitor, [:flush])
          result

        {:DOWN, ^monitor, :process, ^guardian, _died_before_answering} ->
          answer_or(:no_trust_store, reply)
      after
        timeout -> abandon(guardian, monitor, reply)
      end
    end
  end

  defp guard(caller, reply, load) do
    guardian = self()
    caller_down = Process.monitor(caller)

    # Linked so that a caller who kills this guardian takes the loader with it,
    # and monitored as well because a link only carries an abnormal exit: a
    # loader that answered nobody and exited normally would otherwise leave
    # this guardian waiting out the whole deadline.
    loader = spawn_link(fn -> send(guardian, {reply, load.()}) end)
    loader_down = Process.monitor(loader)

    receive do
      {^reply, result} ->
        send(caller, {reply, result})

      {:DOWN, ^loader_down, :process, ^loader, _answered_nobody} ->
        :ok

      {:DOWN, ^caller_down, :process, ^caller, _abandoned} ->
        Process.exit(loader, :kill)
    end
  end

  defp abandon(guardian, monitor, reply) do
    Process.exit(guardian, :kill)

    # The guardian is the only process that can have written to this mailbox,
    # so once its `DOWN` is here, anything it sent is here too.
    receive do
      {:DOWN, ^monitor, :process, ^guardian, _killed} -> answer_or(:timeout, reply)
    end
  end

  # A result that arrived in the moment before the deadline, or before the
  # guardian died, is still a result; anything else is the failure named here.
  defp answer_or(failure, reply) do
    receive do
      {^reply, result} -> result
    after
      0 -> {:error, failure}
    end
  end
end
