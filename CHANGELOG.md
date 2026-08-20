# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
While the version is `0.x`, breaking changes are expected and only require a
minor bump; consumers pin an exact tag or Git revision rather than a range.

## [Unreleased]

### Added

- Repository infrastructure: Mix project, formatter, Credo, Dialyzer, ExDoc,
  StreamData, and usage-rules tooling.
- Repository-owned gates `mix check` and `mix full_check`, implemented as
  scripts under `scripts/ci/` and shared by the Git hooks and GitHub Actions.
- GitHub Actions workflow: quality, tests on Linux and macOS, minimum
  Elixir/OTP compatibility, Dialyzer, docs, and release/package verification.
- The reserved public namespace `PtcLlmHttp` and its OTP application.

[Unreleased]: https://github.com/andreasronge/ptc_llm_http/commits/main
