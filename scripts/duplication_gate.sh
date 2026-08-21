#!/usr/bin/env bash
#
# Duplication ratchet. Fails only on clones absent from the committed baseline,
# so known debt does not hide newly introduced duplication.
#
#   scripts/duplication_gate.sh check
#   scripts/duplication_gate.sh bless

set -euo pipefail

cd "$(dirname "$0")/.."

MODE="${1:-check}"
BASELINE=".duplication-baseline.json"
REPORT="$(mktemp "${TMPDIR:-/tmp}/ptc-llm-http-clones.XXXXXX")"
RAW="$(mktemp "${TMPDIR:-/tmp}/ptc-llm-http-clones-raw.XXXXXX")"
trap 'rm -f "$REPORT" "$RAW"' EXIT

# Keep build output out of ExDNA's JSON stream.
mix compile >&2

# An unreachable budget makes clones reportable; detector failures still fail.
mix ex_dna lib/ test/ --format json --max-clones 1000000 >"$RAW"

# Mix may print dependency notices before the JSON object.
sed -n '/^{/,$p' "$RAW" >"$REPORT"

if [ ! -s "$REPORT" ]; then
  echo "duplication gate: ex_dna produced no JSON report. Raw output:" >&2
  tail -20 "$RAW" >&2
  exit 1
fi

exec python3 scripts/duplication_gate.py "$MODE" "$REPORT" "$BASELINE"
