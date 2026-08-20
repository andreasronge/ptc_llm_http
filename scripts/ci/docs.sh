#!/usr/bin/env bash

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$script_dir/_common.sh"

# ExDoc is a dev-only dependency.
export MIX_ENV=dev

mix deps.get --check-locked
mix docs --warnings-as-errors

# The dependency-rules block in AGENTS.md is generated. This fails when a
# dependency change has left it stale; `mix usage_rules.sync --yes` rewrites it.
mix usage_rules.sync --check
