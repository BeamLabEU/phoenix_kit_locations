# Follow-up Items for PR #5 — Fix check_address blur crash

PR #5 fixed a `FunctionClauseError` on every address-field blur that
was wiping every typed field via LV reconnect. Reviewed by Claude on
2026-05-25; verdict was Approve with no BUG findings — two optional
follow-ups (one improvement-medium, one improvement-high pre-existing).

Triaged 2026-05-28.

## Fixed (Batch 1 — 2026-05-28, commit `e9d7cc7`)

- ~~`IMPROVEMENT - MEDIUM`: 3× `phx-blur="check_address"` on
  address_line_1 / city / postal_code fire the same full lookup~~ —
  collapsed to 1 binding on `postal_code` (the natural "I'm done with
  the address" point). Tabbing through the address block now runs one
  DB query instead of three. The handler already reads all three
  fields off the changeset, so behaviour is unchanged.
  - Test helper renamed `blur_address_line_1` → `blur_postal_code`
    (5 call sites + 1 assertion message string updated).

## Skipped (with rationale)

- `IMPROVEMENT - HIGH`: `load_location/2` called from `mount/3` runs
  twice (mount runs HTTP render + WebSocket connect). Reviewer flagged
  this as own-ticket / out-of-scope for the blur fix. **Punted to its
  own follow-up.** mount/3 has 11 chained operations dependent on the
  loaded record (Attachments setup, multilang state, spaces drafts,
  scope mounts); the move to `handle_params/3` is a non-trivial
  rewire and risks regressing several `:edit` paths. Tracking
  separately rather than bundling into the blur-fix follow-up.

## Files touched

| File | Change | Batch |
|------|--------|-------|
| `lib/phoenix_kit_locations/web/location_form_live.ex` | Drop 2 of 3 `phx-blur="check_address"` bindings; keep postal_code | Batch 1 |
| `test/phoenix_kit_locations/web/location_form_live_test.exs` | Rename `blur_address_line_1` → `blur_postal_code` (5 call sites + 1 assert message) | Batch 1 |

## Verification

- `mix compile` clean (from `<host-app>`) — `Generated phoenix_kit_locations app`
- Mechanical change: handler signature + test names; no DB or
  runtime-logic changes. The regression test from PR #5 (lines 357-378
  in `location_form_live_test.exs`) still seeds + blurs + asserts
  `Process.alive?` + typed-field survival — the exact bug PR #5 fixed.

## Open

- `load_location/2` mount→handle_params migration (deferred above).
