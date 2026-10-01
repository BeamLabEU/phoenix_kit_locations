# Follow-up Items for PR #9 — Hierarchical locations, Structure tree, PlacePicker

Post-merge check of CLAUDE_REVIEW.md findings against the current code on
`main`. Triaged 2026-10-01.

## Fixed (pre-existing)

- ~~**BUG - HIGH** `PlacePicker`'s seed-once fix defeated by
  `select_location`~~ — the handler keeps `selected_space_uuid` when it is in
  the newly loaded tree and clears it otherwise
  (`web/components/place_picker.ex:162-186`, `space_in_tree?/2`). Covered by
  the `"update/2 seed-once behavior"` tests
  (`test/phoenix_kit_locations/web/components/place_picker_test.exs:258`).
- ~~**Observation** `files_card.ex` used core's `PhoenixKitWeb.Gettext`
  backend~~ — the review judged it a faithful extraction and left it; it has
  since moved to the module's own backend
  (`web/components/files_card.ex:12`, `use Gettext, backend:
  PhoenixKitLocations.Gettext`).

## Files touched

None — documentation only.

## Verification

Read the `select_location` handler, the files card's Gettext backend and the
Structure LiveView's `mount/3` on current `main`; confirmed the seed-once
tests are in the suite. No code was changed or run in this triage.

## Open

- **IMPROVEMENT - LOW (awaiting Max's decision)** — DB queries in `mount/3`
  with no `handle_params/3`, so the HTTP and WebSocket mounts both query.
  The review noted it as the repo's existing convention, not a PR finding.
  Still the case in `web/location_structure_live.ex:58-79`
  (`Policy.get_location/2`, `Spaces.list_tree/1`), `web/location_form_live.ex:71`
  and `web/location_type_form_live.ex:27`. The same item is already open in
  PR #5's FOLLOW_UP.md (`load_location/2` mount → `handle_params`).
