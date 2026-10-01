# Follow-up Items for PR #19 — Locations pages on core components

Resolution of CLAUDE_REVIEW.md findings. Triaged 2026-10-01.

## Fixed

- ~~**BUG - CRITICAL** `<:toolbar_primary>` crashed the Locations and Types lists on
  every published core~~ — both tables use `<:toolbar_actions>`
  (`web/locations_live.ex`). The toolbar-order test now asserts the button sits in the
  toolbar row above the table (`locations_live_test.exs`). AGENTS.md records the rule.

## Open

- **NITPICK** — nothing runs the suite against Hex core before a release. Run
  `mix test` without `PHOENIX_KIT_PATH` first. Awaiting a CI decision.
- Move the create buttons back to `:toolbar_primary` once a core release ships the slot
  and the `:phoenix_kit` floor is raised to it.

## Files touched

`lib/phoenix_kit_locations/web/locations_live.ex`,
`test/phoenix_kit_locations/web/locations_live_test.exs`, `AGENTS.md`, this folder.

## Verification

`mix test`: 541 tests, 0 failures against `phoenix_kit` 2.42.1 from Hex (38 failures
before). `mix precommit` (compile `--warnings-as-errors`, format, credo `--strict`,
dialyzer, deps/hex audit) passed.
