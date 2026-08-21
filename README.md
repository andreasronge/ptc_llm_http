# PtcLlmHttp

Bounded BEAM-native HTTP transport and wire codecs for LLM requests.

> **Status: pre-alpha.** The bounded HTTP/1 core and public OpenAI-compatible
> text, function-tool, strict structured-output, and synchronous text-streaming
> calls are available.

## What this is

A small library that turns a validated request into **at most one** outbound
HTTP/1.1 attempt, reads a **bounded** response, and normalizes it through an
OpenAI-compatible codec.

It owns:

- one-attempt bounded HTTP/1 transport — DNS, TCP, TLS, framing;
- OpenAI-compatible chat-completion request and response codecs;
- optional Ollama-native codecs once the OpenAI-compatible path is complete;
- text, tool calls, declared structured output, streaming, and reported usage;
- physical outbound-connection admission; and
- typed, bounded transport and wire errors.

It does **not** own model selection, provider failover, credential storage,
application policy, call budgets, traces, pricing, model catalogs, or
provider-native APIs. Those belong to the consumer. No module here imports or
returns a consumer type.

## Fixed transport behavior

- HTTP/1.1 only, sending `Connection: close`.
- No retries, no redirects, no decompression, no cookies.
- No proxy, and no endpoint or credential lookup from the environment.
- HTTPS whenever a credential is present; plain HTTP only for a
  credential-free literal loopback target the constructor explicitly allows.
- Every external byte is bounded before it is accumulated.
- Deadlines and cancellation close the socket and release capacity on every
  exit path.

A new attempt against another model or provider is a new call by the consumer,
with its own authority, capacity, budget, and record. This library never
decides to try again.

## Non-streaming calls

Construct a validated `PtcLlmHttp.Target`, `PtcLlmHttp.Request`, absolute
`PtcLlmHttp.Deadline`, call-local `PtcLlmHttp.Credential`, and aggregate
`PtcLlmHttp.ProcessBudget`, then call `PtcLlmHttp.call/4`. Successful content
and usage are available through explicit redacted-value accessors. Expected
wire and provider failures return the closed facts in
`PtcLlmHttp.Error.contract/0`; raw provider text is never returned.

Requests can declare bounded strict function tools, replay assistant tool calls,
append ordered tool results, and request either strict JSON Schema output or the
older JSON-object mode when the target advertises it. Returned function
arguments are decoded to objects, checked against the declared tool schema, and
exposed through redacted `PtcLlmHttp.ToolCall` values. Structured content is
validated locally and returned as deterministic canonical JSON.

## Streaming calls

`PtcLlmHttp.stream/5` delivers `%{delta: text}` chunks to a synchronous
`:cont | :halt` callback. The callback runs in the attempt's monitored callback
process, and the socket is not read again until it returns, providing natural
backpressure without an `Enumerable` or producer mailbox. Success returns a
redacted `PtcLlmHttp.StreamComplete`; early halt returns a redacted
`PtcLlmHttp.StreamHalt`. Neither value accumulates generated text.

V1 streaming is text-only. Tool-bearing requests are rejected before connect,
and provider tool-call deltas are rejected as malformed streams rather than
silently discarded. The same absolute deadline covers callbacks; deadline,
caller cancellation, callback failure, and early halt all close the socket and
drain the attempt tree before capacity is released.

## Requirements

Elixir `~> 1.20` and Erlang/OTP 29 or later. This is the supported consumer and
development baseline; earlier OTP measurements remain documented in
[docs/transport-backend.md](https://github.com/andreasronge/ptc_llm_http/blob/main/docs/transport-backend.md)
as historical transport evidence. CI runs the complete suite on OTP 29 on Linux
and macOS.

## Development

```sh
mise install                 # Erlang/Elixir toolchain
mix deps.get
./scripts/install-hooks.sh   # once per clone or worktree

mix check                    # per-commit gate: format, compile, Credo, tests
mix full_check               # before push or release: adds Dialyzer, docs,
                             # dependency audit, release smoke, package contents
```

`mix check` is meant to stay comfortably under a minute warm. The gates are
shell scripts in `scripts/ci/`, and the Mix aliases, the Git hooks, and GitHub
Actions all run those same scripts — so a green local gate
means the same thing a green job does.

Repository conventions and agent instructions live in
[AGENTS.md](https://github.com/andreasronge/ptc_llm_http/blob/main/AGENTS.md).

## License

MIT. See [LICENSE](LICENSE).
