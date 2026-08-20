#!/usr/bin/env bash

# Shared process contract for the repository-owned gates. Sourced by the
# executable entry points in this directory; never run directly.
#
# One implementation runs everywhere: `mix check` / `mix full_check`, the Git
# hooks, and GitHub Actions all call these scripts. A gate that only exists in
# a workflow file cannot be reproduced locally, and a gate that only exists in
# a Mix alias silently diverges from CI.

set -euo pipefail

ci_repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ci_repo_root"

export MIX_ENV=test
export HEX_SPONSOR=false
