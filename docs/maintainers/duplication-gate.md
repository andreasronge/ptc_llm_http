# Duplication gate

This repository reuses PtcRunner's ExDNA-based duplication ratchet for its own
source. The tooling is development-only and is not part of the package runtime.

`mix check` and CI run `scripts/duplication_gate.sh check`. It compares an
[ExDNA](https://github.com/elixir-vibe/ex_dna) report with
`.duplication-baseline.json`. Known clones pass, new clones fail, and removed
clones pass with a prompt to shrink the baseline.

## Detection scope

The gate detects exact copies and copies with renamed variables (clone types I
and II) in `lib/` and `test/`. `.ex_dna.exs` requires at least 30 AST nodes and
excludes alias/import/require/use boilerplate. It does not detect equivalent
logic expressed with a different AST structure.

## Responding to a finding

Extract shared logic when the copies implement one rule or policy. Suppress a
copy when independent contracts only happen to look alike and extraction would
couple their owners:

```elixir
# ex_dna:disable-for-next-line — independent adapter callback
def callback(value), do: value
```

Use `scripts/duplication_gate.sh bless` only for existing duplication accepted
as debt. A baseline entry has no rationale, so deliberate new repetition should
normally use a reasoned suppression instead.

## Commands

```sh
scripts/duplication_gate.sh check
scripts/duplication_gate.sh bless
mix ex_dna lib/ test/
mix ex_dna.explain 1 lib/ test/
```

Clone fingerprints cover clone type, file paths, and AST-rendered bodies, but
not line numbers. Unrelated line movement therefore does not churn the
baseline. A clone may shrink without failing only when the ratchet can pair it
one-to-one with old debt and prove that its mass, files, occurrences, and
exactness did not grow.
