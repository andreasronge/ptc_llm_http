#!/usr/bin/env bash

# Per-commit gate. Target: comfortably under a minute warm.
#
# Deliberately absent: Dialyzer, the Elixir/OTP compatibility matrix, release
# assembly, package verification, and the docs build. Those are platform and
# release work, not correctness coverage -- see full_check.sh. Do not buy speed
# here by lowering property counts or skipping tests.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"$script_dir/quality.sh"
"$script_dir/tests.sh" "$@"
