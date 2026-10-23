# Follow-up Items for PR #8 — Add PhoenixKit.SchemaPrefix for runtime named-schema (--prefix) support

Resolution of CLAUDE_REVIEW.md findings. Triaged 2026-10-22.

## Fixed

- Nothing needed fixing.

## Open

- Tighten the test to match `^\s*use PhoenixKit.SchemaPrefix` only if a schema ever slips through.

## Verification

`mix test`: 588 tests, 0 failures. `mix precommit` (compile `--warnings-as-errors`, format, credo `--strict`, dialyzer, deps/hex audit) passed.

## Codex recheck — 2026-10-23

Strengthened the conformance check to inspect real Elixir schema/use syntax; comments no longer satisfy it and table names need no special prefix.

See [CODEX_REVIEW.md](CODEX_REVIEW.md) for independent findings and final validation.

Final verification: `mix test` — 596 tests, 0 failures; `mix precommit`,
Hex package build and `git diff --check` passed.
