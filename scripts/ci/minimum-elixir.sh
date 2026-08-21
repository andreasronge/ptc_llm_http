#!/usr/bin/env bash

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$script_dir/_common.sh"

# The declared consumer surface: this library must compile with *only* its
# runtime dependencies present.
#
# On the supported Elixir/OTP baseline, no dev or test tooling is fetched, so
# this fails if production code reaches for a dev/test-only dependency. The
# package and consumer intentionally share that one baseline.
export MIX_ENV=prod

# `--only prod` leaves the lock's dev/test entries alone; it selects what is
# fetched, it does not rewrite mix.lock.
mix deps.get --only prod
mix compile --warnings-as-errors
