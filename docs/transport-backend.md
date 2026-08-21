# Transport backend

Retained record of the socket and TLS decisions this package's transport rests
on, and of the measurements behind them. The spike that produced it is gone;
the numbers, the contract, and the tests that keep both honest are not.

Measured on macOS 15.3 (arm64) with Erlang/OTP 29.0.3 and Elixir 1.20.2, and
re-run in full on Linux with OTP 26.2.5 and OTP 27.3.4.

Two kinds of row appear below, and the difference matters. Rows marked
**(tested)** describe this package's own behavior and are assertions in
`test/ptc_llm_http/transport/`, which CI runs on Linux and macOS and, through
the shared setup action, on the declared OTP 29 baseline. Unmarked rows
characterize OTP itself — what a rejected API does, what a different setting
would have allowed, how much a connection process held. They were measured
once, during the spike, and are recorded because they are why the contract is
what it is. They are not re-run, and a future OTP could move them; if one ever
needs to be depended on, it needs a test first.

## The contract

The HTTP core reads through one operation:

```elixir
recv_up_to(socket, positive_max_bytes, absolute_deadline)
```

It must return as soon as one or more bytes are available, never return more
than the requested maximum, keep unread bytes for the next call in order and
exactly once, distinguish timeout from closure from transport failure, be
cancellable by owner death, and behave the same over TCP and verified TLS.

Two shapes are excluded by that definition rather than by preference: an
exact-size read cannot deliver a short response promptly, and an uncapped read
cannot bound what it hands back.

## Decision: pure OTP

`:gen_tcp` and `:ssl` in passive mode satisfy the contract, so the port helper
the plan held in reserve is not built. It would have cost frame validation
before allocation, stderr capture, process-group cleanup, release packaging,
and a platform matrix; nothing in the measurements below justifies that.

## What was measured

### Prompt partial delivery

| Case | Result |
| --- | --- |
| One byte available, caller asks 4 KiB (TCP and TLS) **(tested)** | returns that one byte immediately |
| `:gen_tcp.recv(socket, 4096, 300)` with one byte available | blocks the full 300 ms, returns `{:error, :timeout}`; the byte survives for the next read |
| Deadline already passed **(tested)** | `{:error, :timeout}` without touching the socket, both transports |

### Caps where the bytes arrive

`buffer` is the size the driver reads into, and it is what a passive
`recv(socket, 0, timeout)` will not exceed.

| Case | Result |
| --- | --- |
| TCP, 64 KiB pending, cap of 1024 **(tested)** | returns exactly 1024, and holds nothing back |
| TCP, cap shrunk mid-stream **(tested)** | next read honours the new size; already-buffered bytes are kept |
| TLS, 64 KiB in one `send`, `buffer: 262144` | returns up to 65536 in one call |
| TLS, same payload, `buffer: 16384` **(tested)** | returns at most 16384 |
| TLS, 400 small records, `buffer: 16384` **(tested)** | records coalesce, never past the cap |

`:ssl` will not hand back a fraction of a record, so the effective TLS arrival
bound is `max(16 KiB, buffer)`: 16 KiB is one record's maximum plaintext
(RFC 8446, section 5.1). Both backends pin `buffer` to 16 KiB so the two share
one memory profile, and the TCP backend narrows it further when the caller asks
for less. A TLS caller that asks for less than a record gets exactly what it
asked for, and the backend holds the rest — at most 16 KiB.

Holding the rest is one rule, not two. The carry belongs to the shared backend
contract rather than to either backend: the contract performs the split, stores
the remainder on the backend's `:leftover` field, and serves the next read from
that field without touching the socket. A backend supplies the field and its
own socket call; it does not get to decide what "in order and exactly once"
means. The deadline is still checked on a carried read, so a caller past its
deadline gets `:timeout` even when the answer was already in hand.

### Flow control

| Case | Result |
| --- | --- |
| Peer writes 8 MiB while the client never reads (TLS) | the writer blocks; the client's connection processes stay near 34 KiB |
| Client reads the same 8 MiB in bounded calls | largest chunk 16384, connection processes peak near 100 KiB |
| Peer floods 128 MiB in 64 KiB writes **(tested)** | blocked part-way, both transports |

Passive mode is what makes this true: `:ssl` stops reading ahead when nobody is
receiving, so the backlog stays in the peer's socket rather than in this VM.

One caveat worth knowing when reading the tests: a single large `:gen_tcp.send`
is queued by the driver and reports success, so backpressure shows up on the
*next* write, not that one.

### Handshake and certificate bounds

| Case | Result |
| --- | --- |
| Chain of 8 intermediates, `depth: 3` | rejected, `{:bad_cert, :max_path_length_reached}` |
| Same chain, `depth: 8` or `10` | accepted |
| 13 KiB chain, `max_handshake_size: 256` | accepted |
| 43 KiB chain, `max_handshake_size: 8192` / `65536` | rejected / accepted |
| 86 KiB chain, `max_handshake_size: 65536` | rejected |
| 200 KiB leaf, `max_handshake_size: 65536` / `202000` | rejected / accepted, on TLS 1.2 and 1.3 alike |
| 200 KiB chain rejected, 20 KiB chain accepted, at this package's 32 KiB **(tested)** | the bound is where it is documented to be |
| Chain of 15 intermediates rejected, 9 accepted, at `depth: 10` **(tested)** | the depth bound holds |

`depth: 10` equals OTP 26 through 29's own default, measured — 10 intermediates
accepted, 11 rejected, with the option left out. It is pinned so a future
default cannot widen the bound; the conformance test therefore proves the bound
holds, not that this package authored it. Narrowing it would reject peers every
other client reaches, which is a target-level decision rather than a
transport-level one.

`max_handshake_size` bounds a handshake message that spans several records; one
that fits inside a single record is always accepted. The real bound is
therefore `max(16 KiB, max_handshake_size)`. This package sets 32 KiB: today's
chains are a few KiB, post-quantum certificates will be larger, and 200 KiB of
certificate is not a chain, it is a payload.

### Ownership and failure vocabulary

| Case | Result |
| --- | --- |
| Owner killed after connecting **(tested)** | connection closes, the peer observes the close |
| Owner killed mid-handshake **(tested)** | the peer observes the close; nothing is left behind |
| Peer closes after partial data **(tested)** | buffered bytes are delivered first, then `{:error, :closed}` |
| Peer process killed abruptly, no close notification (TLS) **(tested)** | `{:error, :closed}`, no truncation-specific reason |
| Certificate names another host **(tested)** | rejected; the alert *name* differs by release |
| Chain deeper than `depth` **(tested)** | rejected; the alert *name* differs by release |
| ALPN with no overlap **(tested)** | `{:tls, :no_application_protocol}`; no other protocol is ever negotiated |
| Connection process dies in an orderly way | `:ssl` reports `{:error, :closed}` itself |
| Connection process hard-killed under a call **(tested)** | the exit is caught and reported as `{:transport, :process_exit}` |
| Closing **(tested)** | does not wait for the peer's close notification, and the peer still sees the connection go |
| Closing against a peer that is suspended or killed outright | returns in under a millisecond on OTP 26 and 29, with and without an explicit zero wait |

Alert names are not a stable interface, and this is not a theory: the same
misnamed host is `handshake_failure` on OTP 26 and `bad_certificate` on OTP 29,
and the same over-deep chain is `handshake_failure` on 26 and 29 but
`unknown_ca` on 27. Both were found by running the suite on each release. The
error mapping a consumer sees must therefore classify by kind — the handshake
failed, the peer could not be verified — and must never switch on the alert
atom. The atom is a diagnostic, not a contract, and the tests assert it the
same way.

An alert's second element is a description string carrying OTP source
locations and peer-supplied text, and an `{:options, _}` error carries the
option list with the private key in it. Neither travels: callers see
`{:tls, alert_name}` or `{:transport, reason}` and nothing else. `:ssl`'s own
`log_level` is set to `:none` for the same reason.

### What closing does and does not bound

`:ssl.close/2` is called with a zero wait, because this connection carried
`Connection: close` and will never be reused: waiting for the peer's own close
notification buys nothing and lets a peer that withholds one hold cleanup open.

It is not a hard latency bound, and should not be read as one. Closing is a
call into the connection process, and that call carries OTP's five-second
default, so a connection process that cannot answer could hold a caller for
that long. A peer that would cause it was not found — suspending the peer's
processes outright, killing them, and filling the send queue all return in
under a millisecond on both OTP 26 and 29 — but "not found" is not "impossible".

The bound that does hold structurally is ownership: the socket dies with the
process that opened it, immediately and regardless of the peer, which is
tested. A teardown budget that does not depend on `:ssl` answering therefore
belongs with the runtime slice that owns the attempt's processes, where killing
the owner is already the mechanism.

### Verification against a pinned address

Connecting to one approved IP address while SNI and certificate verification
use the original DNS name works, and a certificate that does not name that host
is rejected. Both are tested. The address policy the HTTP core will apply can therefore pin a
single resolved address without weakening what the peer has to prove.

## Bounds this backend does not set

A per-connection-process heap ceiling through `receiver_spawn_opts` was
measured and deliberately not shipped:

- it bounds the term heap, not the reference-counted binaries a response
  actually lives in — `include_shared_binaries` can measure those binaries,
  but a process heap ceiling still cannot bound them;
- a ceiling below what the connection process needs to start kills it while the
  caller is still linked during start-up, hanging the caller rather than
  failing it; and
- above that, a kill surfaces as a catchable exit, which is why every `:ssl`
  call here is wrapped and reported as `{:transport, :process_exit}`.

Bounding process memory is one decision for every role in this package, not a
per-socket option, so it belongs with the runtime's aggregate budget.

Kernel socket buffers are also outside this bound. They hold bytes the BEAM has
not copied and that TCP flow control eventually stops; the caps here are about
what enters the VM.

## Supported Erlang/OTP baseline: 29

The spike established that OTP 26 carried the primitives the transport needs,
but technical feasibility is not the support policy. The package and its only
consumer now standardize on OTP 29 and Elixir `~> 1.20`, enforced in `mix.exs`
and exercised on Linux and macOS in CI. OTP 26 and 27 measurements above remain
historical evidence; those releases are not supported runtimes.

## Trust source

`:public_key.cacerts_get/0`: the platform trust store, held in memory by OTP,
available inside an assembled release, and verified there by the release smoke.
This package ships no CA bundle and adds no CA dependency.

A host without usable trust material fails the connection with
`:no_trust_store` — whether the store could not be read or was read and held
nothing, and equally for an empty caller-supplied list.

The first `cacerts_get/0` in a node's life can reach the filesystem. The HTTP
runtime therefore performs that lookup inside the registered, heap-bounded DNS
role before the socket role starts. Deadline or caller cancellation kills the
whole attempt tree, so no trust helper can detach or survive capacity release;
later calls use OTP's cache. There is no fallback to unverified TLS and no
environment lookup. Callers may supply DER-encoded authorities instead.

On Ubuntu 24.04 / OTP 29.0.3, a spawned process that calls `cacerts_get/0`
on a 146-certificate platform store is killed at about 393,000 words and
survives at about 401,000. Hosts-file `localhost` resolution alone survives
well below 30,000 words. The DNS role therefore needs a heap floor sized for
trust load, not for `getaddrs` of `localhost`. `process-v2` grants 2,000,000
words once the attempt aggregate reaches the 4,000,000-word hostname budget,
which is the consumer-proven working DNS ceiling and leaves margin for the
macOS CI store. A 5% slice of 4,000,000 words (200,000) is below that floor
and is the cold-node failure reported against PtcLlmHttp 0.1.0.
