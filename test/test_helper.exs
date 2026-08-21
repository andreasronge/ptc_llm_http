# Property tests run a fixed, higher case count under CI and the repository
# gates; `scripts/ci/tests.sh` sets CI=1 so a local gate and a GitHub job run
# the same contract.
if System.get_env("CI") do
  Application.put_env(:stream_data, :max_runs, 300)
end

# Tag meanings:
#
#   * `:release` - needs an assembled release or a built package tarball.
#                  `scripts/ci/release.sh` and `scripts/ci/package.sh` own it.
#   * `:soak`    - long-running resource/leak suite; `mix soak` runs it.
#
# Anything excluded here must be run by a named gate, and that gate must be
# listed in AGENTS.md. Never exclude a tag merely because it is slow: the
# per-commit gate is kept small by moving *platform* work out, not coverage.
ExUnit.start(exclude: [:release, :soak])
