# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
While the version is `0.x`, breaking changes are expected and only require a
minor bump; consumers pin an exact tag or Git revision rather than a range.

## [Unreleased]

### Added

- Bounded socket backends for plain TCP and verified TLS, behind one internal
  `recv_up_to/3` contract: prompt partial delivery, an exact per-call maximum,
  unread bytes preserved in order, and timeout, closure, and transport failure
  told apart. Both are proven by one conformance suite against scripted local
  TCP and TLS peers, including deadline, peer-close, owner-death, flow-control,
  certificate-chain, and fragmentation cases.
- `docs/transport-backend.md`: the retained socket/TLS decisions and the
  measurements behind them.
- `PtcLlmHttp.Transport.Trust`: runs one blocking trust lookup under a deadline
  the caller can walk away from and cannot be hurt by.
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
