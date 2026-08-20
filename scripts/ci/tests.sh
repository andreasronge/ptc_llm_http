#!/usr/bin/env bash

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$script_dir/_common.sh"

# StreamData raises its property run count under CI. Establishing it here means
# a local gate and a GitHub job run the same property contract, without
# exporting CI to non-test gates such as Dialyzer, whose local PLT path
# selection depends on CI being unset.
export CI=1

# Extra arguments are forwarded to `mix test`, so a single case or a specific
# seed can be reproduced through the same gate that failed.
mix compile --warnings-as-errors
mix test --max-failures 1 --warnings-as-errors "$@"
