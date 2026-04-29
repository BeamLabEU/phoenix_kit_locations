# Changelog

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
