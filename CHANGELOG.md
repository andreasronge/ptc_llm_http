# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
While the version is `0.x`, breaking changes are expected and only require a
minor bump; consumers pin an exact tag or Git revision rather than a range.

## [Unreleased]

### Added

- `PtcLlmHttp.Error.facts/1`, a public closed instance projection of kind,
  phase, scope, dispatch, HTTP status, and documented provider code, so
  consumers can classify without reading opaque struct keys.

### Changed

- `ResourceContract.current/0` is now `resource-v2`. It publishes the
  `4_000_000`-word hostname-lookup aggregate beside the existing inclusive
  process-budget range, and names the package-owned `process-v2` partition.

### Fixed

- Cold HTTPS hostname attempts no longer die in the DNS role under the
  documented `4_000_000`-word aggregate. `process-v2` grants that role a
  `2_000_000`-word floor once the aggregate reaches the hostname budget and
  rebalances the other roles inside the same total, so callers do not have to
  inflate every ceiling to keep DNS alive. A fresh-OS/BEAM regression covers
  cold and warm `localhost` resolution without a public network.


## [0.1.0] - 2026-08-21

### Added

- Bounded synchronous OpenAI-compatible text streaming through `stream/5`,
  including incremental SSE parsing, natural callback backpressure, early halt,
  terminal usage, redacted stream results, and deterministic cleanup.
- Strict OpenAI-compatible function tools, assistant/tool replay messages,
  parallel returned tool calls with bounded schema-validated arguments, and
  redacted tool-call accessors.
- Strict JSON Schema and JSON-object response formats with pre-admission target
  capability checks, a closed bounded schema dialect, exact local fixtures,
  recursive response validation, and canonical JSON output.
- The `error-openai-v2` contract, adding a model-scoped structured-output
  refusal outcome without retaining provider refusal text.
- Public bounded OpenAI-compatible non-streaming text calls with validated and
  redacted requests, deterministic `/chat/completions` encoding, response and
  usage accessors, bounded codec-role JSON decoding, exact local wire fixtures,
  and one-attempt integration coverage.
- The completed `error-openai-v1` contract, including classified DNS,
  connection, TLS, HTTP framing, response-limit, status, documented provider
  code, and malformed-provider-response facts with exhaustive contract tests.

- A runtime-gated HTTP/1.1 core with bounded DNS results, address-policy
  enforcement, one pinned TCP/TLS connection, exact request serialization,
  strict incremental response parsing, content-length and chunked framing,
  bounded informational responses and trailers, and deterministic close on
  every outcome. Raw TCP/TLS and property-based fragmentation tests exercise
  arbitrary JSON echo traffic without exposing the provider call API early.
- Opaque, redacted target, credential, absolute-deadline, process-budget, and
  closed error contracts, including current address-policy and bearer-token
  validation.
- A fail-stop physical-admission runtime with atomic global/group ceilings,
  fixed-role bounded attempt trees, caller-retained terminal handoff, bounded
  concurrent cleanup, provisional caller-death-safe startup, generation
  fencing, and readiness/counter snapshots.
- Versioned `resource-v1`, `process-v1`, `runtime-control-v1`, and
  `error-base-v1` data contracts for consumer integration checks.
- Bounded socket backends for plain TCP and verified TLS, behind one internal
  `recv_up_to/3` contract: prompt partial delivery, an exact per-call maximum,
  unread bytes preserved in order, and timeout, closure, and transport failure
  told apart. Both are proven by one conformance suite against scripted local
  TCP and TLS peers, including deadline, peer-close, owner-death, flow-control,
  certificate-chain, and fragmentation cases.
- `docs/transport-backend.md`: the retained socket/TLS decisions and the
  measurements behind them.
- Platform-trust lookup runs under the attempt's deadline, in a process the
  caller can walk away from and cannot be hurt by.
- Repository infrastructure: Mix project, formatter, Credo, Dialyzer, ExDoc,
  StreamData, and usage-rules tooling.
- Repository-owned gates `mix check` and `mix full_check`, implemented as
  scripts under `scripts/ci/` and shared by the Git hooks and GitHub Actions.
- GitHub Actions workflow: quality, tests on Linux and macOS, Dialyzer, docs,
  and release/package verification on the supported toolchain.
- Protected, main-only Hex dry-run and publication automation with exact
  version/tag checks, step-scoped credentials, immutable third-party actions,
  and the complete release gate.
- The reserved public namespace `PtcLlmHttp` and its OTP application.

### Changed

- Elixir 1.20 and Erlang/OTP 29 are now the declared and enforced minimums,
  matching the only consumer and the development/CI baseline. Earlier OTP
  releases remain transport-spike evidence but are not supported runtimes.

### Fixed

- `mix check` and `mix full_check` now fail when a step fails. Their entry
  scripts ran every step regardless and reported the last one's status, so a
  Credo or formatting failure could pass the gate.

[Unreleased]: https://github.com/andreasronge/ptc_llm_http/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/andreasronge/ptc_llm_http/releases/tag/v0.1.0
