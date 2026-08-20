#!/usr/bin/env bash

# Install the tracked hooks in .githooks/ into this clone (or linked worktree).
# Git cannot ship hooks in a repository, so every clone runs this once.

set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

# Resolve through Git so linked worktrees and a configured core.hooksPath land
# where Git will actually execute them.
hooks_dir="$(git rev-parse --git-path hooks)"

if ! mkdir -p "$hooks_dir" 2>/dev/null || [ ! -d "$hooks_dir" ]; then
  echo "cannot install hooks: $hooks_dir is not a usable directory" >&2

  configured="$(git config --get core.hooksPath || true)"
  if [ -n "$configured" ]; then
    echo "core.hooksPath is set to: $configured" >&2
    echo "clear it with: git config --unset core.hooksPath" >&2
  fi

  exit 1
fi

for hook in pre-commit pre-push; do
  cp ".githooks/$hook" "$hooks_dir/$hook"
  chmod +x "$hooks_dir/$hook"
  echo "installed $hook"
done
