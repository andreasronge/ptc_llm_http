# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
While the version is `0.x`, breaking changes are expected and only require a
minor bump; consumers pin an exact tag or Git revision rather than a range.

## [Unreleased]

### Added

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
- GitHub Actions workflow: quality, tests on Linux and macOS, minimum
  Elixir/OTP compatibility, Dialyzer, docs, and release/package verification.
- The reserved public namespace `PtcLlmHttp` and its OTP application.

### Changed

- Erlang/OTP 26 is now the declared and enforced minimum, established by the
  socket/TLS spike rather than assumed. The compatibility job runs the whole
  suite on it.

### Fixed

- `mix check` and `mix full_check` now fail when a step fails. Their entry
  scripts ran every step regardless and reported the last one's status, so a
  Credo or formatting failure could pass the gate.

[Unreleased]: https://github.com/andreasronge/ptc_llm_http/commits/main
