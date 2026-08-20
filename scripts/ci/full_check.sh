#!/usr/bin/env bash

# Pre-push and pre-release gate: everything in check.sh, plus the slow platform
# and release work.
#
# The test step is not `check.sh`'s: it additionally includes the `:compat` and
# `:release` tagged tests that `mix test` excludes by default, so the suite runs
# once here rather than twice.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"$script_dir/quality.sh"
"$script_dir/tests.sh" --include compat --include release
"$script_dir/deps.sh"
"$script_dir/minimum-elixir.sh"
"$script_dir/dialyzer.sh"
"$script_dir/docs.sh"
"$script_dir/release.sh"
"$script_dir/package.sh"
