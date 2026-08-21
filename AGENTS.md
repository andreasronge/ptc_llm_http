# Repository Instructions

Canonical agent instructions for this repository. `CLAUDE.md` is a symlink to
this file, so Claude Code and Codex read the same rules. Edit only this file.

PtcLlmHttp is a bounded BEAM-native HTTP/1 transport and wire-codec library for
LLM requests. The approved plan is
[`docs/plans/implementation.md`](docs/plans/implementation.md); read the slice
you are working on before writing code.

## Status

Pre-alpha. The repository holds infrastructure and the reserved public
namespace. No network call is possible yet.

## Boundaries

- **No consumer types.** No module imports or returns a `PtcRunner.*` type, and
  nothing here reads consumer configuration. The package's public API must be
  usable with no knowledge of PtcRunner.
- **No copying.** Do not copy helpers or implementation modules from PtcRunner
  or ReqLLM into this repository. Wire fixtures may be derived from published
  protocols or independently captured local test traffic, with their origin
  recorded in `docs/protocol-evidence.md`.
- **Not owned here:** model selection, provider failover, credential storage,
  application policy, provider-task heaps, call budgets, traces, pricing, model
  catalogs, and provider-native APIs.
- **Runtime dependencies stay minimal.** JSON only. Req, Finch, Mint, an HTTP
  server, a model database, and provider SDKs must not become runtime
  dependencies. Everything else is `only: [:dev, :test]`.

## Transport rules

These are contract, not defaults. Changing one is a plan change, not a code
change.

- No automatic retries, redirects, decompression, cookies, or proxy support,
  and no endpoint or credential lookup from the environment.
- HTTP/1.1 only; send `Connection: close`. One request performs at most one
  DNS/connect/send attempt over at most one connection.
- Every external byte is bounded before it is accumulated. A cap is applied
  where the bytes arrive, not after a buffer has grown.
- Deadlines and cancellation close the socket and release capacity on **every**
  exit path — success, error, timeout, callback failure, and caller death.
- HTTPS whenever a credential is present. Plain HTTP only for a credential-free
  literal loopback target the constructor explicitly allows.
- A direct call must not be able to bypass a configured physical-connection
  runtime.

## Code rules

- **One module per file**, named after the file.
- Do not copy a helper into another module to avoid an import. `mix check`
  rejects duplication absent from `.duplication-baseline.json`; extract shared
  policy, or suppress deliberate repetition with a reason. See
  `docs/maintainers/duplication-gate.md`.
- **Redaction before use.** Target, credential, request, response, error,
  tool-call, and stream-state structs get a redacted `Inspect` implementation,
  with a test asserting the sentinel, in the same commit that introduces the
  struct. Secrets, private endpoints, prompts, and model output must not leak
  through inspection, logs, or telemetry.
- **Owner-process state changes use atomic owner operations.** Never
  read-then-write shared capacity across a message boundary.
- **Public API additions require a plan update.** Update
  `docs/plans/implementation.md` and the API contract in the same change.
- **Do not raise on external input.** Constructors validate and return typed
  errors. Programmer misuse of a trusted callback may raise, but only after
  cleanup has run.
- Do not link to `docs/plans/` from code documentation; plans are disposable.
  Durable contracts belong in module docs or a retained document such as
  `docs/protocol-evidence.md`.

## Test rules

- **Bug fixes start with a failing test** at the wire or integration level that
  reproduces the bug, committed before the fix.
- **No `Process.sleep` in tests.** Use monitors, barriers, held sockets, and
  messages.
- No correctness test uses a public network or real credentials. Raw local
  TCP/TLS fixtures script exact bytes and lifecycle events.
- Assert connection and attempt counts deterministically at the fixture server.
- Prefer parser fragmentation tables and property tests over assertions that
  mirror implementation branches.
- After a load-sensitive failure, rerun the exact failing seed and case before
  concluding anything about it.

### Test tags

Excluded from `mix test` by default (`test/test_helper.exs`); each one has a
named gate that runs it:

| Tag | Meaning | Gate |
| --- | --- | --- |
| `:release` | Requires an assembled release or built package | `release-package` job, `mix full_check` |
| `:soak` | Long-running resource/leak trend suite | `mix soak` |

`mix soak` exits non-zero with "no test was executed" until the first `:soak`
test lands; the resource and soak suite arrives with Slice 7.

Never exclude a tag merely because it is slow. The per-commit gate is kept
small by moving *platform* work out, not by dropping coverage.

## Commands

- `mix check` — per-commit gate: lock check, format, compile with warnings as
  errors, compile-cycle check, Credo, duplication ratchet, and the test suite.
  Target: comfortably under a minute warm. Run before every commit.
- `mix full_check` — everything in `mix check`, plus the `:release` tests,
  dependency audit, the runtime-dependency check
  (`scripts/ci/minimum-elixir.sh`: the library must compile with only its
  runtime dependencies fetched), Dialyzer, docs with warnings as errors, the
  minimal release smoke, and package-contents verification. Run before a
  release.
- `scripts/ci/tests.sh [args]` — the canonical test gate. It sets `CI=1`, so
  property tests run the same case count locally and in CI. Extra arguments go
  to `mix test`, which is how a specific seed or case is reproduced through the
  gate that failed.
- `./scripts/install-hooks.sh` — install the tracked Git hooks; run once per
  clone or worktree.
- `git push` — the pre-push hook runs `scripts/ci/full_check.sh`, covering every
  gate meaningful on the supported Elixir 1.20 / OTP 29 toolchain. GitHub
  Actions additionally runs the OS matrix.

The gates are shell scripts in `scripts/ci/`. The Mix aliases, the Git hooks,
and GitHub Actions all call those same scripts — never add a gate step to a
workflow file alone, or it becomes unreproducible locally.

## Worktrees

Several agents may work in parallel worktrees.

- Do not share a writable `_build` or project Dialyzer PLT between concurrent
  worktrees. The core PLT is shared read-mostly under
  `~/.cache/ptc_llm_http/dialyzer_plts`; the project PLT stays worktree-local.
- Assign files and slices so two agents never edit the same parser owner.
- Serialize `mix full_check` and release builds on one machine rather than
  running several CPU-saturating copies.
- Review concurrency and transport changes against a fault matrix: owner death,
  callback death, timeout, peer close, parser rejection, and cleanup.

## Commit messages

Conventional Commit subjects, e.g. `feat(transport): bound chunked reads`. For
non-trivial commits add a short body covering what changed and how it was
verified.

## Working style

This is a **0.x library** — breaking changes are expected. When refactoring,
delete old code rather than deprecate it; add no compatibility shims. Explore
the source before claiming something is missing. Fix code and docs together.

## Cursor Cloud specific instructions

This is a library, not a service: there is nothing to "serve". Development is
compile / lint / test / release-gate work plus exercising the public API in
`iex`/`mix run`. The standard commands live in the `## Commands` section above
and in the README — use those; nothing below repeats them.

- **Toolchain is mise-managed** (Erlang/OTP and Elixir pinned in `mise.toml`,
 currently OTP 29.0.3 / Elixir 1.20.2-otp-29). The startup update script runs
 `mise install` followed by `mix deps.get`; you do not need to install the
 toolchain yourself.
- **`mise` is only on `PATH` in interactive shells** (activated via `~/.bashrc`).
 Non-interactive shells — including the agent's own command tool — do **not**
 inherit it. Prefix commands with `~/.local/bin/mise exec --`
 (e.g. `~/.local/bin/mise exec -- mix check`), or run
 `eval "$(~/.local/bin/mise activate bash)"` first. Bare `mix`/`elixir` will
 otherwise be "command not found".
- **Git hooks are not installed automatically.** Run `./scripts/install-hooks.sh`
 once per clone/worktree if you need them. The `pre-push` hook runs
 `mix full_check`, whose Dialyzer step builds a core PLT under
 `~/.cache/ptc_llm_http/dialyzer_plts` on first use (slow the first time, cached
 after). `mix full_check` passes cleanly in this environment.
- **Expected test noise:** the suite deliberately kills supervised processes to
 exercise fault paths, so `[error] GenServer ... terminating ** (stop) killed`
 and an `SSL WARNING: Ignoring a CA cert` line appear on a *passing* run. Judge
 the run by the final `Result:` line, not these logs.
- Tests never touch the public network or real credentials; they script raw
 local TCP/TLS fixtures, so no secrets are required to run the full suite.

<!-- usage-rules-start -->
<!-- usage_rules:elixir-start -->
## usage_rules:elixir usage
[usage_rules:elixir usage rules](deps/usage_rules/usage-rules/elixir.md)
<!-- usage_rules:elixir-end -->
<!-- usage_rules:otp-start -->
## usage_rules:otp usage
[usage_rules:otp usage rules](deps/usage_rules/usage-rules/otp.md)
<!-- usage_rules:otp-end -->
<!-- usage-rules-end -->
