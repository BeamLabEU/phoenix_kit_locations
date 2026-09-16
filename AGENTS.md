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
- **Admin surface:** tab `:admin_locations` at `/admin/locations` (`group: :admin_modules`, priority 670, redirects to its first subtab). Visible subtabs (only with `locations.manage_all`; an owner-scoped user gets the bare parent entry, since a lone "Locations" child under "Locations" reads as a duplicate): Locations (`/admin/locations`), Types (`/admin/locations/types`). Hidden subtabs: `/admin/locations/new`, `/admin/locations/:uuid/edit`, `/admin/locations/:uuid/structure`, `/admin/locations/types/new`, `/admin/locations/types/:uuid/edit`. Plus a Sites tab rendered inside a project page by the projects hub.
- **Who sees what:** one set of pages for everyone (core retired the `/dashboard` user dashboard; user and admin pages both live under `/admin`, renameable via `admin_path`). The base `locations` permission scopes every page to the locations owned by the user or by the user's organization; the `locations.manage_all` sub-permission opens every location, ownership, internal notes, attachments and Types (`PhoenixKitLocations.Policy`, the `phoenix_kit_bookings` pattern). `user_dashboard_tabs/0` stays `[]`.
- **Module key** `"locations"`; settings prefix `locations_`.

## What this module does NOT do

- **No PubSub broadcasts or real-time sync.** Locations are reference data edited by admins and by their owners; no LiveView subscribes. Two editors of one record is last-write-wins. Adding broadcasts means a new `pubsub_topic/0`, a mount-time subscribe and a payload-minimal contract; defer until there is a consumer.
- **No soft-delete / restore.** Hard delete only. FK cascades remove type assignments and the whole space subtree; nothing survives into a restore flow.
- **No background jobs / Oban workers.** No reconciliation, async geocoding or import worker. CSV/XLSX import is out of scope (each location is hand-curated).
- **No external HTTP calls.** No geocoding API, map tiles or reverse DNS; no SSRF surface to harden.
- **No public API routes.** Every route sits in `live_session :phoenix_kit_admin` behind the `locations` permission, and is owner-scoped without `locations.manage_all`. The context modules are the only public API; no JSON, REST or GraphQL.
- **No roles inside an organization.** A location has at most one owner (`owner_uuid` → `phoenix_kit_users`, a person or an organization account). In core a person belongs to at most one organization (`organization_uuid` on the user row) and there are no org-internal roles, so every member of an organization sees and manages the organization's locations equally (`Policy.owner_uuids/1`). There is no org-admin/member split and no multi-organization membership.
- **No per-page permission beyond `locations`.** Core maps each LiveView to one permission key, and `LocationsLive` serves both the list and Types, so every tab carries `locations`. The list and Types subtabs hide themselves with `visible:` and `LocationsLive` (`:types`) / `LocationTypeFormLive` redirect a scope without `locations.manage_all` themselves.
- **No address validation against a registry.** `find_similar_addresses/5` detects exact-match duplicates in the local DB only.
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
- **Routing:** every page, visible or hidden, is a `live_view:` on a `Tab` in `admin_tabs/0`; `route_module/0` is nil. Static paths (`locations/new`, `locations/types/new`, `locations/types/:uuid/edit`) are listed before the `:uuid` wildcards (`locations/:uuid/edit`, `locations/:uuid/structure`). `:admin_locations_list` matches with a regex (`(?:^|/)locations(?:/new|/[^/]+/edit)?$`) so `/new` and `/:uuid/edit` highlight it without swallowing the `types` subtree (`:prefix` swallows, `:exact` misses). Never hand-register these routes in a host router; core's `guides/custom-admin-pages.md` is the reference. A host that wants the data without the UI sets `config :phoenix_kit, hidden_admin_tabs: [:admin_locations]`. Owner-scoped access is a sub-permission on the same pages, never a parallel `my-…` page family (no module in the ecosystem has one) or `user_dashboard_tabs/0`. `personal: true` wouldn't help either: core admits personal views only from its hardcoded `@personal_admin_views` list, so a module tab without a permission falls back to `locations` through namespace inference.
- **LiveView macro:** `use Phoenix.LiveView` with explicit imports (`PhoenixKitWeb.Components.Core.{Icon, Input, Select, Textarea, Modal, TableDefault, TableRowMenu, NavTabs}`, `PhoenixKitWeb.Components.MultilangForm`, `LanguageSwitcher`), never `use PhoenixKitWeb, :live_view`. Components are `use Phoenix.Component` / `use Phoenix.LiveComponent`. No template wraps in `LayoutWrapper`; the admin live_session supplies the layout. Assigns available in admin pages: `@phoenix_kit_current_scope`, `@phoenix_kit_current_user`, `@current_locale`, `@url_path`.
- **Page headers live in core's admin header, never in the body.** No page renders `<.admin_page_header>`. Each LiveView assigns `page_title`, and where it is nested `page_section` ("Locations" → `Paths.index/0`) and `page_crumbs`; the admin layout renders them as "Project / Locations / New". The create button is `page_action: %{icon:, label:, navigate:}` (a plugin LiveView cannot pass the `:action` slot). Titles: list "Locations" (+ New Location), types "Locations / Types" (+ New Type), location form "Locations / New" or "Locations / <name>", Structure "Locations / <name>", type form "Locations / Types / New" or "… / <name>". `LocationsLive` serves both actions, so `assign_header/2` resets all four keys on every patch. Header strings use `gettext_with_backend(PhoenixKitLocations.Gettext, …)` in the LiveViews still on core's backend. `Test.Layouts.app/1` renders these assigns as `#header-section`, `.header-crumb`, `#header-title`, `#header-action` so tests can assert them.
- **Gettext is a hybrid.** The module's own `PhoenixKitLocations.Gettext` (`priv/gettext`, en/et/ru) serves the admin tabs (`gettext_backend: PhoenixKitLocations.Gettext`, `gettext_domain: "default"` on every `Tab`), `Space.kind_label/1`, `LocationStructureLive`, `LocationTabs`, `SpaceTree`, `PlacePicker` and `OwnerComponents`. Core's `PhoenixKitWeb.Gettext` serves `LocationsLive`, `LocationFormLive`, `LocationTypeFormLive`, `Errors`, `FilesCard` and `Attachments`. New strings go on the module backend. Extract with `mix gettext.extract --merge`. The tab-label msgids (`Locations`, `Types`, `New Location`, `Edit Location`, `New Type`, `Edit Type`, `Structure`) are looked up at runtime by core's `Tab.localized_label/1`, so the extractor never sees that use: they are hand-written in the pot/po **without** the `elixir-autogen` flag, which is what stops `--merge` from pruning them. `Locations`, `Types`, `New Location` and `New Type` now also have header call sites, so `--merge` re-adds the flag to them; strip it again after every merge. Review `--merge`'s `fuzzy` guesses: it pairs new msgids with unrelated translations (it matched "Actions" to "Section").
- **JS hooks:** no `js_sources/0` bundle. The one hook, `.PkLocationsUploadScope` in `FilesCard`, is a `Phoenix.LiveView.ColocatedHook` (compiled into the host's colocated manifest, spread into the LiveSocket as `colocatedHooks`). Never register a hook from a plain inline `<script>`: morphdom does not execute inserted script tags, so it vanishes on LiveView navigation.
- **`enabled?/0`** reads `locations_enabled` via `Settings.get_boolean_setting/2`, rescues every error **and catches `:exit`**, returning `false` (the DB may be down at boot; sandbox-owner exits on test teardown otherwise surface as a 1-in-N flake). `enable_system/0` / `disable_system/0` write the setting through `update_boolean_setting_with_module/3` and log the toggle.
- **Activity logging:** every mutating function in `Locations` and `Spaces` accepts `opts \\ []`; LiveViews thread the caller through `actor_opts/1`, which reads `socket.assigns[:phoenix_kit_current_scope].user.uuid` into `actor_uuid:`. Two helpers per context: `log_activity/5` is a pipe step on a repo result (`{:ok, struct}` logs metadata; `{:error, %Ecto.Changeset{}}` logs a `db_pending: true` row with the invalid field names only; `{:error, atom}` passes through unlogged), and `maybe_log_activity/5` is called directly by operations with no single repo result. Both call `PhoenixKit.Activity.log/1` inside `Code.ensure_loaded?(PhoenixKit.Activity)`, swallow `Postgrex.Error` `:undefined_table` (host without the activities table) and `Logger.warning` anything else; logging never crashes the primary operation. Metadata is minimal and PII-aware: `name`, `city`, `status`, `owner_uuid` for locations; `name`, `status` for types; `name`, `kind`, `status`, `location_uuid`, `parent_uuid` for spaces. Never log `email`, `phone` or `notes`. Action format is `resource.verb` (table in Architecture).
- **Hard delete only**, no soft-delete sentinel.
- **Single context per aggregate:** `Locations` (locations, types, assignments, duplicate detection) and `Spaces` (the tree). Schemas are data-only with changesets. Both read the repo through `PhoenixKit.RepoHelper.repo()`.
- **Errors dispatcher:** non-changeset errors are atoms (`:location_not_found`, `:location_type_not_found`, `:location_delete_failed`, `:location_type_delete_failed`, `:type_assignment_failed`, `:owner_update_failed`, `:not_allowed`, `:space_not_found`, `:parent_in_other_location`, `:parent_not_found`, `:cycle`, `:parent_floor_unsaved`, `:unexpected`). LiveViews call `PhoenixKitLocations.Errors.message/1` at the UI boundary; strings pass through, anything else renders as `Unexpected error: <inspect>`. Extend `Errors.message/1` instead of inlining user-facing error strings.
- **Multilang:** translatable fields are `name`, `description`, `public_notes` on Location, `name`, `description` on LocationType and Space. Primary-language values live in the columns; other languages nest in `data` under the language code with `_`-prefixed keys (`"_name"`). Forms use core's `MultilangForm` (`mount_multilang/1`, `handle_switch_language/2`, `merge_translatable_params/4` with `preserve_fields`, `get_lang_data/3`; components `multilang_tabs`, `multilang_fields_wrapper`, `translatable_field`). A form LiveView assigns both `:changeset` (read by `<.translatable_field>`) and `:form = to_form(changeset, as: :location)` (read by core `<.input>` / `<.select>` / `<.textarea>`) and keeps them in sync through one `assign_form/2` helper (`assign_space_form/2` on the Structure tab).
- **Core form primitives** (`<.input field={@form[:x]}>`, `<.select>`, `<.textarea>`) rather than raw HTML; they wire labels, errors and daisyUI styling.
- **Location form:** one `<.form id="location-form">` with `phx-change="validate"` / `phx-submit="save"`, laid out as three cards: Public Information (translatable fields, address, contact, features), Files & Featured Image, Internal (admin notes, status, type badges). `features` is a `%{"key" => boolean}` map toggled by `toggle_feature` (keys in `@feature_keys`, labels via `feature_label/1` so the literals are extractable); types toggle via `toggle_type` into a `MapSet` and are synced after save. `check_address` runs on `phx-blur` of the address fields and reads the changeset, not the event payload. The Details/Structure tab strip renders only in `:edit` (a new location has no uuid). Save is disabled while uploads are in flight. What the form offers depends on the scope; `@mode` (`:all` / `:own`) is set at mount for rendering, but every write re-reads the live scope. **`locations.manage_all`** adds the owner card above the form (`OwnerComponents.owner_picker_card/1`). It carries its own `#owner-search-form` because forms cannot nest; `pick_owner` only accepts a uuid from the current search results, and the owner is pending until save. On `:edit`, an owner change goes through `set_location_owner/3` after `update_location/3`. **Base `locations` only** hides the owner card, the Files card and internal notes. It drops the `notes` param server-side, creates with `owner_uuid:` from `Policy.new_owner_uuid/1` (the user's organization when they belong to one, else the user; refuses to create without a user), resolves edits through `Policy.get_location/2` at mount and again at save, scopes `check_address` to the user's own locations, and ignores the owner events.
- **Policy:** `PhoenixKitLocations.Policy` is the one place access is decided. `manage_all?/1` is `Scope.can?(scope, "locations.manage_all")`, which also requires the base key held and the module enabled. `owner_uuids/1` is the user's uuid plus their `organization_uuid` when set (accepts a scope or a user, for host code); `new_owner_uuid/1` is the organization when there is one, else the user. `list_locations/2` pins a scope without `manage_all` to `owner_uuid: owner_uuids` (and ignores any `owner_uuid:` it passes); `get_location/2` resolves any location for `manage_all` and otherwise only one owned by `owner_uuids` (malformed uuid → `nil`); `similar_address_opts/1` scopes the duplicate warning. Every LiveView resolves client-supplied uuids through it: the list's deletes, the form's mount and save, and the Structure page's mount. The Structure page additionally accepts a space uuid only when the space belongs to the loaded location (`space_in_location/2`), and drops space `notes` and hides Files without `manage_all`. Hiding is not the gate: both LiveViews route every file event through one `@attachment_events` clause that ignores it without `manage_all` (live scope), and they only call `allow_attachment_upload/1` for `manage_all`, so a forged upload has no channel. `Attachments.inject_attachment_data/3` removes a client-sent `files_folder_uuid` / `featured_image_uuid` when the scope has none, and `create_space` strips both (`Attachments.drop_attachment_pointers/1`); a stored forged pointer would aim later file actions at another account's folder. Structure writes (`@location_writes`) re-resolve the location through `Policy` before running, via a `location_rechecked` flag and re-dispatch; `open_add_child` only accepts a parent from the tree.
- **Type sync:** `sync_location_types(location_uuid, type_uuids, opts)` is delete-all + re-insert in a transaction returning `{:ok, :synced}`; when the requested set equals the current set it short-circuits to `{:ok, :unchanged}` with no write and no log entry. `add_location_type/3` is a no-op when already assigned; `remove_location_type/3` returns `{:ok, 0 | 1}`.
- **Ownership:** `owner_uuid` (nullable, FK → `phoenix_kit_users`, `ON DELETE CASCADE`, V2) is **not** in `Location.changeset/2`'s cast list; only `Location.owner_changeset/2` sets it. Callers set it through `create_location(attrs, owner_uuid: uuid | nil)` or change it with `set_location_owner/3`. `set_location_owner/3` logs `location.owner_changed` (`owner_from` / `owner_to`); setting the current owner again returns `{:ok, location}` with no write and no log, and an unknown user comes back as an `:owner_uuid` changeset error. `update_location/3` never changes the owner. The `owner_uuid:` filter on `list_locations/1`, `count_locations/1` and `find_similar_addresses/5` (and `PlacePicker`'s `:owner_uuid` attr) is read with `Keyword.fetch`/`Map.fetch`: omitted means every row, a uuid means that owner's rows, a list means rows owned by any of them (`[]` → none), `nil` means unowned only, and `:any` means every owned row. Tenant-facing single-row lookups use `get_location_for_owner/2` (one owner uuid or a list), which returns `nil` for foreign, unowned or malformed input. Deleting a user cascades their locations with their type assignments and space trees; `before_user_delete/1` logs `location.deleted` for each one first (`mode: "auto"`, `reason: "owner_deleted"`), since the cascade leaves no trace.
- **Duplicate detection:** `find_similar_addresses/5` matches on lower-cased, trimmed `address_line_1` + `city` + `postal_code`, limit 5, excludes the record being edited, takes an `owner_uuid:` scope (the form passes `Policy.similar_address_opts/1`, so without `manage_all` the warning never names another account's location), and rescues to `[]` so the form still saves.
- **Spaces:** `kind` is app-narrowed to `floor room zone section aisle shelf` (the DB CHECK also allows `hall suite corner`). The same-Location parent rule and indirect-cycle guard live in the `Spaces` context, not the schema or the DB; the schema catches only a direct self-parent. `create_space/2` appends to the sibling group when no `position` is given. The Structure tab commits immediately (no drafts); deletes cascade the subtree and fire only from the confirmation modal that shows `count_descendants/1`. Details in `dev_docs/guides/spaces.md`.
- **Attachments:** per-scope state in `socket.assigns.attachments_by_scope`, keyed by an opaque scope string (`"location"` on the form; the Space uuid on the Structure tab); modal state is shared at socket level and tracks `:media_selector_scope`. One upload config, `:attachment_files` (any type, 20 entries, 100 MB, auto-upload); every event carries `phx-value-scope`; the dropzone sets the active scope on click and on `dragenter` (the colocated hook). Pointers `files_folder_uuid` / `featured_image_uuid` live in the resource's `data` JSONB and are merged into params at save by `inject_attachment_data/3`. Folders are named `location-<uuid>` / `location-space-<uuid>` (`folder_name_for/1`); a `:new` resource uploads into `location-attachment-pending-<uuid>` and `maybe_rename_pending_folder_for/3` renames it after the insert (name only, never a move: core's `Storage.update_folder/3` treats any explicit `parent_uuid`, `nil` included, as a move). A host can set `config :phoenix_kit_locations, :attachments_parent_folder, {Mod, :fun}` (`fun(kind, actor, resource)` or `fun(kind, actor)`) and `:attachments_folder_name` (`fun(resource, actor)`); a raising hook degrades to `nil`. Host names are not unique across owners, so a folder found by host name is adopted only when no other Location/Space `data` points at it, and a taken host name falls back to the deterministic name. The featured-image picker is core's `MediaSelectorModal` (`:image` filter, `:single` mode) replying `{:media_selected, uuids}` / `{:media_selector_closed}`. Uploads need `@phoenix_kit_current_user` (folder and file are owned by that user; without one the upload fails with `:no_user`). Removing a file soft-trashes a single-owner home file and only unlinks a multi-resource one.
- **Sites extension** (`phoenix_kit_project_extensions/0`): a plain map (`key: "locations_sites"`, `module_key: "locations"`, `default_enabled: false`, one tab `sites` → `ProjectSitesLive`, `config_schema` with `location_uuids`, `permission_actions: [:view]`). `ProjectSitesLive` is rendered by the hub via `live_render` with its embed-session contract, reads `session["config"]["location_uuids"]`, has **no `handle_params/3`** (off-router mount is the hub's hard requirement), and degrades a stale uuid or DB error to a missing card rather than crashing the host page.
- **`css_sources/0`** returns `[:phoenix_kit_locations]` (atoms; the core compiler resolves them to `lib/` + `priv/`).

### Landmines

- `Spaces.update_space/3` does `Map.put_new(attrs, "location_uuid", …)`: atom-keyed attrs become a mixed-key map and `cast/3` raises `Ecto.CastError`. Pass string-keyed attrs, as `LocationStructureLive` and the tests do.
- Root-sibling queries (`reorder_siblings/4`, `next_position/2`) must match `is_nil(parent_uuid)`; a pinned `^nil` compiles to `= NULL`, never matches, and floor reordering silently updates zero rows.
- `phx-blur` payloads carry only `key`/`value`, never form params. `check_address` reads `socket.assigns.changeset`; a clause matching `%{"location" => params}` crashes the LiveView on every blur and the reconnect wipes the form.
- Strings on core's `PhoenixKitWeb.Gettext` backend (the three list/form LiveViews, `Errors`, `FilesCard`, `Attachments`) are not in core's catalogue, so they render as the English msgid in every locale; `Attachments` also uses the runtime `Gettext.gettext(Backend, …)` form the extractor cannot see. Moving a string to the module backend is the fix, not editing core's po.
- Never add `elixir-autogen` to the hand-written tab-label msgids in `priv/gettext`: `mix gettext.extract --merge` then finds no call site, drops them, and the sidebar falls back to English with no warning.
- **Omitting `owner_uuid:` returns every location.** A tenant-facing `list_locations/1` or `PlacePicker` without it leaks every account's addresses. Pass it explicitly. A mistaken `nil` fails closed (global rows only).
- `owner_uuid` in `attrs` is silently ignored. That's deliberate (a form forwarding browser params must not reassign ownership), so a caller that "sets the owner" through `create_location(%{owner_uuid: ...})` gets a global location; use the `owner_uuid:` opt.
- Don't put pages in `user_dashboard_tabs/0` or render `PhoenixKitWeb.Layouts.dashboard`: core retired `/dashboard` (`user_dashboard_enabled` defaults to `false`, so those routes don't exist on a default host).
- Don't give the Types tabs `permission: "locations.manage_all"`: core caches ONE permission key per LiveView module (`cache_custom_view_permission/2`, last write wins), and `LocationsLive` also serves the list, so a base-only user could lose the list. Gate Types in the LiveViews instead.
- `Scope.can?/2` resolves `locations.manage_all` through core's `ModuleRegistry` (base key + module-enabled check). The test helper starts `ModuleRegistry` and `LiveCase` enables the module; without either, every scope looks base-only.
- Organization membership changes don't refresh an open LiveView's scope: core's `Auth.set_organization` / `remove_from_organization` broadcast nothing, so `scope.user.organization_uuid` stays stale. A removed member keeps access to the organization's locations until their next page load or reconnect.
- `Auth.register_user/1` in a test needs core's Hammer rate-limiter process, which this suite doesn't start (the ETS table is missing). `fixture_user/1` inserts through the `User` schema instead.

## Architecture

```
lib/phoenix_kit_locations.ex                 # PhoenixKit.Module: admin + user tabs, permission, css_sources, project extension, before_user_delete
lib/phoenix_kit_locations/
├── locations.ex                             # Locations context: types, locations, assignments, duplicates, logging
├── spaces.ex                                # Spaces context: tree reads, CRUD, reorder, parent/cycle guards, logging
├── migrations.ex                            # Module-owned versioned chain (V1 adopts core V135's four tables; V2 owner_uuid)
├── policy.ex                                # Access: base `locations` = own locations, `locations.manage_all` = all
├── attachments.ex                           # Multi-scope files + featured image (Location and each Space)
├── errors.ex                                # Error atom -> translated message
├── media_reorganizer.ex                     # Storage.Reorganizer source: plans legacy folder moves via the attachment hooks
├── gettext.ex                               # PhoenixKitLocations.Gettext backend
├── paths.ex                                 # URL helpers
├── schemas/
│   ├── location.ex                          # phoenix_kit_locations
│   ├── location_type.ex                     # phoenix_kit_location_types
│   ├── location_type_assignment.ex          # phoenix_kit_location_type_assignments
│   └── space.ex                             # phoenix_kit_location_spaces (+ kinds, kind_label/1, kind_icon/1)
└── web/
    ├── locations_live.ex                    # :index (locations) and :types lists, delete confirm modals
    ├── location_form_live.ex                # :new / :edit location (Details tab), scoped via Policy
    ├── location_structure_live.ex           # :edit Structure tab (space tree CRUD + detail panel)
    ├── location_type_form_live.ex           # :new / :edit location type
    ├── project_sites_live.ex                # Sites tab inside the projects hub
    └── components/
        ├── files_card.ex                    # files_card_body/1 + colocated .PkLocationsUploadScope hook
        ├── location_tabs.ex                 # Details / Structure strip via core <.nav_tabs variant={:border}>
        ├── owner_components.ex              # admin owner filter, owner labels, owner picker card
        ├── place_picker.ex                  # LiveComponent: location combobox + space tree picker
        └── space_tree.ex                    # space_tree/1, pure presentation, picker mode
```

### Data model (UUIDv7 PKs, `use PhoenixKit.SchemaPrefix`, `timestamps(type: :utc_datetime)`)

| Schema | Table | Notes |
|---|---|---|
| `LocationType` | `phoenix_kit_location_types` | `name`, `description`, `status` (`active`/`inactive`), `data` JSONB |
| `Location` | `phoenix_kit_locations` | `name`, `description`, `public_notes`, `address_line_1/2`, `city`, `state`, `postal_code`, `country`, `phone`, `email`, `website`, `notes`, `status`, `features` JSONB, `data` JSONB, `owner_uuid` (nullable FK → `phoenix_kit_users` CASCADE, indexed; set only via `owner_changeset/2`); `has_many :location_types, through:` the join |
| `LocationTypeAssignment` | `phoenix_kit_location_type_assignments` | `location_uuid`, `location_type_uuid` (both FK CASCADE, `assoc_constraint` so FK failures come back as changesets); unique on the pair |
| `Space` | `phoenix_kit_location_spaces` | `location_uuid` (required, FK CASCADE), `parent_uuid` (self FK CASCADE), `kind` (CHECK), `name`, `description`, `notes`, `status`, `position`, `data` JSONB; indexes on `(location_uuid)`, `(parent_uuid)`, `(location_uuid, parent_uuid, position)` |

Changeset rules: `name` required (1–255); `email` must contain `@`; `website` must start with `http://` or `https://`; `status` in `active`/`inactive`; length caps on every text column.

### Activity log actions (`module: "locations"`, `mode` defaults to `"manual"`)

| Action | Resource | When |
|---|---|---|
| `location.created` / `updated` / `deleted` | `location` | Location CRUD; also `deleted` with `mode: "auto"`, `reason: "owner_deleted"` from `before_user_delete/1` |
| `location.owner_changed` | `location` | `set_location_owner/3`, only when the owner changed (`owner_from` / `owner_to`) |
| `location.types_synced` | `location` | `sync_location_types/3`, only when the set changed (`types_from` / `types_to`) |
| `location.type_added` / `type_removed` | `location` | single assignment add/remove (`type_uuid`) |
| `location_type.created` / `updated` / `deleted` | `location_type` | LocationType CRUD |
| `space.created` / `updated` / `deleted` | `location_space` | Space CRUD (children of a cascade are not logged) |
| `space.reordered` | `location_space` (resource = parent uuid) | `reorder_siblings/4` (`location_uuid`, `count`) |
| `locations_module.enabled` / `disabled` | `module` | `enable_system/0` / `disable_system/0` |

- **Settings keys:** `locations_enabled`.
- **Permissions:** base `locations` (`permission_metadata/0`; every tab carries `permission: module_key()`): the Locations pages scoped to the user's own locations. Sub-permission `locations.manage_all` (declared in `permission_metadata/0` `sub_permissions`, `Policy.manage_all_key/0`): every location, ownership, internal notes, attachments, Types. Core auto-grants sub-permissions to Admin at boot; Owner holds all keys. ⚠️ A custom role holding `locations` from before this split now sees only its own locations until it is granted `locations.manage_all`. The Sites extension declares `permission_actions: [:view]` for the hub.
- **PubSub topics:** none.

## Database & migrations

Owns a versioned chain: `PhoenixKitLocations.Migrations` via
`migration_module/0`, marker `pkloc_schema:<N>` as a `COMMENT ON TABLE` on
`phoenix_kit_locations` (a marker-less or foreign comment reads as 0). The SQL
is exposed as data (`up_statements/2`, `down_statements/2`); `up/1` / `down/1`
`execute/1` it, so they only work inside an `Ecto.Migration` run. Hosts never
hand-write a migration: `mix phoenix_kit.update` runs core's chain, then
generates a wrapper calling `up(prefix:, version:)`.

- **V1 is adoption, not creation.** Core's V135 baseline still creates
  `phoenix_kit_locations`, `phoenix_kit_location_types`,
  `phoenix_kit_location_type_assignments` and `phoenix_kit_location_spaces`
  (no later core version reshapes them). V1 re-states that DDL verbatim
  (`CREATE TABLE IF NOT EXISTS`, guarded `DO $$` PK/FK/CHECK blocks, `IF NOT
  EXISTS` indexes, core's exact object names) and stamps the marker. On
  existing installs only the marker is new; on a future core whose baseline no
  longer creates the tables, the same statements create them.
- **V2 adds ownership:** `ALTER TABLE ... ADD COLUMN IF NOT EXISTS owner_uuid uuid`, the guarded
  `phoenix_kit_locations_owner_uuid_fkey` (→ `phoenix_kit_users(uuid)` `ON DELETE CASCADE`) and
  `phoenix_kit_locations_owner_uuid_index`. It only adds objects the manifest never names, so
  no core step was needed.
- **`down/1` never drops a table** — it only rewrites or clears the marker (rolling back to V1
  leaves the `owner_uuid` column, FK and index in place).
  `migrations_test.exs` asserts no emitted statement matches
  `DROP|TRUNCATE|DELETE`.
- **Never edit a shipped version's statements.** A change is a new version
  appended behind `target >= N` in `up_statements/2` plus a bumped
  `@current_version`.
- **A V2+ that changes shape needs core first.** Core's `ExpectedSchema`
  manifest still audits these tables (`owner: :locations`); before release add
  the altered objects to core's manifest generator `@excluded_exact`
  (`dev_docs/squash/generate_baseline.exs`), regenerate the manifest, and raise
  the `:phoenix_kit` floor to that release, or `mix phoenix_kit.repair` restores
  the V135 shape. Additive objects the manifest never names (a new table,
  index, or column) are outside its reach and need no core step. Reference:
  `phoenix_kit_legal`'s `dev_docs/reports/2026-08-10-consent-logs-extraction.md`.
- **Never write a conditional core migration** ("module absent → drop table").

The `kind` CHECK constraint (`phoenix_kit_location_spaces_kind_check`) allows
`floor room hall suite section zone aisle shelf corner`; the app list is
narrower. All five FKs (four from V135, the owner FK from V2) are `ON DELETE CASCADE`. UUIDv7 PKs and
`use PhoenixKit.SchemaPrefix` on every table-backed schema (a conformance test
enforces the latter).

## Testing

- **DB:** `phoenix_kit_locations_test` (+ `MIX_TEST_PARTITION` suffix), overridable with `PGDATABASE`. `config/test.exs` honours `PGUSER` (default `postgres`), `PGPASSWORD`, `PGHOST`, `PGPOOL` (pool size; default `schedulers_online * 2`). It also sets `config :phoenix_kit, repo: PhoenixKitLocations.Test.Repo`; without it every `RepoHelper` call fails with "No repository configured".
- **`test/test_helper.exs`:** `Code.require_file`s the support modules first (Elixir 1.19 no longer auto-loads `test/support` at helper time), checks `psql -lqt` for the DB, then starts the repo, runs `PhoenixKit.Migration.ensure_current/2` (core's chain), replays `Migrations.up_statements/1` through the repo when `migrated_version_runtime/1` is behind, starts `PhoenixKit.PubSub.Manager` + `PhoenixKit.ModuleRegistry` (sub-permission resolution), sets the sandbox to `:manual`, pins `:persistent_term.put({PhoenixKit.Config, :url_prefix}, "/")`, and starts `Test.Endpoint` (`server: false`) only when the DB is available. Without a DB, `ExUnit.start(exclude: [:integration])`.
- **Runs without Postgres:** the behaviour test, `errors_test`, `attachments_test`, `space_tree_test`, `core_pin_conformance_test`, `schema_prefix_conformance_test`, `migrations_test` (pins V1 and V2's table/index/constraint names, guards, cascades, prefix threading, version targeting and no-destruction; its drift lock checks every `owner: :locations` object core's `ExpectedSchema` requires is emitted, skipping when the manifest is not generated).
- **Support modules:** `Test.Repo`; `DataCase` (sandbox owner, tags `:integration`, imports `ActivityLogAssertions`, `errors_on/1`); `LiveCase` (same plus `Phoenix.LiveViewTest`, `fake_scope/1` returning a real `PhoenixKit.Users.Auth.Scope` with `cached_roles` as role-name strings, `put_test_scope/2`, `fixture_location/1`, `fixture_location_type/1`); `fixture_user/1` in both cases (a real `phoenix_kit_users` row for owner FKs); `LiveCase` also enables the module (`enable_locations/0`) and starts every conn with a `fake_scope/1` holding `locations` + `locations.manage_all` (pass `permissions: ["locations"]` for an owner-scoped user, as `scoped_locations_live_test.exs` does); `Test.Endpoint` + `Test.Router` (base `/en/admin/locations`, mirroring `Paths`) + `Test.Layouts`; `Test.Hooks` (`:assign_scope` on_mount reads `"phoenix_kit_test_scope"` from the session into `:phoenix_kit_current_scope` / `:phoenix_kit_current_user`); `ActivityLogAssertions.assert_activity_logged/2` (`resource_uuid:`, `actor_uuid:`, `metadata_has:`); `PlacePickerHarnessLive` at `/en/admin/locations/__test__/place-picker` (test-only host for the LiveComponent).
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
| Media reorganizer source | `media_reorganizer/0` → `MediaReorganizer.plan/2` (core 2.24+ `mix phoenix_kit.media.reorganize`). Plain maps, no `@behaviour` while the core floor is `~> 2.0`; every action must pass core's `Reorganizer.Action.new!/1` (a test enforces it). Without a configured `:attachments_parent_folder` hook it only reports; a failing hook is `:hook_error`, never root; it never creates folders | `PhoenixKitLocations.MediaReorganizer` moduledoc, core `Reorganizer.Source` moduledoc |
| Sites project extension | One-way duck-typed contract; `ProjectSitesLive` has no `handle_params/3` and never crashes the host project page | `PhoenixKitLocations.Web.ProjectSitesLive` moduledoc |
| PlacePicker | Sends `{:place_picker_select, id, %{location_uuid, space_uuid}}`; `selected_space_uuid` is seed-once; a given `:owner_uuid` also gates `select_location` | `PhoenixKitLocations.Web.Components.PlacePicker` moduledoc |
| Ownership + scoped access | No client-supplied value reaches another account's location: owner never cast from attrs; without `locations.manage_all` every page resolves through `Policy` (mount and save) and spaces must belong to the loaded location; owner filter omitted = all rows | `PhoenixKitLocations.Policy`, `Locations` docs, `LocationFormLive` moduledoc |

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
- Without `locations.manage_all` the form and Structure page hide Files (and space internal notes). `MediaSelectorModal` confines browsing to `scope_folder_id` only once the resource has a folder; with none it browses the whole library. Scoping it (e.g. its `user_uuid` attr) would let owners attach files. Trigger: an owner who needs floor plans or photos on their own locations.
- `ProjectSitesLive` is not owner-scoped: it shows every location the project's config names to anyone who can view the project. Scoping needs the viewer's scope in the hub's embed session. Trigger: projects shared across tenants.
- Core's V135 baseline still creates the four location tables (Phase 2 of the extraction). They leave core's baseline at its next squash, after which `Migrations` V1 is the only creator; nothing changes here. Trigger: the core squash PR, which should list these tables as module-owned.
