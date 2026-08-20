#!/usr/bin/env bash

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$script_dir/_common.sh"

# GitHub renders `github` format as inline annotations; locally it is unusable
# next to dialyxir's grouped output.
if [ -n "${CI:-}" ]; then
  mix dialyzer --format github
else
  mix dialyzer --format dialyxir
fi
