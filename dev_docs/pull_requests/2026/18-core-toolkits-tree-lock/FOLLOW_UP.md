# Follow-up Items for PR #18 — Core toolkits, spaces tree lock, actor and activity through core

Post-merge check of CLAUDE_REVIEW.md findings against the current code on
`main`. Triaged 2026-10-01.

## Fixed (pre-existing)

- ~~**BUG - MEDIUM** Saving a space deleted since it was loaded crashed the
  Structure LiveView~~ — `locked_update/2` returns `{:error, :space_not_found}`
  when the locked read is `nil` (`spaces.ex:207-225`; spec at `:182`). Test:
  `test/spaces_test.exs:526`.
- ~~**BUG - MEDIUM** Same stale-struct raise in `update_location/3`~~ — rolls
  back to `{:error, :location_not_found}` (`locations.ex:296-303`), and
  `LocationFormLive` flashes `Errors.message/1` for an atom
  (`web/location_form_live.ex:412-419`). Test: `test/locations_test.exs:210`.

## Files touched

None — documentation only.

## Verification

Read `locked_update/2`, `update_location/3` and the form's save branches on
current `main`; confirmed both regression tests exist. No code was changed or
run in this triage.

## Open

- **NITPICK (awaiting Max's decision)** — `set_active_upload_scope/2` accepts
  any string (`attachments.ex:256-258`, reached from
  `web/location_form_live.ex:348` and `web/location_structure_live.ex:637`). An
  unknown scope uploads into a fresh pending folder nothing points at. Needs
  `manage_all` and touches no other account's data; the reviewer judged a fix
  not worth threading the scope list through both LiveViews.
