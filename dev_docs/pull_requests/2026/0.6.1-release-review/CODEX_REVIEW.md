# Release 0.6.1 review

- **Release:** [Hex 0.6.1](https://hex.pm/packages/phoenix_kit_locations/0.6.1)
- **Commit:** `b0d1d37` (tag `0.6.1`)
- **Reviewer:** Codex
- **Date:** 2026-10-01
- **Skills:** `pr-review-release`, `elixir:phoenix-thinking`, `elixir:ecto-thinking`

## Scope and evidence

Reviewed the changes since 0.6.0, including the core component migration,
forms, picker filters, gettext changes and embedded Sites view, with the
surrounding context APIs and tests. Compared all 30 packaged source and asset
files against tag `0.6.1`: identical. The initial suite passed 541 tests against
the locked Hex core 2.42.1; targeted new tests exposed the findings below.

Checked the newly used component attributes, slots and upload helper against
the published core 2.41.1 source, the declared minimum. The existing
`toolbar_actions` fix is compatible with both that source and locked core.
This was a source check of the minimum version, not a full test run against it.

## Findings

### BUG - HIGH — Final picker confirmation bypasses current owner/type/status filters

`PlacePicker.select_location` correctly rechecks the location when opening its
tree. Final `select_location_only` confirmation sends the cached location UUID
without another check. `select_space` checks only the cached tree, then sends the
same cached location UUID. A reassignment, removed type, deactivation or deletion
between browsing and confirmation therefore lets the picker emit a place it would
no longer offer. In particular, a tenant picker can emit another owner's location
after ownership changes.

**Fixed:** both confirmation paths use `send_selection/2`, which reloads the
location and reapplies every current picker filter. A space confirmation also
reloads the space and requires it to remain active and in that location. The
existing tree membership check still rejects forged UUIDs outside the offered
tree. Rejected confirmations send no selection message.

Tests cover owner reassignment, type removal, inactive/deleted locations and
inactive/deleted spaces, alongside the existing successful selection tests.

### BUG - MEDIUM — Saving a deleted location type crashes its open form

`update_location_type/3` calls `Repo.update` directly. Deleting a type in another
editor then submitting a changed name raises `Ecto.StaleEntryError`, terminating
the LiveView. Submitting unchanged attributes can instead return a false success
because Ecto skips an update with no changes. Locations and spaces already handle
deleted records explicitly; types lacked the same contract.

**Fixed:** hold the type row lock inside a transaction, returning
`{:error, :location_type_not_found}` when absent, including unchanged saves.
The type form distinguishes changeset errors from error atoms and redirects to
Types with the existing translated not-found message. Successful writes and
changeset failures retain their activity logging behavior; a missing record
does not log a successful update.

Tests cover the context result for changed/unchanged saves and the complete
LiveView redirect and error message after deletion.

### BUG - MEDIUM — Malformed type edit UUID crashes instead of redirecting

`get_location_type/1` passes the route parameter straight to `Repo.get`.
`/admin/locations/types/not-a-uuid/edit` raises `Ecto.Query.CastError` before the
form can handle its not-found branch.

**Fixed:** cast the UUID before querying and return `nil` on malformed input.
The existing missing-record redirect now covers malformed UUIDs, including
type lookup through list delete events. Context and LiveView regression tests
cover this behavior.

## Validation and limits

- `mix test`: 549 tests, 0 failures, including the database and LiveView tests,
  against Hex core 2.42.1.
- `mix precommit`: passed compilation with warnings as errors, unused dependency
  checking, Hex audit, format checking, strict Credo and Dialyzer.
- `git diff --check`: passed.

The picker validates at confirmation time; consumers must also validate a place
when persisting their own operation, because reference data may change after the
message. No production consumer exists yet. This change does not add live syncing
or alter the documented project Sites visibility contract.

No version bump, changelog entry or publication: this task reviews and improves
the published release; the fixes are committed for a subsequent release.
