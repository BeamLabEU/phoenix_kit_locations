# Follow-up Items for PR #13 — Render LocationTabs through core nav_tabs

Post-merge check of GROK_REVIEW.md findings against the current code on
`main`. Triaged 2026-10-01.

## Fixed (pre-existing)

- ~~**BUG - MEDIUM** Details page never rendered the tab strip~~ —
  `LocationFormLive` imports and renders `<.location_tabs>` on `:edit` only
  (`web/location_form_live.ex:34`, `:511`). Fixed in `3d78c94`.
- ~~**BUG - MEDIUM** `version/0` drifted from `mix.exs`~~ —
  `@version Mix.Project.config()[:version]` single-sources it
  (`lib/phoenix_kit_locations.ex:39`, `:88`), and the test asserts against
  `Mix.Project.config()[:version]` (`test/phoenix_kit_locations_test.exs:132`).
- ~~**IMPROVEMENT - MEDIUM** `mix.exs` still admitted cores that double-prefix
  `:navigate`~~ — the core floor is now `>= 2.41.1 and < 3.0.0`
  (`mix.exs:88`), well above 2.13.6. Raised first to 2.38.0 in `d612119`.

## Skipped (with rationale)

- **Gettext `.po` line references stale by a few lines** — not a defect; the
  reviewer noted extraction refreshes them, and the catalogue has been
  re-extracted since (`e034333`).

## Files touched

None — documentation only.

## Verification

Read the form's tab import and render, `version/0`, the version test and the
`phoenix_kit` requirement on current `main`; traced the floor bumps with
`git log -G` on `mix.exs`. No code was changed or run in this triage.

## Open

None.

## Claude review (CLAUDE_REVIEW.md)
Resolution of CLAUDE_REVIEW.md findings. Triaged 2026-10-22.

### Claude review: fixed

- Dropped the stale `WarehouseHeader` reference from the `LocationTabs` moduledoc.

### Claude review: open

- None.

### Claude review: verification

`mix test`: 588 tests, 0 failures. `mix precommit` (compile `--warnings-as-errors`, format, credo `--strict`, dialyzer, deps/hex audit) passed.

## Codex recheck — 2026-10-23

Rechecked both LiveViews, active IDs, navigation URLs and published core; no further code fix needed.

See [CODEX_REVIEW.md](CODEX_REVIEW.md) for independent findings and final validation.

Final verification: `mix test` — 596 tests, 0 failures; `mix precommit`,
Hex package build and `git diff --check` passed.
