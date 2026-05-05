# AGENTS.md

This file provides guidance to AI agents working with code in this repository.

## Project Overview

PhoenixKit Locations — an Elixir module for physical location management, built as a pluggable module for the PhoenixKit framework. Manages locations with full international addresses, contact info, translatable fields (name, description, public notes), feature/amenity checkboxes, and user-defined location types with many-to-many assignment.

## Common Commands

### Setup & Dependencies

```bash
mix deps.get                # Install dependencies
```

### Testing

```bash
mix test                        # Run all tests (integration excluded if no DB)
mix test test/file_test.exs     # Run single test file
mix test test/file_test.exs:42  # Run specific test by line
```

### Code Quality

```bash
mix format                  # Format code
mix credo --strict          # Lint / code quality (strict mode)
mix dialyzer                # Static type checking
mix precommit               # compile + format + credo --strict + dialyzer
mix quality                 # format + credo --strict + dialyzer
mix quality.ci              # format --check-formatted + credo --strict + dialyzer
```

## Dependencies

This is a **library**, not a standalone Phoenix app — there is no production `config/` directory, no endpoint, no router. (There *is* a `config/test.exs` — it wires a test-only `PhoenixKitLocations.Test.Repo` + `Test.Endpoint` for `Phoenix.LiveViewTest`; see the Testing section.) The full dependency chain:

- `phoenix_kit` (Hex `~> 1.7`) — provides `Module` behaviour, `Settings`, `RepoHelper`, Dashboard tabs, Multilang, Activity logging, and the core form primitives (`<.input>`, `<.select>`, `<.textarea>`)
- `phoenix_live_view` (`~> 1.1`) — web framework (LiveView UI)
- `lazy_html` (test only) — HTML parser used by `Phoenix.LiveViewTest`

## Architecture

This is a **PhoenixKit module** that implements the `PhoenixKit.Module` behaviour. It depends on the host PhoenixKit app for Repo, Endpoint, and Settings.

### How It Works

1. Parent app adds this as a dependency in `mix.exs`
2. PhoenixKit scans `.beam` files at startup and auto-discovers modules (zero config)
3. `admin_tabs/0` callback registers admin pages; PhoenixKit generates routes at compile time
4. Settings are persisted via `PhoenixKit.Settings` API (DB-backed in parent app)
5. Permissions are declared via `permission_metadata/0` and checked via `Scope.has_module_access?/2`

### Core Schemas (all use UUIDv7 primary keys)

- **LocationType** (`phoenix_kit_location_types`) — user-created categories with name, description (translatable), status (active/inactive)
- **Location** (`phoenix_kit_locations`) — physical places with:
  - Translatable fields: name, description, public_notes (via `data` JSONB column + MultilangForm)
  - Address: address_line_1, address_line_2, city, state, postal_code, country
  - Contact: phone, email, website
  - Features: JSONB map of boolean flags (wheelchair_accessible, elevator, parking, etc.)
  - Internal: notes (admin-only), status (active/inactive)
- **LocationTypeAssignment** (`phoenix_kit_location_type_assignments`) — many-to-many join table (a location can have multiple types, e.g. both "Showroom" and "Storage")

### Web Layer

- **Admin** (3 LiveViews):
  - `LocationsLive` — index page with Locations/Types tab switching
  - `LocationFormLive` — create/edit location with multilang tabs, address fields, feature checkboxes, type toggle badges, duplicate address warning
  - `LocationTypeFormLive` — create/edit type with multilang tabs
- **Routes**: Admin routes auto-generated from `admin_tabs/0` — no route module needed (single-page pattern per tab). Each visible tab and hidden sub-tab (`:admin_locations_new`, `:admin_locations_edit`, `:admin_locations_type_new`, `:admin_locations_type_edit`) sets its own `live_view:`, and PhoenixKit auto-generates the route. Never hand-register these routes in the parent app's `router.ex`; see `phoenix_kit/guides/custom-admin-pages.md` for the authoritative reference
- **Routing pattern**: this module uses the **Single-Page** pattern (`live_view:` on each tab). The alternative **Multi-Page** pattern (a `route_module/0` returning `admin_routes/0` + `admin_locale_routes/0`) is for modules with so many sub-routes that enumerating each as a hidden `Tab` becomes noisy — see `phoenix_kit_ai` / `phoenix_kit_publishing` for that shape. This module is small enough that the tab-based approach is clearer
- **Paths**: Centralized path helpers in `Paths` module — always use these instead of hardcoding URLs

### Activity Logging Pattern

Every mutating function in the `PhoenixKitLocations.Locations` context logs a business-level activity via `PhoenixKit.Activity.log/1`, guarded so logging never crashes the primary operation.

Two helpers live in the context module:

1. **`log_activity/5`** is a pipe-step used on simple CRUD — it pattern-matches on the repo result, logs on `{:ok, struct}`, and passes `{:error, changeset}` through untouched:

   ```elixir
   def create_location(attrs, opts \\ []) do
     %Location{}
     |> Location.changeset(attrs)
     |> repo().insert()
     |> log_activity("location.created", "location", opts, &location_metadata/1)
   end
   ```

2. **`maybe_log_activity/5`** is called directly for operations that don't produce a single repo result to pipe from — e.g. `sync_location_types`, `add_location_type`, `remove_location_type`, and the module enable/disable toggle (`log_module_toggle/2`).

Both ultimately call `PhoenixKit.Activity.log/1` inside a `Code.ensure_loaded?(PhoenixKit.Activity)` guard, with a rescue that swallows `Postgrex.Error %{postgres: %{code: :undefined_table}}` (for hosts without core's activity migration) and logs a `Logger.warning` for anything else.

Key rules:

- **Mutating context fns accept `opts \\ []`** — LiveViews forward the caller's UUID via an `actor_opts/1` helper reading `socket.assigns[:phoenix_kit_current_scope].user.uuid`.
- **Metadata is minimal and PII-aware** — `name`, `city`, `status` for locations; `name`, `status` for types. Never log `email`, `phone`, or `notes`.
- **Actions logged**: create/update/delete on `Location` and `LocationType`, `sync_location_types` (with `types_from`/`types_to` diffs, skipped when unchanged), `add_location_type`, `remove_location_type`, module `enable_system` / `disable_system`.
- **Action format**: `"resource.verb"` — e.g. `"location.created"`, `"location_type.deleted"`, `"locations_module.enabled"`.

### Multilang (Translatable Fields)

Location and LocationType forms use PhoenixKit's `MultilangForm` component system:
- Translatable fields are stored in the `data` JSONB column
- Primary language values are denormalized to DB columns (name, description, public_notes) for querying
- Secondary language overrides stored nested in `data` by language code
- Form handling: `mount_multilang/1`, `handle_switch_language/2`, `merge_translatable_params/4`
- Template components: `multilang_tabs`, `multilang_fields_wrapper`, `translatable_field`

### Location Form Layout

The form is split into two cards:
1. **Public Information** (top card) — translatable fields, address, contact, features & amenities
2. **Internal** (bottom card) — admin-only notes, status, location type assignment

### Settings Keys

`locations_enabled`

### File Layout

```
lib/phoenix_kit_locations.ex                    # Main module (PhoenixKit.Module behaviour)
lib/phoenix_kit_locations/
├── locations.ex                               # Context module (CRUD, type sync, address detection, activity logging)
├── errors.ex                                  # Atom → gettext message dispatcher for UI boundary
├── paths.ex                                   # Centralized URL path helpers
├── schemas/
│   ├── location.ex                            # Location schema + changeset
│   ├── location_type.ex                       # LocationType schema + changeset
│   └── location_type_assignment.ex            # Many-to-many join table schema
└── web/
    ├── locations_live.ex                      # Index page (locations/types tabs)
    ├── location_form_live.ex                  # Create/edit location (multilang, features, types)
    └── location_type_form_live.ex             # Create/edit location type (multilang)
```

## Critical Conventions

- **Module key**: `"locations"` — MUST be consistent across all callbacks (`module_key/0`, `admin_tabs/0`, settings keys, tab IDs)
- **Tab ID prefix**: all admin tabs MUST use `:admin_locations_` prefix (e.g., `:admin_locations_list`, `:admin_locations_types`)
- **UUIDv7 primary keys** — all schemas MUST use `@primary_key {:uuid, UUIDv7, autogenerate: true}`
- **Centralized paths via `Paths` module** — NEVER hardcode URLs or route paths in LiveViews; always use `Paths` helpers
- **URL paths use hyphens** — route segments use hyphens (e.g., `/admin/locations`), never underscores
- **Admin routes from `admin_tabs/0`** — all admin navigation is auto-generated by PhoenixKit Dashboard from the tabs; do not manually add admin routes elsewhere
- **Navigation paths** — always use `PhoenixKit.Utils.Routes.path/1` for navigation within the PhoenixKit ecosystem
- **LiveViews use `Phoenix.LiveView` directly** — do not use `PhoenixKitWeb` macros (`use PhoenixKitWeb, :live_view`) in this standalone package; import helpers explicitly
- **`enabled?/0` MUST rescue** — the function must rescue all errors and return `false` as fallback (DB may not be available at boot)
- **Single context module** — all business logic lives in `PhoenixKitLocations.Locations`; schemas are data-only with changesets
- **Hard-delete only** — locations and types use hard-delete (simple reference data, no soft-delete cascade needed)
- **Multilang fields** — name and description fields use PhoenixKit's `Multilang` module for i18n support; public_notes on Location is also translatable
- **Features stored as JSONB** — the `features` field is a map of `%{"key" => boolean}` pairs, toggled via `toggle_feature` events in the LiveView
- **Many-to-many types** — location ↔ type relationship uses a join table. `sync_location_types(location_uuid, type_uuids, opts \\ [])` does a delete-all + re-insert in a transaction and returns `{:ok, :synced}`. When the requested set matches the existing set it short-circuits to `{:ok, :unchanged}` and skips both the DB write and the activity log entry (no noise on unchanged saves)
- **JavaScript hooks**: inline `<script>` tags if needed; register on `window.PhoenixKitHooks`
- **LiveView assigns** available in admin pages: `@phoenix_kit_current_scope`, `@current_locale`, `@url_path`
- **Errors dispatcher** — non-changeset errors returned by the Locations context are atoms (`:location_not_found`, `:type_assignment_failed`, `:unexpected`, …). LiveViews call `PhoenixKitLocations.Errors.message/1` at the UI boundary to get a `gettext`-translated string. Do not inline user-facing error strings in LiveViews; extend `Errors.message/1` instead
- **Core form primitives** — use `<.input field={@form[:x]}>`, `<.select field={@form[:x]} options={...}>`, `<.textarea field={@form[:x]}>` from `PhoenixKitWeb.Components.Core.{Input, Select, Textarea}` rather than raw HTML. These handle label wiring, error rendering via `phx-feedback-for`, and daisyUI styling. The form LV must assign both `:changeset` (for `<.translatable_field>`) and `:form = to_form(changeset, as: :location)` — keep them in sync via an `assign_form/2` private helper

### Commit Message Rules

Start with action verbs: `Add`, `Update`, `Fix`, `Remove`, `Merge`. Do not include AI attribution or `Co-Authored-By` footers — Max handles attribution on his own.

## Pre-commit Commands

Always run before `git commit`:

```bash
mix precommit               # compile + format + credo --strict + dialyzer
```

CI runs the same chain via `mix quality.ci` (format-check mode). If `precommit` fails, fix the underlying issue — do not bypass with `--no-verify`.

## Database & Migrations

This repo ships **no production migrations** — all runtime database tables are created by the parent [phoenix_kit](https://github.com/BeamLabEU/phoenix_kit) project (V90). This module only defines Ecto schemas that map to those tables.

The test suite builds its schema by running core's versioned migrations directly via `PhoenixKit.Migration.ensure_current/2` in `test/test_helper.exs` — no module-owned DDL.

### Tables (created by PhoenixKit V90)

- `phoenix_kit_location_types` — name, description, status, data (JSONB for multilang), timestamps
- `phoenix_kit_locations` — name, description, public_notes, address_line_1, address_line_2, city, state, postal_code, country, phone, email, website, notes, status, features (JSONB), data (JSONB for multilang), timestamps
- `phoenix_kit_location_type_assignments` — location_uuid (FK CASCADE), location_type_uuid (FK CASCADE), timestamps; unique index on (location_uuid, location_type_uuid)

## Tailwind CSS Scanning

This module implements `css_sources/0` returning `[:phoenix_kit_locations]` (atom list — the core scanner resolves it to the OTP app's `lib/` and `priv/` paths). CSS source discovery is **automatic at compile time** — the `:phoenix_kit_css_sources` compiler scans all discovered modules, resolves their paths, and writes `assets/css/_phoenix_kit_sources.css`. The parent app's `app.css` imports this generated file.

## Testing

### Setup

This module owns its own test database (`phoenix_kit_locations_test`). Schema setup runs core's versioned migrations directly via `PhoenixKit.Migration.ensure_current/2` in `test/test_helper.exs` — no module-owned DDL anywhere. Create the DB once:

```bash
createdb phoenix_kit_locations_test
```

If the DB is absent, integration tests auto-exclude via the `:integration` tag (see `test/test_helper.exs`) — unit tests still run.

The critical config wiring is in `config/test.exs`:

```elixir
config :phoenix_kit, repo: PhoenixKitLocations.Test.Repo
```

Without this, all DB calls through `PhoenixKit.RepoHelper` crash with "No repository configured".

### Test infrastructure

- `test/support/test_repo.ex` — `PhoenixKitLocations.Test.Repo` (Ecto repo for tests)
- `test/support/data_case.ex` — `PhoenixKitLocations.DataCase` (sandbox setup, auto-tags `:integration`)
- `test/support/live_case.ex` — `PhoenixKitLocations.LiveCase` (thin wrapper around `Phoenix.LiveViewTest` with router + endpoint wiring)
- `test/support/test_endpoint.ex` + `test_router.ex` + `test_layouts.ex` — minimal Phoenix plumbing so LiveViews can render under `Phoenix.LiveViewTest.live/2`
- `test/test_helper.exs` calls `PhoenixKit.Migration.ensure_current/2` to apply all core versioned migrations (V40 extensions + `uuid_generate_v7()`, V03 settings, V90 locations + activities) on every boot — no module-owned DDL

### Running tests

```bash
mix test                             # All tests (excludes :integration if no DB)
mix test test/locations_test.exs     # Context tests only
mix test test/phoenix_kit_locations/web  # LiveView smoke tests only
for i in $(seq 1 10); do mix test; done   # stability check — catches sandbox/activity-log flakes
```

## Versioning & Releases

This project follows [Semantic Versioning](https://semver.org/).

### Version locations

The version must be updated in **three places** when bumping:

1. `mix.exs` — `@version` module attribute
2. `lib/phoenix_kit_locations.ex` — `def version, do: "x.y.z"`
3. `test/phoenix_kit_locations_test.exs` — version compliance test

### Tagging & GitHub releases

Tags use **bare version numbers** (no `v` prefix):

```bash
git tag 0.1.0
git push origin 0.1.0
```

GitHub releases are created with `gh release create`:

```bash
gh release create 0.1.0 \
  --title "0.1.0 - 2026-04-03" \
  --notes "$(changelog body for this version)"
```

### Full release checklist

1. Update version in `mix.exs`, `lib/phoenix_kit_locations.ex`, and the version test
2. Add changelog entry in `CHANGELOG.md`
3. Run `mix precommit` — ensure zero warnings/errors before proceeding
4. Commit all changes: `"Bump version to x.y.z"`
5. Push to main and **verify the push succeeded** before tagging
6. Create and push git tag: `git tag x.y.z && git push origin x.y.z`
7. Create GitHub release: `gh release create x.y.z --title "x.y.z - YYYY-MM-DD" --notes "..."`

**IMPORTANT:** Never tag or create a release before all changes are committed and pushed. Tags are immutable pointers — tagging before pushing means the release points to the wrong commit.

## Pull Requests

### PR Reviews

PR review files go in `dev_docs/pull_requests/{year}/{pr_number}-{slug}/` directory. Use `{AGENT}_REVIEW.md` naming (e.g., `CLAUDE_REVIEW.md`, `GEMINI_REVIEW.md`).

Severity levels for review findings:

- `BUG - CRITICAL` — Will cause crashes, data loss, or security issues
- `BUG - HIGH` — Incorrect behavior that affects users
- `BUG - MEDIUM` — Edge cases, minor incorrect behavior
- `IMPROVEMENT - HIGH` — Significant code quality or performance issue
- `IMPROVEMENT - MEDIUM` — Better patterns or maintainability
- `NITPICK` — Style, naming, minor suggestions

## External Dependencies

- **PhoenixKit** (`~> 1.7`) — Module behaviour, Settings API, RepoHelper, Dashboard tabs, Multilang, MultilangForm components, Activity logging
- **Phoenix LiveView** (`~> 1.1`) — Admin LiveViews
- **ex_doc** (`~> 0.39`, dev only) — Documentation generation
- **credo** (`~> 1.7`, dev/test) — Static analysis / code quality
- **dialyxir** (`~> 1.4`, dev/test) — Static type checking
- **lazy_html** (`~> 0.1`, test only) — HTML parser used by `Phoenix.LiveViewTest` for smoke tests

## Two Module Types

PhoenixKit modules come in two shapes:

- **Full-featured**: admin tabs, routes, UI, settings — this module
- **Headless**: functions/API only, no UI — still gets auto-discovery, toggles, and permissions

Both shapes implement `PhoenixKit.Module`. The difference is whether `admin_tabs/0` returns entries with `live_view:` bindings.

## What This Module Does NOT Have

Deliberate non-features — pinning these in writing prevents future scope creep and makes review-finding triage faster.

- **No PubSub broadcasts or real-time sync.** Locations are admin-only reference data; no public-facing LiveViews subscribe to changes. If two admins edit the same record, last-write-wins. Adding broadcasts would mean a new `pubsub_topic/0`, mount-time subscribe, and a payload-minimal contract — defer until there's a real consumer.
- **No soft-delete / restore.** Hard-delete only. Cascading FK deletes remove `phoenix_kit_location_type_assignments` rows when a location or type is deleted; the locations themselves don't survive a restore flow.
- **No background jobs / Oban workers.** No cron'd reconciliation, no async geocoding, no batch import worker. CSV/XLSX import is intentionally out of scope (each location is hand-curated).
- **No external HTTP calls.** No geocoding API, no map tile fetch, no reverse-DNS, no SSRF surface to harden.
- **No public API routes.** All routes are gated behind `live_session :phoenix_kit_admin` and the `locations` permission. The context module is the only public API surface; no JSON endpoint, no REST, no GraphQL.
- **No file uploads or attachments.** Locations don't carry photos, documents, or `featured_image`. The `Attachments` module from core is not wired up.
- **No multi-step / wizard form.** A single `LocationFormLive` page with a two-card layout (public info + internal). No tabs beyond multilang.
- **No address validation against a registry.** The `find_similar_addresses/4` helper detects exact-match duplicates within the local DB but does not validate against postal authorities or geocode.
