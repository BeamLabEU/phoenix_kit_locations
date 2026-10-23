# Follow-up Items for PR #11 — Add a conformance test for the :phoenix_kit requirement

Resolution of CLAUDE_REVIEW.md findings. Triaged 2026-10-22.

## Fixed

- Nothing needed fixing.

## Open

- None.

## Verification

`mix test`: 588 tests, 0 failures. `mix precommit` (compile `--warnings-as-errors`, format, credo `--strict`, dialyzer, deps/hex audit) passed.

## Codex recheck — 2026-10-23

Restored the Hex core dependency, raised its floor to 2.63.0 for Cities, and test the committed source/options in an isolated VM without a local override. The current GitHub-source and low-floor regressions were reproduced before fixing. Also updated plug_crypto 2.2.0 to patched 2.2.1 after the dependency audit reported EEF-CVE-2026-105963.

See [CODEX_REVIEW.md](CODEX_REVIEW.md) for independent findings and final validation.

Final verification: `mix test` — 596 tests, 0 failures; `mix precommit`,
Hex package build and `git diff --check` passed.
