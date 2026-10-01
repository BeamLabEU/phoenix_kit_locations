# Follow-up Items for PR #7 — Env-gated path override for phoenix_kit deps

Post-merge check of CLAUDE_REVIEW.md findings against the current code on
`main`. Triaged 2026-10-01.

## Fixed (pre-existing)

- ~~**BUG - MEDIUM** Empty `<APP>_PATH` produced a broken `path: ""` dep~~ —
  `pk_dep/3` reads `System.get_env(env_var, "") |> String.trim()` and treats
  blank as unset (`mix.exs:65-73`); the comment says "Unset or blank => the
  published pin" (`mix.exs:63`).
- ~~**IMPROVEMENT - LOW** Redundant `nil` clause split~~ — folded into the same
  fix; the no-path clauses branch on `""` (`mix.exs:69-70`).

## Files touched

None — documentation only.

## Verification

Read `pk_dep/3` and its call site (`mix.exs:88`) on current `main`. No code
was changed or run in this triage.

## Open

- **NITPICK (awaiting Max's decision)** — in path mode the version requirement
  is dropped (Mix rejects a requirement on a `path:` dep), so nothing checks
  that the local checkout meets the floor (`mix.exs:71`). The reviewer called
  it acceptable for local development and flagged it for awareness only.
