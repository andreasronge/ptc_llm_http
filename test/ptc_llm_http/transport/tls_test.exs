defmodule PtcLlmHttp.Transport.TlsTest do
  use PtcLlmHttp.Test.SocketBackendConformance, backend: PtcLlmHttp.Transport.Tls

  alias PtcLlmHttp.Test.Certificates
  alias PtcLlmHttp.Transport.Tls
  alias X509.Certificate.Validity

  @loopback {127, 0, 0, 1}

  # Which alert a rejected certificate produces is not stable across OTP
  # releases: the same over-deep chain is `handshake_failure` on 26 and 29 and
  # `unknown_ca` on 27, and the same misnamed host is `handshake_failure` on 26
  # and `bad_certificate` on 29. Every rejection here therefore asserts that the
  # handshake failed on the certificate, never which atom said so.
  @certificate_rejected [:bad_certificate, :handshake_failure, :unknown_ca]

  def start_peer, do: start_peer(Certificates.build())

  def start_peer(bundle) do
    start_supervised!({RawServer, [transport: :tls, certificates: bundle]})
  end

  def open(server, deadline), do: open(server, deadline, [])

  def open(server, deadline, overrides) do
    spec = %{
      address: @loopback,
      port: RawServer.port(server),
      hostname: "localhost",
      trust: RawServer.trust(server)
    }

    Tls.connect(Enum.into(overrides, spec), deadline)
  end

  def shrink_kernel_buffer(%Tls{socket: socket}), do: :ssl.setopts(socket, recbuf: 8_192)

  describe "handshake" do
    test "verifies the chain and negotiates HTTP/1.1" do
      {_server, socket} = connected()

      assert {:ok, "http/1.1"} = :ssl.negotiated_protocol(socket.socket)
    end

    test "verifies the certificate against the hostname while connecting to a pinned address" do
      # The leaf names only `localhost`; the socket goes to a literal address.
      # This is the shape the address policy needs: one approved address, with
      # the name the caller started from still deciding what the peer must
      # prove.
      server = start_peer(Certificates.build(names: ["localhost"]))

      assert {:ok, socket} = open(server, deadline(5_000))
      assert :ok = Tls.close(socket)
    end

    test "rejects a certificate that does not name the host asked for" do
      server = start_peer(Certificates.build(names: ["elsewhere.example"]))

      assert {:error, {:tls, alert}} = open(server, deadline(5_000))
      assert alert in @certificate_rejected
    end

    test "rejects a certificate that names the host only in its common name" do
      # RFC 9110 section 4.3.4: a client must not accept a CN-ID. The leaf here
      # says `CN=localhost` and carries no subject alternative name at all.
      server = start_peer(Certificates.build(names: [], common_name: "localhost"))

      assert {:error, {:tls, alert}} = open(server, deadline(5_000))
      assert alert in @certificate_rejected
    end

    test "rejects a chain that no trusted authority signed" do
      stranger = Certificates.build()
      server = start_peer(Certificates.build(trusted_by: [stranger.authority]))

      assert {:error, {:tls, alert}} = open(server, deadline(5_000))
      assert alert in @certificate_rejected
    end

    test "rejects an expired certificate" do
      validity = Validity.new(~U[2020-01-01 00:00:00Z], ~U[2020-02-01 00:00:00Z])

      server = start_peer(Certificates.build(validity: validity))

      assert {:error, {:tls, :certificate_expired}} = open(server, deadline(5_000))
    end

    test "accepts a chain at the depth limit and rejects one beyond it" do
      within = start_peer(Certificates.build(depth: 9))
      assert {:ok, socket} = open(within, deadline(5_000))
      assert :ok = Tls.close(socket)

      beyond =
        start_supervised!(
          {RawServer, [transport: :tls, certificates: Certificates.build(depth: 15)]},
          id: :beyond
        )

      assert {:error, {:tls, alert}} = open(beyond, deadline(5_000))
      assert alert in @certificate_rejected
    end

    test "rejects a certificate chain too large to reassemble within the bound" do
      oversized = Certificates.build(extensions: [oversized: extension(pad(200_000))])

      assert Certificates.chain_size(oversized) > 200_000
      server = start_peer(oversized)

      assert {:error, {:tls, alert}} = open(server, deadline(5_000))
      assert alert in @certificate_rejected
    end

    test "accepts a large chain that still fits inside the bound" do
      sized = Certificates.build(extensions: [oversized: extension(pad(20_000))])

      assert Certificates.chain_size(sized) in 20_000..32_768
      server = start_peer(sized)

      assert {:ok, socket} = open(server, deadline(5_000))
      assert :ok = Tls.close(socket)
    end

    test "refuses to negotiate a protocol other than HTTP/1.1" do
      server =
        start_supervised!(
          {RawServer, [transport: :tls, certificates: Certificates.build(), protocols: ["h2"]]}
        )

      assert {:error, {:tls, :no_application_protocol}} = open(server, deadline(5_000))
    end

    test "refuses to connect with no authorities to verify against" do
      server = start_peer()

      assert {:error, :no_trust_store} = open(server, deadline(5_000), trust: [])
    end

    test "gives up at the deadline when the peer never answers the handshake" do
      # A plain-TCP peer accepts the connection and says nothing further, which
      # is also the proof that this backend has no plaintext fallback: it never
      # produces a usable socket, it times out.
      server = start_supervised!({RawServer, [transport: :tcp]})

      assert {:error, :timeout} =
               Tls.connect(
                 %{
                   address: @loopback,
                   port: RawServer.port(server),
                   hostname: "localhost",
                   trust: Certificates.build().roots
                 },
                 deadline(100)
               )
    end

    test "closes the connection when the caller dies mid-handshake" do
      server = start_supervised!({RawServer, [transport: :tcp]})
      port = RawServer.port(server)

      trust = Certificates.build().roots

      caller =
        spawn(fn ->
          Tls.connect(
            %{address: @loopback, port: port, hostname: "localhost", trust: trust},
            deadline(30_000)
          )
        end)

      :ok = RawServer.await_connection(server)

      reference = Process.monitor(caller)
      Process.exit(caller, :kill)
      assert_receive {:DOWN, ^reference, :process, ^caller, :killed}, 5_000

      assert :ok = RawServer.await_close(server, 5_000)
    end

    test "refuses a connection whose deadline has already passed" do
      server = start_peer()

      assert {:error, :timeout} = open(server, expired_deadline())
      assert RawServer.connection_count(server) == 0
    end

    @tag :capture_log
    test "never turns undecodable trust material into trust" do
      server = start_peer()

      # `:ssl` skips a CA it cannot decode rather than refusing the option, so
      # the failure surfaces as a chain that nothing vouches for. Either way it
      # must fail; what it must not do is proceed.
      assert {:error, {:tls, alert}} = open(server, deadline(5_000), trust: ["not a certificate"])
      assert alert in @certificate_rejected
    end

    test "does not start loading platform trust once the deadline has passed" do
      server = start_peer()

      assert {:error, :timeout} = open(server, expired_deadline(), trust: :system)
      assert RawServer.connection_count(server) == 0
    end

    test "reaches the platform trust store rather than failing for want of one" do
      server = start_peer()

      # The fixture's private authority is not in the platform store, so the
      # handshake must fail on the certificate — never on a missing store,
      # which is what a release without usable trust material would report.
      assert {:error, {:tls, _alert}} = open(server, deadline(5_000), trust: :system)
    end

    test "reports a connection process killed under a read instead of exiting the caller" do
      {_server, socket} = connected()

      # Every `:ssl` operation is a call into that process, and `:ssl` turns an
      # orderly death into `:closed` itself. A hard kill while a read is in
      # flight is what is left: without the guard it would exit a caller that
      # only asked for bytes. Slice 2's per-role ceilings make this reachable
      # in production, so the path is worth holding now.
      reader = Task.async(fn -> Tls.recv_up_to(socket, 16, deadline(30_000)) end)
      await_blocked(reader.pid)

      # Where `:ssl` keeps those pids inside its socket term differs by release,
      # so they are found by walking it. Asserting that some were found keeps a
      # future shape change loud instead of turning this into a test that kills
      # nothing and proves nothing.
      assert [_ | _] = processes = connection_processes(socket.socket)
      Enum.each(processes, &Process.exit(&1, :kill))

      assert {:error, {:transport, :process_exit}} = Task.await(reader, 5_000)
    end
  end

  test "inspection reveals nothing about the connection" do
    {_server, socket} = connected()

    assert inspect(socket) == "#PtcLlmHttp.Transport.Tls<redacted>"
    refute inspect(socket) =~ "socket"
  end

  test "reports closure when the peer dies without a close notification" do
    {server, socket} = connected()
    reference = Process.monitor(server)
    Process.exit(server, :kill)
    assert_receive {:DOWN, ^reference, :process, ^server, :killed}, 5_000

    assert {:error, :closed} = Tls.recv_up_to(socket, 4_096, deadline(5_000))
  end

  test "many small records still arrive within one record's cap" do
    {server, socket} = connected()
    Enum.each(1..400, fn _ -> :ok = RawServer.write(server, :binary.copy("z", 200)) end)

    {read, socket} = read_bytes(socket, 80_000, [SocketBackend.max_chunk()])
    assert byte_size(read) == 80_000
    assert socket.leftover == <<>>
  end

  test "one arrival is one TLS record at most, whatever the caller asks for" do
    {server, socket} = connected()
    :ok = RawServer.write(server, :binary.copy("a", 65_536))

    assert {:ok, chunk, socket} = Tls.recv_up_to(socket, 1_000_000, deadline(5_000))
    assert byte_size(chunk) <= SocketBackend.max_chunk()
    assert socket.leftover == <<>>
  end

  defp extension(value), do: {:Extension, {1, 3, 6, 1, 4, 1, 57_264, 1}, false, value}

  defp pad(bytes), do: :binary.copy("A", bytes)

  defp connection_processes(pid) when is_pid(pid), do: [pid]

  defp connection_processes(term) when is_tuple(term),
    do: term |> Tuple.to_list() |> connection_processes()

  defp connection_processes(term) when is_list(term),
    do: Enum.flat_map(term, &connection_processes/1)

  defp connection_processes(_other), do: []

  # Blocks until `pid` is parked in a receive, so a test can act on a call that
  # is genuinely in flight rather than one that might not have started.
  defp await_blocked(pid, attempts \\ 100_000)

  defp await_blocked(pid, 0), do: flunk("#{inspect(pid)} never blocked")

  defp await_blocked(pid, attempts) do
    case Process.info(pid, :status) do
      {:status, :waiting} -> :ok
      _running -> await_blocked(pid, attempts - 1)
    end
  end
end
