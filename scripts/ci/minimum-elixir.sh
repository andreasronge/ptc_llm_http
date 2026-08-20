#!/usr/bin/env bash

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$script_dir/_common.sh"

# The declared consumer surface: this library must compile with *only* its
# runtime dependencies present.
#
# Two different failures land here. Run under the oldest Elixir the package
# claims in `mix.exs`, it verifies that claim -- no dev or test tooling is
# fetched, so tooling that needs a newer Elixir cannot mask an incompatible
# library. Run under any Elixir, it still fails if production code reached for
# a dev/test-only dependency, which the minimal-runtime-dependency contract
# forbids.
export MIX_ENV=prod

# `--only prod` leaves the lock's dev/test entries alone; it selects what is
# fetched, it does not rewrite mix.lock.
mix deps.get --only prod
mix compile --warnings-as-errors
