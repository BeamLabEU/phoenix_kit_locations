# Follow-up Items for PR #14 — test: make the test database name overridable via PGDATABASE (+ PGPOOL)

Resolution of CLAUDE_REVIEW.md findings. Triaged 2026-10-22.

## Fixed

- AGENTS.md Testing section: `PGDATABASE` replaces the whole name, is libpq's standard variable, and `mix test.reset` would drop whatever it names.

## Open

- If core renames the variable (e.g. a `PHOENIX_KIT_TEST_DB`), follow it here.

## Verification

`mix test`: 588 tests, 0 failures. `mix precommit` (compile `--warnings-as-errors`, format, credo `--strict`, dialyzer, deps/hex audit) passed.

## Codex recheck — 2026-10-23

Trim settings before selecting defaults; added config tests covering blank/whitespace values, explicit names, partitions and valid/invalid pool sizes. Existing explicit PGDATABASE behavior is preserved.

See [CODEX_REVIEW.md](CODEX_REVIEW.md) for independent findings and final validation.

Final verification: `mix test` — 596 tests, 0 failures; `mix precommit`,
Hex package build and `git diff --check` passed.
