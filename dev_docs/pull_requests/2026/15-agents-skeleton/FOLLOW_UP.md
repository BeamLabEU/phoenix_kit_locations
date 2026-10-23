# Follow-up Items for PR #15 — Standardize AGENTS.md onto the shared module skeleton

Resolution of CLAUDE_REVIEW.md findings. Triaged 2026-10-22.

## Fixed

- AGENTS.md and the `test_helper.exs` comment describe the preflight.

## Open

- None.

## Verification

`mix test`: 588 tests, 0 failures. `mix precommit` (compile `--warnings-as-errors`, format, credo `--strict`, dialyzer, deps/hex audit) passed.

## Codex recheck — 2026-10-23

Moved migrations and sandbox setup outside the connection rescue. Regression tests prove migration errors fail startup and missing databases still permit unit tests; corrected setup/reset command examples.

See [CODEX_REVIEW.md](CODEX_REVIEW.md) for independent findings and final validation.

Final verification: `mix test` — 596 tests, 0 failures; `mix precommit`,
Hex package build and `git diff --check` passed.
