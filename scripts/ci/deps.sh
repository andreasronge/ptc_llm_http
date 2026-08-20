#!/usr/bin/env bash

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$script_dir/_common.sh"

# Dependency hygiene. Kept out of the per-commit path because `hex.audit`
# reaches the network; `quality.sh` already fails a lockfile that diverged
# from mix.exs.
mix deps.get --check-locked
mix deps.unlock --check-unused
mix hex.audit
