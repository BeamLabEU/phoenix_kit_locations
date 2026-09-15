# CLAUDE_REVIEW — 0.5.0: module-owned migrations, ownership, scoped access

**No PR:** direct commits on `main`, per the repo's workflow.
**Commits:** `34e5bac` (*Add module-owned migrations, location ownership and
owner-scoped access*), `0718a0a` (*Add organization sharing to owner-scoped
locations*); `0.4.2..0718a0a`, 34 files, +3713 / −614.
**Reviewed:** 2026-09-15 by an independent review agent (read-only), with
every finding verified against the code before acting.
**Verdict:** release after the fixes below.

## Scope

- `Migrations` V1 (adoption of core V135's four tables) and V2 (`owner_uuid`),
  checked against core's `v135.ex`, `PhoenixKit.Migrations.Modules` and the
  wrapper `mix phoenix_kit.update` generates.
- Ownership in `Locations` / `Location`.
- `Policy` (`locations` vs `locations.manage_all`, organization sharing) and
  every LiveView event path that consumes it: `LocationsLive`,
  `LocationFormLive`, `LocationStructureLive`, `LocationTypeFormLive`,
  `PlacePicker`, `ProjectSitesLive`.

Confirmed sound:
- Migrations: prefix regex, `nspname`-qualified guards, idempotence, a
  marker-less table reads as 0, `down` only rewrites the marker, and
  `version:` targeting matches core's wrapper.
- Owner is never cast from attrs.
- List, delete, and form mount/save resolve through `Policy`.
- The Types pages are gated.
- `PlacePicker` re-checks the owner filter on selection.

## Findings

### BUG - CRITICAL: file events bypassed `locations.manage_all` *(fixed)*

- **Scope:** `LocationFormLive` and `LocationStructureLive`.
- **Hole:** the Files card was hidden without `manage_all`, but
  `open_featured_image_picker`, `remove_file`, `clear_featured_image`,
  `set_active_upload_scope`, `cancel_upload` and the `attachment_files` upload
  were still registered and handled.
- **Aggravating:** `Attachments.inject_attachment_data/3` left a client-sent
  `data["files_folder_uuid"]` in place whenever the resource had no folder.
- **Scenario:** an owner-scoped user saves a forged folder uuid and reloads.
  The next mount targets that folder, so a forged `remove_file` soft-trashes
  another account's file and an upload writes into their folder.

**Fix:**
- Both LiveViews route file events through one `@attachment_events` clause that
  ignores them unless the live scope has `manage_all`.
- `allow_attachment_upload/1` runs only for `manage_all`; a new
  `uploads_in_flight?/1` covers templates without an upload config.
- `inject_files_folder(params, nil)` now removes a client pointer, matching
  what the featured-image path already did.
- `create_space` strips both pointers through the new
  `Attachments.drop_attachment_pointers/1`.

**Tests** (`scoped_locations_live_test.exs`, "hardening"):
- forged file events plus a forged `data` save leave no pointer;
- `create_space` with a forged pointer stores none.

### BUG - MEDIUM: Structure authorized only at mount *(fixed; organization part documented)*

**Problem:**
- `create_space`, `update_space_form`, `rename_space`, `confirm_delete_space` and
  `move_space_*` used the location loaded at mount.
- A location reassigned while the page was open kept accepting space changes
  until reconnect.

**Fix:** those events (`@location_writes`) re-resolve the location through
`Policy.get_location/2` before running, via a `location_rechecked` flag and
re-dispatch. A nil location redirects with "not found".

**Test:** writes stop after `set_location_owner/3` to someone else.

**Not fixed:** core's `Auth.set_organization` / `remove_from_organization`
broadcast no scope refresh, so `scope.user.organization_uuid` stays stale
until the next page load. Re-reading it from the DB on every event would put
a query on each check to cover a core gap. Recorded as an AGENTS.md landmine,
the same "next page load" semantics as core's role-switch settings.

### IMPROVEMENT - MEDIUM: `ProjectSitesLive` is not owner-scoped *(documented)*

- **Behaviour:** it shows every location named in the project config to every
  project viewer, via `Locations.get_location/1`.
- **Why not fixed:** scoping needs the viewer's scope in the hub's embed
  session, which the contract doesn't carry. Filtering by viewer would also
  hide company sites from project members who don't own them.
- **Recorded:** in the moduledoc and as an AGENTS.md TODO.

### NITPICK: malformed uuids crashed LiveViews *(fixed)*

- **Where:** `space_in_location/2` and `PlacePicker.selectable_location/2`.
- **Fix:** both cast the uuid before reading.
- **Also:** `open_add_child` accepts only a parent from the loaded tree, so a
  forged or malformed `parent_uuid` never reaches `create_space`.
- **Tests:** added for both LiveViews.

### NITPICK: `filter_owner/2` raised on unexpected shapes *(fixed)*

- A binary or list with malformed uuids now drops them.
- Any other value matches no rows (fail closed).
- Tests are in `location_owner_test.exs`.

### NITPICK: `toggle_type` accepted any uuid *(fixed)*

- **Problem:** a forged toggle could link an inactive type, or roll the sync
  back with a nonexistent one.
- **Fix:** toggles are limited to the active types the form offered plus the
  types already linked, so an inactive link still survives a save.
- **Test:** added.

### NITPICK: README drift *(fixed)*

- The `PlacePicker` example now uses `Policy.owner_uuids/1`, so organization
  locations aren't dropped.
- The Owner column, filter and picker are described as `manage_all`-only.

### NITPICK: upgrade ordering *(fixed)*

- The CHANGELOG now says to deploy only after `mix phoenix_kit.update` has run.
- Reason: `Location` reads `owner_uuid`, so every location query fails until
  the column exists.

## Validation

All run after the fixes:

- `mix format`: clean.
- `mix test`: 426 tests, 0 failures. One existing test forged `toggle_type` to
  reach the type-sync error path; it now reaches that path through a type
  deleted while the form is open.
- `mix precommit` (compile `--warnings-as-errors`, `deps.unlock
  --check-unused`, `hex.audit`, `quality.ci`): clean.
- `mix quality.ci` (format check, `credo --strict`, dialyzer): clean.
