# Follow-up Items for PR #6 — Spaces + scope-aware Attachments

Post-merge check of CLAUDE_REVIEW.md findings against the current code on
`main`. The review applied every fix itself and left no open
recommendations. Triaged 2026-10-01.

## Fixed (pre-existing)

- ~~**BUG - CRITICAL** Saving a location with no staged spaces crashed the
  form (shadowed `persist_space_drafts([], …)` clause)~~ — fixed by the review;
  the whole staged-draft flow was later removed from `LocationFormLive` when
  PR #9 moved spaces to the immediate-commit Structure page.
  `persist_space_drafts` no longer exists anywhere in `lib/`.
- ~~**NITPICK** `<.textarea label={nil}>` attr warnings~~ — fixed by the
  review; those floor/room editors were removed with the draft flow in PR #9.
  No `label={nil}` remains in `lib/`.
- ~~**BUG - LOW** `Spaces.reorder_siblings/4` no-oped for root-level floors~~ —
  `sibling_position_query/3` has an `is_nil(s.parent_uuid)` clause for a `nil`
  parent (`spaces.ex:296-302`).
- ~~**NITPICK** Inconsistent key access in `update_space/3`'s cycle check~~ —
  `fetch_attr/2` reads both key shapes (`spaces.ex:399`) and feeds both the
  parent and cycle checks (`spaces.ex:208`, `:217`).
- ~~**NITPICK** `:parent_in_other_location` returned for a non-existent
  parent~~ — `check_parent_under_location/2` returns `:parent_not_found` for a
  missing parent (`spaces.ex:409-411`); message in `errors.ex:50`; specs list
  it (`spaces.ex:161`, `:184`).
- ~~**Process note** Add `mix compile --warnings-as-errors` to the gate~~ —
  `mix precommit` runs `compile --force --warnings-as-errors` (`mix.exs:40`).

## Files touched

None — documentation only.

## Verification

Grepped `lib/` for every symbol the review named and read the current
`spaces.ex`, `errors.ex` and `mix.exs` aliases. No code was changed or run in
this triage.

## Open

None.
