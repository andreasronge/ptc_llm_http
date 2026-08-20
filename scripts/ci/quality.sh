#!/usr/bin/env bash

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$script_dir/_common.sh"

# Deterministic static gate. Fast enough for the per-commit path: no Dialyzer,
# no platform matrix, no release assembly.
mix deps.get --check-locked
mix compile --warnings-as-errors
mix format --check-formatted
mix xref graph --format cycles --label compile-connected --fail-above 0
mix credo --strict
