#!/usr/bin/env bash

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$script_dir/_common.sh"

# Package build plus contents inspection.
#
# The consumer pins an immutable revision of this package, so what ships is
# part of the contract. Two failures matter: a file the consumer needs that is
# missing, and a file that must never ship -- disposable plans, gate scripts,
# fixtures, or anything under test/ -- that leaked in.
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

mix hex.build --unpack -o "$work_dir/package"

contents="$(cd "$work_dir/package" && find . -type f | sed 's|^\./||' | sort)"
printf 'package contents:\n%s\n\n' "$contents"

status=0

require() {
  if ! printf '%s\n' "$contents" | grep -qx "$1"; then
    echo "missing from package: $1" >&2
    status=1
  fi
}

forbid() {
  if printf '%s\n' "$contents" | grep -qE "$1"; then
    echo "must not ship in package: matches /$1/" >&2
    status=1
  fi
}

require "mix.exs"
require "README.md"
require "LICENSE"
require "CHANGELOG.md"
require "lib/ptc_llm_http.ex"

forbid '^test/'
forbid '^scripts/'
forbid '^docs/plans/'
forbid '^\.github/'
forbid '\.plt$'

exit "$status"
