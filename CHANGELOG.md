# Changelog

## 0.4.2 - 2026-08-22

### Changed

- **Details/Structure tab strip uses core `<.nav_tabs variant={:border}>`** (#13).
  The wrapper's local API (`location` + `active` atom) is unchanged; only the
  markup moves to core so the underline look stays in one place. Needs
  `phoenix_kit` 2.13.6 (verbatim `:navigate` + the border variant); the mix.exs
  pin stays `~> 2.0` so later 2.x minors still resolve.

### Fixed

- The edit Location form now shows the Details/Structure tab strip. It was
  only rendered on the Structure page, so there was no in-page way from
  Details to Structure.
- `PhoenixKitLocations.version/0` had drifted to `"0.4.0"` after the 0.4.1
  bump. It now has to match `mix.exs`.

## 0.4.1 - 2026-08-11

### Fixed

- **Sidebar tab labels are translated** (#12). All eight admin tabs now declare
  `gettext_backend` and `gettext_domain`. Without them a tab label is passed
  through untranslated no matter what the `.po` files hold, so the Locations
  section stayed English in every locale while its pages were fully translated.

### Changed

- Dependency updates (`phoenix_kit` 2.2.0, `phoenix` 1.8.10, `hackney` 4.7.3).

## 0.4.0 - 2026-08-10

### Changed

- **⚠️ Requires `phoenix_kit ~> 2.0`.** The core pin moved to `~> 2.0`, so this
  release no longer resolves against core 1.7.

  Core 2.0.0 squashes the migration chain into a single `V135` baseline and makes
  V135 the chain's floor: `mix ecto.migrate` now *refuses* on a database below it
  rather than migrating. Check `mix phoenix_kit.status` **before** upgrading. A
  host below V135 must install `phoenix_kit 1.7.236` — the migration bridge, the
  last release carrying the full pre-squash chain — migrate until the reported
  version is at least V135, and only then move to 2.0.

  This package does not call migration internals, so the change is the pin
  itself.

### Added

- **Sites tab for the `phoenix_kit_projects` hub (PR #10).** Contributed through
  `phoenix_kit_project_extensions/0`, the duck-typed one-way discovery contract —
  the projects package finds it, and this package takes **no dependency** on
  projects. Linkage is per-project config (comma-separated location UUIDs in the
  Modules & features panel), not a foreign key. Read-only address cards with
  link-outs to the locations admin; a stale UUID or a DB hiccup degrades to a
  missing card rather than crashing the host project page.

## 0.3.0 - 2026-07-13

### Added
- **Space kinds extended** from `floor/room` to `floor/room/zone/section/aisle/shelf` (app-layer list; the core V122 CHECK constraint already allowed them), with localized labels/icons via the module's own gettext backend (en/et/ru).
- **Structure tab** (`LocationStructureLive`) — an N-deep Space tree UI (`SpaceTree`, modeled on core's `FolderExplorer`) replacing the old two-level staged floor/room draft flow. Immediate-commit CRUD (create/rename/reorder/delete) with activity logging; delete opens a confirmation modal reporting the true descendant count (`Spaces.count_descendants/1`, a recursive CTE) since a hard delete CASCADEs the whole subtree. Each Space gets its own Files + Featured Image card via the existing multi-resource Attachments pattern, and its own multilang name/description.
- **`Spaces.full_path/2`** — locale-aware breadcrumb ("Location / Floor / Zone / Shelf") via a cycle-safe recursive CTE.
- **`PlacePicker`** — a LiveComponent combining a Location search-combobox with the Space tree in read-only picker mode, for consumers (e.g. `phoenix_kit_manufacturing`) that need to pick a Location and optionally a Space in one widget. Sends `{:place_picker_select, id, %{location_uuid, space_uuid}}`.
- Auto-positioning of new spaces (`Spaces.create_space/2` appends to the end of its sibling group when no `position` is given).

### Fixed
- `PlacePicker`'s `select_location` handler unconditionally reset the local `selected_space_uuid` to `nil`, which clobbered a consumer-seeded selection the moment the matching Location was picked — defeating the component's own "seed-once" contract (and its test) for the one case it exists to cover. Now the seed is kept when it's present in the newly-loaded tree.
- `lib/phoenix_kit_locations.ex`'s `version/0` had drifted to `"0.1.1"` (stale since before 0.2.0) while `mix.exs` and the version-compliance test only checked consistency with each other, not against it. All three now agree.

## 0.2.1 - 2026-06-08

### Added
- **Env-gated local dependency override.** `phoenix_kit` (and future sibling `phoenix_kit_*` deps) now resolve through a `pk_dep/3` helper in `mix.exs`: export `<APP>_PATH` (e.g. `PHOENIX_KIT_PATH=../phoenix_kit`) to build/test against a local checkout via `path:` + `override: true`; unset or blank falls back to the published Hex pin, so `mix hex.publish` and CI resolve exactly as before. Documented in `AGENTS.md`. A blank/whitespace value is treated as unset (`System.get_env/1` returns `""`, not `nil`), so `PHOENIX_KIT_PATH= mix test` no longer produces a broken `path: ""` dep.

### Changed
- Dependency lockfile refreshed (incl. `phoenix_kit` 1.7.125 → 1.7.133); the `~> 1.7.125` requirement is unchanged and the published runtime/API is identical to 0.2.0.
- Minor docstring cleanup in `PhoenixKitLocations.Locations.log_module_toggle/2`.

## 0.2.0 - 2026-05-29

### Added
- **Spaces** — nested floors and rooms under a Location (`PhoenixKitLocations.Spaces` + `Schemas.Space`, backed by core migration V122 `phoenix_kit_location_spaces`). Edited as staged in-memory drafts that commit on the global Location save; floors are top-level tabs, rooms nest under the active floor. Block-on-invalid validation gate with a kind-aware flash that names the offending draft ("Floor 2 needs a name" / "Room 1 in Floor 2 needs a name"). Floor delete cascades to its rooms; partial-save failures keep the failed drafts on the page. Context guards the same-Location parent invariant and indirect-cycle prevention (depth-bounded walk-up).
- **Attachments** — scope-aware Files cards + featured-image picker per Location and per Space draft (`PhoenixKitLocations.Attachments`), routing drag-and-drop uploads to the right scope.
- Per-draft independent language selector on floor and room editors.
- `PhoenixKitLocations.Errors` atoms for Spaces: `:space_not_found`, `:parent_in_other_location`, `:parent_not_found`, `:cycle`, `:parent_floor_unsaved`.

### Changed
- **Dependency floor raised: `{:phoenix_kit, "~> 1.7.105"}` → `"~> 1.7.125"`.** 1.7.125 is the first core release shipping migration V122; the Spaces feature would have no table on older cores.
- Locations/Types in-page tab nav removed in favor of the PhoenixKit admin dashboard's sibling subtabs; replaced with `<.admin_page_header>`. Name cells in both tables now navigate to the edit page on click.
- Full-width admin layout across all three LiveViews (forms capped at an inner `max-w`); dropped the deprecated `back=` attr from headers.

### Fixed
- Saving a Location with no staged spaces no longer crashes the form — `persist_space_drafts/3` had a dead `[] -> nil` clause shadowing the `{nil, MapSet.new()}` clause, so the empty-drafts path raised a `MatchError` on the (common) spaceless save.
- `Spaces.reorder_siblings/4` no longer silently no-ops for root-level floors — a pinned `parent_uuid == ^nil` compiled to SQL `= NULL` (zero rows); the `nil`-parent case now uses `is_nil/1`.
- `Spaces.update_space/3`'s cycle check now reads `parent_uuid` under both string and atom keys (via a shared `fetch_attr/2`), matching the parent-location check — an atom-keyed `attrs` map no longer bypasses the guard.
- `check_parent_under_location/2` returns the accurate `:parent_not_found` when a parent UUID doesn't exist, instead of conflating it with `:parent_in_other_location`.

### Quality
- `mix precommit` clean: `compile --force --warnings-as-errors`, `deps.unlock --check-unused`, `format --check-formatted`, `credo --strict`, `dialyzer` all pass. Restored `handle_event/3` and `persist_room/5` clause grouping that the Spaces work had split (which `--warnings-as-errors` rejected).
- Pure-helper test suites for `Space` schema, `Attachments` helpers, and the new `Errors` atoms.

## 0.1.3 - 2026-05-25

### Fixed
- `check_address` no longer crashes the location form's LiveView on address-field blur. `phx-blur` delivers `%{"key", "value"}`, not the form's serialized params, so the old `%{"location" => params}` clause never matched and every blur raised `FunctionClauseError` — taking down the LiveView, forcing a reconnect, and wiping every in-progress field. The handler now reads the address from the changeset (kept current by `phx-change="validate"`).

### Quality
- `check_address` tests now drive the real `phx-blur` event via `render_blur` on the input element instead of a hand-crafted `render_hook` payload, plus a regression test asserting the LiveView survives a blur and preserves typed fields.

## 0.1.2 - 2026-04-29

### Added
- `PhoenixKitLocations.Errors` module — central gettext-backed mapping from error atoms to user-facing strings.
- Activity logging across all mutations (location + type create/update/delete, `sync_location_types`, `add_location_type`, `remove_location_type`, module enable/disable). Metadata is PII-audited at the source.
- `LocationTypeAssignment.changeset/2` with `assoc_constraint/2` — FK violations now surface as `{:error, changeset}` instead of `Ecto.ConstraintError`.
- `@spec` typespecs on every public Locations API; `@type t` on each schema.
- Test infrastructure: `Test.Endpoint`, `Test.Router`, `LiveCase`, scope-injection `on_mount` hook, destructive-rescue test file.
- README sections for Error Handling and Activity Logging.

### Changed
- `sync_location_types/3` short-circuits to `{:ok, :unchanged}` when the requested type set matches existing assignments — no DB write, no activity log spam.
- `get_location_by/2` allowlists `:name` / `:email` / `:phone`; arbitrary caller-chosen atoms are rejected.
- All admin LiveView forms now use core `<.input>` / `<.select>` / `<.textarea>` primitives; dropped homegrown error helpers.
- `phx-disable-with` on every submit button to prevent double-submit.
- Replaced inline section-header SVGs with `<.icon name="hero-...">` from core.

### Fixed
- Save-error paths now `Map.put(changeset, :action, :validate)` so validation errors render via core `<.input>` (which gates on `changeset.action != nil`).
- Feature-flag labels are now extractable by `mix gettext.extract` via a literal-call helper.

### Quality
- 188 tests, 0 failures (up from 73).
- 96.89% line coverage via `mix test --cover`.
- `mix precommit` clean (compile + format + credo --strict + dialyzer).

## 0.1.1 - 2026-04-11

### Fixed
- Add routing anti-pattern warning to AGENTS.md

All notable changes to this project will be documented in this file.

## 0.1.0 - 2026-04-02

### Added

- Initial release
- Location management with name, address, city, country, phone, email, notes, status
- Location type management (e.g., Showroom, Storage, Office)
- Admin panel with two subtabs: Locations and Types
- Create/edit forms for both locations and types
- Type picker on location form (toggleable badges for active types)
- Centralized path helpers via `Paths` module
- PhoenixKit.Module behaviour implementation with auto-discovery
