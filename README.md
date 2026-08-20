# PtcLlmHttp

Bounded BEAM-native HTTP transport and wire codecs for LLM requests.

> **Status: pre-alpha.** Validated targets, call-local credentials, absolute
> deadlines, process budgets, and the fail-stop physical-admission runtime are
> in place. No HTTP request can be made yet; the HTTP core and codecs land in
> later slices under the approved implementation plan in `docs/plans/`.

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

## Requirements

Elixir `~> 1.15` and Erlang/OTP 26 or later. The OTP floor is what the bounded
socket and TLS behavior needs, not a preference — see
[docs/transport-backend.md](https://github.com/andreasronge/ptc_llm_http/blob/main/docs/transport-backend.md)
— and CI runs the transport suite on it. Development uses the toolchain pinned
in `mise.toml`.

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
