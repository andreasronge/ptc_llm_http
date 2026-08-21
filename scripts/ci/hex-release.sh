#!/usr/bin/env bash

# Validate the identity selected by the protected Hex workflow. The workflow
# itself always comes from main; publish mode verifies that the remote tag names
# that exact commit before detaching at the already-reviewed candidate.

set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "usage: hex-release.sh VERSION MODE GITHUB_REF" >&2
  exit 64
fi

expected_version="$1"
mode="$2"
github_ref="$3"

if ! elixir -e '
  case Version.parse(hd(System.argv())) do
    {:ok, _version} -> System.halt(0)
    :error -> System.halt(1)
  end
' -- "$expected_version"; then
  echo "invalid release version: $expected_version" >&2
  exit 64
fi

if [ "$github_ref" != "refs/heads/main" ]; then
  echo "Hex release workflow must be dispatched from main" >&2
  exit 1
fi

case "$mode" in
  dry-run)
    ;;

  publish)
    tag_ref="refs/tags/v${expected_version}"
    git check-ref-format "$tag_ref"
    git fetch --force --no-tags origin "$tag_ref:$tag_ref"

    tag_commit="$(git rev-parse "$tag_ref^{commit}")"
    main_commit="$(git rev-parse HEAD)"

    if [ "$tag_commit" != "$main_commit" ]; then
      echo "$tag_ref does not name the dispatched main commit" >&2
      exit 1
    fi

    git checkout --detach "$tag_commit"
    ;;

  *)
    echo "invalid release mode: $mode" >&2
    exit 64
    ;;
esac

actual_version="$(
  mix run --no-start --no-compile --no-deps-check \
    -e 'IO.write(Mix.Project.config()[:version])'
)"

if [ "$actual_version" != "$expected_version" ]; then
  echo "mix.exs version $actual_version does not match $expected_version" >&2
  exit 1
fi
