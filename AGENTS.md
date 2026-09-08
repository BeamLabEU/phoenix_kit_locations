# AGENTS.md

Guidance for AI agents working on `phoenix_kit_locations`.

## Overview

Physical-location management for PhoenixKit: locations with international
addresses, contact info, translatable name/description/public notes, JSONB
feature flags, user-defined location types assigned many-to-many, a per-location
tree of nested spaces (floors, rooms, zones, sections, aisles, shelves), and
folder-scoped file attachments with a featured image on both locations and
spaces. It is a library, not an app: no production `config/`, endpoint or
router; the host provides Repo, Endpoint and Settings.

- **Depends on:** `phoenix_kit` `~> 2.0` (Hex), `phoenix_live_view ~> 1.1`. No sibling `phoenix_kit_*` deps.
- **Consumed by:** `phoenix_kit_projects` discovers `phoenix_kit_project_extensions/0` (the Sites tab) through its extension registry; duck-typed, no dependency in either direction. `PlacePicker` is built for warehouse/manufacturing-style consumers; none is wired yet.
- **Admin surface:** tab `:admin_locations` at `/admin/locations` (`group: :admin_modules`, priority 670, redirects to its first subtab). Visible subtabs: Locations (`/admin/locations`), Types (`/admin/locations/types`). Hidden subtabs: `/admin/locations/new`, `/admin/locations/:uuid/edit`, `/admin/locations/:uuid/structure`, `/admin/locations/types/new`, `/admin/locations/types/:uuid/edit`. Plus a Sites tab rendered inside a project page by the projects hub.
- **Module key** `"locations"`; settings prefix `locations_`.

## What this module does NOT do

- **No PubSub broadcasts or real-time sync.** Locations are admin-only reference data; no public LiveView subscribes. Two admins editing one record is last-write-wins. Adding broadcasts means a new `pubsub_topic/0`, a mount-time subscribe and a payload-minimal contract; defer until there is a consumer.
- **No soft-delete / restore.** Hard delete only. FK cascades remove type assignments and the whole space subtree; nothing survives into a restore flow.
- **No background jobs / Oban workers.** No reconciliation, async geocoding or import worker. CSV/XLSX import is out of scope (each location is hand-curated).
- **No external HTTP calls.** No geocoding API, map tiles or reverse DNS; no SSRF surface to harden.
- **No public API routes.** Every route sits in `live_session :phoenix_kit_admin` behind the `locations` permission. The context modules are the only public API; no JSON, REST or GraphQL.
- **No address validation against a registry.** `find_similar_addresses/4` detects exact-match duplicates in the local DB only.
- **No migrations of its own.** All four tables ship in core's chain.
- **No dependency on `phoenix_kit_projects`.** The Sites extension is a one-way discovery contract; linkage is per-project config (comma-separated location uuids), not a FK.
- **No `route_module/0`.** Every page is a `live_view:` on a tab.
- **`PlacePicker` does not resolve type names.** Callers resolve `location_type_uuid` via `Locations.get_location_type_by_name/1` first, keeping the component's API small.

## Commands

```bash
mix deps.get
createdb phoenix_kit_locations_test          # once; DB-backed tests are tagged :integration and auto-skip without it
mix test
mix precommit                # compile --warnings-as-errors + format + credo --strict + dialyzer; run before every commit
```

`phoenix_kit*` deps resolve from Hex. To run against a local checkout, export
`<APP>_PATH` (the dep's app name upper-cased plus `_PATH`); `pk_dep/3` in
`mix.exs` swaps the Hex pin for a `path:` dep at resolve time. Unset means the
Hex pin, so `mix hex.publish` is unaffected. Run `mix deps.get` with the var
exported before the first `mix test` (a stale lock aborts on the optional
`igniter` dep), and never commit a hand-edited `path:` tuple.

```bash
PHOENIX_KIT_PATH=../phoenix_kit mix deps.get && PHOENIX_KIT_PATH=../phoenix_kit mix test
```

Also: `mix test.setup` (creates the test DB), `mix test.reset` (drop + create;
clears the `schema_migrations` rows `ensure_current/2` accumulates), `mix quality`
(format + credo --strict + dialyzer), `mix quality.ci` (format check instead of
format). `precommit` also runs `deps.unlock --check-unused` and `mix hex.audit`.

## Conventions

- **Module key** `"locations"` everywhere: `module_key/0`, tab `permission:`, settings keys, activity `module:`. Tab ids carry the `:admin_locations_` prefix. URL segments use hyphens, never underscores.
- **Paths** come from `PhoenixKitLocations.Paths` (`index/0`, `location_new/0`, `location_edit/1`, `location_structure/1`, `types/0`, `type_new/0`, `type_edit/1`), each through `PhoenixKit.Utils.Routes.path/1` for prefix + locale. Never hardcode a URL in a LiveView or component.
- **Routing:** every page, visible or hidden, is a `live_view:` on a `Tab` in `admin_tabs/0`; `route_module/0` is nil. Static paths (`locations/new`, `locations/types/new`, `locations/types/:uuid/edit`) are listed before the `:uuid` wildcards (`locations/:uuid/edit`, `locations/:uuid/structure`). `:admin_locations_list` matches with a regex (`(?:^|/)locations(?:/new|/[^/]+/edit)?$`) so `/new` and `/:uuid/edit` highlight it without swallowing the `types` subtree (`:prefix` swallows, `:exact` misses). Never hand-register these routes in a host router; core's `guides/custom-admin-pages.md` is the reference. A host that wants the data without the UI sets `config :phoenix_kit, hidden_admin_tabs: [:admin_locations]`.
- **LiveView macro:** `use Phoenix.LiveView` with explicit imports (`PhoenixKitWeb.Components.Core.{AdminPageHeader, Icon, Input, Select, Textarea, Modal, TableDefault, TableRowMenu, NavTabs}`, `PhoenixKitWeb.Components.MultilangForm`, `LanguageSwitcher`), never `use PhoenixKitWeb, :live_view`. Components are `use Phoenix.Component` / `use Phoenix.LiveComponent`. No template wraps in `LayoutWrapper`; the admin live_session supplies the layout. Assigns available in admin pages: `@phoenix_kit_current_scope`, `@phoenix_kit_current_user`, `@current_locale`, `@url_path`.
- **Gettext is a hybrid.** The module's own `PhoenixKitLocations.Gettext` (`priv/gettext`, en/et/ru) serves the admin tabs (`gettext_backend: PhoenixKitLocations.Gettext`, `gettext_domain: "default"` on every `Tab`), `Space.kind_label/1`, `LocationStructureLive`, `LocationTabs`, `SpaceTree` and `PlacePicker`. Core's `PhoenixKitWeb.Gettext` serves `LocationsLive`, `LocationFormLive`, `LocationTypeFormLive`, `Errors`, `FilesCard` and `Attachments`. New strings go on the module backend. Extract with `mix gettext.extract --merge`. The tab-label msgids (`Locations`, `Types`, `New Location`, `Edit Location`, `New Type`, `Edit Type`, `Structure`) are looked up at runtime by core's `Tab.localized_label/1`, so the extractor never sees them: they are hand-written in the pot/po **without** the `elixir-autogen` flag, which is what stops `--merge` from pruning them.
- **JS hooks:** no `js_sources/0` bundle. The one hook, `.PkLocationsUploadScope` in `FilesCard`, is a `Phoenix.LiveView.ColocatedHook` (compiled into the host's colocated manifest, spread into the LiveSocket as `colocatedHooks`). Never register a hook from a plain inline `<script>`: morphdom does not execute inserted script tags, so it vanishes on LiveView navigation.
- **`enabled?/0`** reads `locations_enabled` via `Settings.get_boolean_setting/2`, rescues every error **and catches `:exit`**, returning `false` (the DB may be down at boot; sandbox-owner exits on test teardown otherwise surface as a 1-in-N flake). `enable_system/0` / `disable_system/0` write the setting through `update_boolean_setting_with_module/3` and log the toggle.
- **Activity logging:** every mutating function in `Locations` and `Spaces` accepts `opts \\ []`; LiveViews thread the caller through `actor_opts/1`, which reads `socket.assigns[:phoenix_kit_current_scope].user.uuid` into `actor_uuid:`. Two helpers per context: `log_activity/5` is a pipe step on a repo result (`{:ok, struct}` logs metadata; `{:error, %Ecto.Changeset{}}` logs a `db_pending: true` row with the invalid field names only; `{:error, atom}` passes through unlogged), and `maybe_log_activity/5` is called directly by operations with no single repo result. Both call `PhoenixKit.Activity.log/1` inside `Code.ensure_loaded?(PhoenixKit.Activity)`, swallow `Postgrex.Error` `:undefined_table` (host without the activities table) and `Logger.warning` anything else; logging never crashes the primary operation. Metadata is minimal and PII-aware: `name`, `city`, `status` for locations; `name`, `status` for types; `name`, `kind`, `status`, `location_uuid`, `parent_uuid` for spaces. Never log `email`, `phone` or `notes`. Action format is `resource.verb` (table in Architecture).
- **Hard delete only**, no soft-delete sentinel.
- **Single context per aggregate:** `Locations` (locations, types, assignments, duplicate detection) and `Spaces` (the tree). Schemas are data-only with changesets. Both read the repo through `PhoenixKit.RepoHelper.repo()`.
- **Errors dispatcher:** non-changeset errors are atoms (`:location_not_found`, `:location_type_not_found`, `:location_delete_failed`, `:location_type_delete_failed`, `:type_assignment_failed`, `:space_not_found`, `:parent_in_other_location`, `:parent_not_found`, `:cycle`, `:parent_floor_unsaved`, `:unexpected`). LiveViews call `PhoenixKitLocations.Errors.message/1` at the UI boundary; strings pass through, anything else renders as `Unexpected error: <inspect>`. Extend `Errors.message/1` instead of inlining user-facing error strings.
- **Multilang:** translatable fields are `name`, `description`, `public_notes` on Location, `name`, `description` on LocationType and Space. Primary-language values live in the columns; other languages nest in `data` under the language code with `_`-prefixed keys (`"_name"`). Forms use core's `MultilangForm` (`mount_multilang/1`, `handle_switch_language/2`, `merge_translatable_params/4` with `preserve_fields`, `get_lang_data/3`; components `multilang_tabs`, `multilang_fields_wrapper`, `translatable_field`). A form LiveView assigns both `:changeset` (read by `<.translatable_field>`) and `:form = to_form(changeset, as: :location)` (read by core `<.input>` / `<.select>` / `<.textarea>`) and keeps them in sync through one `assign_form/2` helper (`assign_space_form/2` on the Structure tab).
- **Core form primitives** (`<.input field={@form[:x]}>`, `<.select>`, `<.textarea>`) rather than raw HTML; they wire labels, errors and daisyUI styling.
- **Location form:** one `<.form id="location-form">` with `phx-change="validate"` / `phx-submit="save"`, laid out as three cards: Public Information (translatable fields, address, contact, features), Files & Featured Image, Internal (admin notes, status, type badges). `features` is a `%{"key" => boolean}` map toggled by `toggle_feature` (keys in `@feature_keys`, labels via `feature_label/1` so the literals are extractable); types toggle via `toggle_type` into a `MapSet` and are synced after save. `check_address` runs on `phx-blur` of the address fields and reads the changeset, not the event payload. The Details/Structure tab strip renders only in `:edit` (a new location has no uuid). Save is disabled while uploads are in flight.
- **Type sync:** `sync_location_types(location_uuid, type_uuids, opts)` is delete-all + re-insert in a transaction returning `{:ok, :synced}`; when the requested set equals the current set it short-circuits to `{:ok, :unchanged}` with no write and no log entry. `add_location_type/3` is a no-op when already assigned; `remove_location_type/3` returns `{:ok, 0 | 1}`.
- **Duplicate detection:** `find_similar_addresses/4` matches on lower-cased, trimmed `address_line_1` + `city` + `postal_code`, limit 5, excludes the record being edited, and rescues to `[]` so the form still saves.
- **Spaces:** `kind` is app-narrowed to `floor room zone section aisle shelf` (the DB CHECK also allows `hall suite corner`). The same-Location parent rule and indirect-cycle guard live in the `Spaces` context, not the schema or the DB; the schema catches only a direct self-parent. `create_space/2` appends to the sibling group when no `position` is given. The Structure tab commits immediately (no drafts); deletes cascade the subtree and fire only from the confirmation modal that shows `count_descendants/1`. Details in `dev_docs/guides/spaces.md`.
- **Attachments:** per-scope state in `socket.assigns.attachments_by_scope`, keyed by an opaque scope string (`"location"` on the form; the Space uuid on the Structure tab); modal state is shared at socket level and tracks `:media_selector_scope`. One upload config, `:attachment_files` (any type, 20 entries, 100 MB, auto-upload); every event carries `phx-value-scope`; the dropzone sets the active scope on click and on `dragenter` (the colocated hook). Pointers `files_folder_uuid` / `featured_image_uuid` live in the resource's `data` JSONB and are merged into params at save by `inject_attachment_data/3`. Folders are named `location-<uuid>` / `location-space-<uuid>` (`folder_name_for/1`); a `:new` resource uploads into `location-attachment-pending-<uuid>` and `maybe_rename_pending_folder_for/2` renames it after the insert. The featured-image picker is core's `MediaSelectorModal` (`:image` filter, `:single` mode) replying `{:media_selected, uuids}` / `{:media_selector_closed}`. Uploads need `@phoenix_kit_current_user` (folder and file are owned by that user; without one the upload fails with `:no_user`). Removing a file soft-trashes a single-owner home file and only unlinks a multi-resource one.
- **Sites extension** (`phoenix_kit_project_extensions/0`): a plain map (`key: "locations_sites"`, `module_key: "locations"`, `default_enabled: false`, one tab `sites` → `ProjectSitesLive`, `config_schema` with `location_uuids`, `permission_actions: [:view]`). `ProjectSitesLive` is rendered by the hub via `live_render` with its embed-session contract, reads `session["config"]["location_uuids"]`, has **no `handle_params/3`** (off-router mount is the hub's hard requirement), and degrades a stale uuid or DB error to a missing card rather than crashing the host page.
- **`css_sources/0`** returns `[:phoenix_kit_locations]` (atoms; the core compiler resolves them to `lib/` + `priv/`).

### Landmines

- `Spaces.update_space/3` does `Map.put_new(attrs, "location_uuid", …)`: atom-keyed attrs become a mixed-key map and `cast/3` raises `Ecto.CastError`. Pass string-keyed attrs, as `LocationStructureLive` and the tests do.
- Root-sibling queries (`reorder_siblings/4`, `next_position/2`) must match `is_nil(parent_uuid)`; a pinned `^nil` compiles to `= NULL`, never matches, and floor reordering silently updates zero rows.
- `phx-blur` payloads carry only `key`/`value`, never form params. `check_address` reads `socket.assigns.changeset`; a clause matching `%{"location" => params}` crashes the LiveView on every blur and the reconnect wipes the form.
- Strings on core's `PhoenixKitWeb.Gettext` backend (the three list/form LiveViews, `Errors`, `FilesCard`, `Attachments`) are not in core's catalogue, so they render as the English msgid in every locale; `Attachments` also uses the runtime `Gettext.gettext(Backend, …)` form the extractor cannot see. Moving a string to the module backend is the fix, not editing core's po.
- Never add `elixir-autogen` to the hand-written tab-label msgids in `priv/gettext`: `mix gettext.extract --merge` then finds no call site, drops them, and the sidebar falls back to English with no warning.

## Architecture

```
lib/phoenix_kit_locations.ex                 # PhoenixKit.Module: tabs, permission, css_sources, project extension
lib/phoenix_kit_locations/
├── locations.ex                             # Locations context: types, locations, assignments, duplicates, logging
├── spaces.ex                                # Spaces context: tree reads, CRUD, reorder, parent/cycle guards, logging
├── attachments.ex                           # Multi-scope files + featured image (Location and each Space)
├── errors.ex                                # Error atom -> translated message
├── gettext.ex                               # PhoenixKitLocations.Gettext backend
├── paths.ex                                 # URL helpers
├── schemas/
│   ├── location.ex                          # phoenix_kit_locations
│   ├── location_type.ex                     # phoenix_kit_location_types
│   ├── location_type_assignment.ex          # phoenix_kit_location_type_assignments
│   └── space.ex                             # phoenix_kit_location_spaces (+ kinds, kind_label/1, kind_icon/1)
└── web/
    ├── locations_live.ex                    # :index (locations) and :types lists, delete confirm modals
    ├── location_form_live.ex                # :new / :edit location (Details tab)
    ├── location_structure_live.ex           # :edit Structure tab (space tree CRUD + detail panel)
    ├── location_type_form_live.ex           # :new / :edit location type
    ├── project_sites_live.ex                # Sites tab inside the projects hub
    └── components/
        ├── files_card.ex                    # files_card_body/1 + colocated .PkLocationsUploadScope hook
        ├── location_tabs.ex                 # Details / Structure strip via core <.nav_tabs variant={:border}>
        ├── place_picker.ex                  # LiveComponent: location combobox + space tree picker
        └── space_tree.ex                    # space_tree/1, pure presentation, picker mode
```

### Data model (UUIDv7 PKs, `use PhoenixKit.SchemaPrefix`, `timestamps(type: :utc_datetime)`)

| Schema | Table | Notes |
|---|---|---|
| `LocationType` | `phoenix_kit_location_types` | `name`, `description`, `status` (`active`/`inactive`), `data` JSONB |
| `Location` | `phoenix_kit_locations` | `name`, `description`, `public_notes`, `address_line_1/2`, `city`, `state`, `postal_code`, `country`, `phone`, `email`, `website`, `notes`, `status`, `features` JSONB, `data` JSONB; `has_many :location_types, through:` the join |
| `LocationTypeAssignment` | `phoenix_kit_location_type_assignments` | `location_uuid`, `location_type_uuid` (both FK CASCADE, `assoc_constraint` so FK failures come back as changesets); unique on the pair |
| `Space` | `phoenix_kit_location_spaces` | `location_uuid` (required, FK CASCADE), `parent_uuid` (self FK CASCADE), `kind` (CHECK), `name`, `description`, `notes`, `status`, `position`, `data` JSONB; indexes on `(location_uuid)`, `(parent_uuid)`, `(location_uuid, parent_uuid, position)` |

Changeset rules: `name` required (1–255); `email` must contain `@`; `website` must start with `http://` or `https://`; `status` in `active`/`inactive`; length caps on every text column.

### Activity log actions (`module: "locations"`, `mode` defaults to `"manual"`)

| Action | Resource | When |
|---|---|---|
| `location.created` / `updated` / `deleted` | `location` | Location CRUD |
| `location.types_synced` | `location` | `sync_location_types/3`, only when the set changed (`types_from` / `types_to`) |
| `location.type_added` / `type_removed` | `location` | single assignment add/remove (`type_uuid`) |
| `location_type.created` / `updated` / `deleted` | `location_type` | LocationType CRUD |
| `space.created` / `updated` / `deleted` | `location_space` | Space CRUD (children of a cascade are not logged) |
| `space.reordered` | `location_space` (resource = parent uuid) | `reorder_siblings/4` (`location_uuid`, `count`) |
| `locations_module.enabled` / `disabled` | `module` | `enable_system/0` / `disable_system/0` |

- **Settings keys:** `locations_enabled`.
- **Permissions:** `locations` (`permission_metadata/0`; every tab carries `permission: module_key()`). No sub-permissions. The Sites extension declares `permission_actions: [:view]` for the hub.
- **PubSub topics:** none.

## Database & migrations

None. Tables `phoenix_kit_location_types`, `phoenix_kit_locations`,
`phoenix_kit_location_type_assignments`, `phoenix_kit_location_spaces` ship in
core's chain (V135 baseline); `migration_module/0` is unset. A schema change is
a core migration first, then schema edits here. The `kind` CHECK constraint
(`phoenix_kit_location_spaces_kind_check`) allows `floor room hall suite section
zone aisle shelf corner`; the app list is narrower. UUIDv7 PKs and
`use PhoenixKit.SchemaPrefix` on every table-backed schema (a conformance test
enforces the latter).

## Testing

- **DB:** `phoenix_kit_locations_test` (+ `MIX_TEST_PARTITION` suffix), overridable with `PGDATABASE`. `config/test.exs` honours `PGUSER` (default `postgres`), `PGPASSWORD`, `PGHOST`, `PGPOOL` (pool size; default `schedulers_online * 2`). It also sets `config :phoenix_kit, repo: PhoenixKitLocations.Test.Repo`; without it every `RepoHelper` call fails with "No repository configured".
- **`test/test_helper.exs`:** `Code.require_file`s the support modules first (Elixir 1.19 no longer auto-loads `test/support` at helper time), checks `psql -lqt` for the DB, then starts the repo, runs `PhoenixKit.Migration.ensure_current/2` (core's chain, no module DDL), sets the sandbox to `:manual`, pins `:persistent_term.put({PhoenixKit.Config, :url_prefix}, "/")`, and starts `Test.Endpoint` (`server: false`) only when the DB is available. Without a DB, `ExUnit.start(exclude: [:integration])`.
- **Runs without Postgres:** the behaviour test, `errors_test`, `attachments_test`, `space_tree_test`, `core_pin_conformance_test`, `schema_prefix_conformance_test`.
- **Support modules:** `Test.Repo`; `DataCase` (sandbox owner, tags `:integration`, imports `ActivityLogAssertions`, `errors_on/1`); `LiveCase` (same plus `Phoenix.LiveViewTest`, `fake_scope/1` returning a real `PhoenixKit.Users.Auth.Scope` with `cached_roles` as role-name strings, `put_test_scope/2`, `fixture_location/1`, `fixture_location_type/1`); `Test.Endpoint` + `Test.Router` (base `/en/admin/locations`, mirroring `Paths`) + `Test.Layouts`; `Test.Hooks` (`:assign_scope` on_mount reads `"phoenix_kit_test_scope"` from the session into `:phoenix_kit_current_scope` / `:phoenix_kit_current_user`); `ActivityLogAssertions.assert_activity_logged/2` (`resource_uuid:`, `actor_uuid:`, `metadata_has:`); `PlacePickerHarnessLive` at `/en/admin/locations/__test__/place-picker` (test-only host for the LiveComponent).
- **Conformance tests:** the `:phoenix_kit` requirement must stay a two-segment `~> 2.0` (a three-segment `~> 2.0.x` excludes every later core minor and breaks hosts' `deps.get`; a committed `path:` dep also fails it); every table-backed schema uses `SchemaPrefix`.
- **`destructive_rescue_test.exs`** DROPs tables inside the sandbox transaction to reach the `Postgrex.Error` rescue branches; it must stay `async: false` or it deadlocks against async tests holding row locks.
- **Creating the DB:** `mix test.setup` / `mix test.reset` only work under `MIX_ENV=test` (`Test.Repo` lives in `test/support`, compiled in test only). The database needs a UTF-8 ctype: under a `C`-ctype database Postgres `LOWER()` leaves non-ASCII untouched and the unicode duplicate-address test fails (`createdb -T template0 -E UTF8 --lc-ctype=en_US.UTF-8 --lc-collate=en_US.UTF-8 phoenix_kit_locations_test` when the cluster default is `C`).
- **Known noise:** `[error] Failed to assign type … / Failed to sync location types` (the FK-failure paths under test), `undefined_table` errors and warnings from `destructive_rescue_test`, and a compile-time "form with phx-change but missing id" warning from the inline rename form in `SpaceTree`.
- **Stability:** `for i in $(seq 1 10); do mix test; done` catches sandbox/activity-log flakes. Form tests target `#location-form` / `#location-type-form` / `#new-space-form` by id.

## Feature notes

| Feature | Constraint that must hold | Where |
|---|---|---|
| Spaces tree + Structure tab | A parent must be in the same Location (context guard, not DB); deletes cascade the subtree and fire only from the confirm modal | `dev_docs/guides/spaces.md` |
| Multi-scope attachments | All per-resource state lives in `attachments_by_scope`; every event carries its scope; pending folders are renamed after a `:new` insert | `PhoenixKitLocations.Attachments` moduledoc |
| Sites project extension | One-way duck-typed contract; `ProjectSitesLive` has no `handle_params/3` and never crashes the host project page | `PhoenixKitLocations.Web.ProjectSitesLive` moduledoc |
| PlacePicker | Sends `{:place_picker_select, id, %{location_uuid, space_uuid}}`; `selected_space_uuid` is seed-once | `PhoenixKitLocations.Web.Components.PlacePicker` moduledoc |

## Versioning & releases

SemVer. The version is single-sourced in `mix.exs` (`@version`); `version/0`
reads it at compile time and the behaviour test asserts against
`Mix.Project.config()[:version]`, so nothing else needs bumping.

Release procedure (the steps the maintainer runs):

1. Bump `@version` in `mix.exs`; add a `CHANGELOG.md` entry headed `## x.y.z - YYYY-MM-DD`.
2. `mix precommit` clean.
3. Commit (`"Bump version to x.y.z"`) and push; verify the push landed.
4. `mix hex.publish`.
5. Tag, matching the form of the newest existing tag (`git tag --sort=-creatordate | head -1` shows it), and push the tag.
6. GitHub release via `gh release create` if the repo does those (`gh release list` shows whether it does).

Tags are immutable pointers: never tag before the commit is pushed and the
publish has succeeded.

## Pull requests & commits

- Commit messages start with an action verb (`Add`, `Update`, `Fix`, `Remove`, `Merge`). No AI attribution and no `Co-Authored-By` trailers.
- Version bumps and CHANGELOG entries land with the release commit on upstream, not in feature PRs.
- Review files live in `dev_docs/pull_requests/{year}/{pr_number}-{slug}/{AGENT}_REVIEW.md`, one file per reviewing agent, never edited by another agent; `FOLLOW_UP.md` records how each finding was resolved. Severities: `BUG - CRITICAL/HIGH/MEDIUM`, `IMPROVEMENT - HIGH/MEDIUM`, `NITPICK`.

## TODOs

- Move the strings still on core's `PhoenixKitWeb.Gettext` (`LocationsLive`, `LocationFormLive`, `LocationTypeFormLive`, `Errors`, `FilesCard`, `Attachments`) onto `PhoenixKitLocations.Gettext` and extract them; until then those pages render English in every locale. Trigger: the next i18n pass or a translated-locale bug report.
- `PlacePicker` has no production consumer; `:selected_location_uuid` is accepted but unused and Space names inside its tree are untranslated. Trigger: the first warehouse/manufacturing integration.
- `hall`, `suite`, `corner` are allowed by the DB CHECK but not by `Space.kinds/0`; enabling one is a schema-only change (`@kinds`, `kind_label/1`, `kind_icon/1`). Trigger: a product request for that kind.
