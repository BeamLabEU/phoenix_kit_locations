# Follow-up Items for PR #17 — Media reorganizer source

Post-merge check of CLAUDE_REVIEW.md findings against the current code on
`main`. The 1,600-line planner has since been replaced by a 70-line
declaration on core's `Reorganizer.ResourceSource` (`f46b0cd`), so the
planning logic the review fixed now lives in core; the module's tests still
pin the behaviour. Triaged 2026-10-01.

## Fixed (pre-existing)

- ~~**BUG - MEDIUM** A failing name hook dropped that record's parent from the
  orphan scan~~ — fixed by the review; still pinned by
  `test/phoenix_kit_locations/media_reorganizer_test.exs:1698` against the
  core-backed source.
- ~~**BUG - MEDIUM** A pointer folder stuck on a pending name was never
  renamed~~ — fixed by the review; the declaration passes
  `pending_prefix: "location-attachment-pending-"`
  (`media_reorganizer.ex:29`), pinned by `media_reorganizer_test.exs:1669`.
- ~~**IMPROVEMENT - MEDIUM** No test that the plan passes core's
  `Action.new!/1`~~ — test asserts `unknown_keys/1 == []` on every action
  (`media_reorganizer_test.exs:1765`).
- ~~**NITPICK** `suffixed_variant?/2` accepted suffixes core rejects~~ — the
  local matcher is gone; suffix matching is core's.
- ~~**NITPICK** Stale "core does not ship the engine yet" comments~~ — the
  moduledoc now describes the `ResourceSource` declaration
  (`media_reorganizer.ex:1-16`).
- ~~**IMPROVEMENT - MEDIUM** Live `Attachments` lookup did not filter trashed
  folders~~ — fixed in `d934df5`: the live path goes through
  `ResourceFolders`, which no longer finds a trashed folder by name
  (`attachments.ex:86`, `:638-642`).

## Files touched

None — documentation only.

## Verification

Read the current `media_reorganizer.ex` and the commit messages of `f46b0cd`
and `d934df5`; grepped the reorganizer test file for the regression tests the
review added. No code was changed or run in this triage.

## Open

None.
