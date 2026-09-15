# Spaces: the per-Location tree and the Structure tab

How nested spaces (floors, rooms, zones, sections, aisles, shelves) are modelled,
guarded, edited and attached to files. Rules for this live in
[AGENTS.md](../../AGENTS.md) → Conventions and Feature notes.

## Data model

A `Space` (`phoenix_kit_location_spaces`) is a nested space inside a `Location`.
Spaces form a filesystem-like tree per Location: each row belongs to exactly one
Location (required `location_uuid` FK, ON DELETE CASCADE) and may optionally
belong to a parent Space (self-referencing `parent_uuid` FK, ON DELETE CASCADE),
forming arbitrary-depth nesting. `position` orders siblings within one
`(location_uuid, parent_uuid)` group; the composite index on
`(location_uuid, parent_uuid, position)` backs sibling-ordering queries.

`name` and `description` are translatable. Primary-language values stay in the
dedicated columns; secondary languages live under a language-code key in `data`,
for example `%{"es-ES" => %{"_name" => "Planta 2"}}`. Top-level keys in `data`
carry attachment pointers (`files_folder_uuid`, `featured_image_uuid`),
mirroring how `phoenix_kit_locations.data` is used.

### Kind

`kind` is a fixed string from `Space.kinds/0`: `floor room zone section aisle
shelf`. Floor and room are the top-level subdivisions of a location;
zone/section/aisle/shelf are finer-grained subdivisions (production
zones/sections, warehouse addressable storage). The DB CHECK constraint
(`phoenix_kit_location_spaces_kind_check`, created by core's baseline and
adopted by V1 of `PhoenixKitLocations.Migrations`) intentionally still allows a
wider set (`hall`, `suite`, `corner`) reserved for future growth without an
immediate migration; narrowing to the app-layer list happens in the schema.
Adding one of the reserved kinds is a schema-only change: extend `@kinds`,
`kind_label/1` and `kind_icon/1`. Adding a kind outside the CHECK list is a new
version of this module's chain, which, because it changes a constraint core's
`ExpectedSchema` audits, needs the core manifest-exclusion step first (see the
`PhoenixKitLocations.Migrations` moduledoc).

`Space.kind_label/1` translates the label through the module's own Gettext
backend and falls back to the raw kind string for anything outside `@kinds`.
`Space.kind_icon/1` maps each kind to a heroicon and falls back to `hero-cube`.

## Invariants guarded in the `Spaces` context

### Same-Location parent

A space's `parent_uuid` (when set) must reference another space in the **same**
Location. The DB does not enforce this directly; a composite FK on
`(parent_uuid, location_uuid)` would, but it is heavier than the consumer surface
justifies. The guard sits at the context boundary instead: `create_space/2` and
`update_space/3` reject any cross-location parent with
`{:error, :parent_in_other_location}` (and an unknown parent with
`{:error, :parent_not_found}`). The schema changeset cannot check it (no parent
context without an extra DB read), so keep the invariant load-bearing on the
context.

### Cycle prevention

A direct self-loop is caught by the schema changeset (`validate_no_self_parent/1`).
Indirect cycles (A → B → A) are blocked in the context's `validate_no_cycle/3`
before any `parent_uuid` change is persisted. The walk up the parent chain is
depth-limited to 64 hops, generous for any realistic building hierarchy, so a
corrupted chain cannot spin forever.

### Attribute key shape

`attrs` may arrive string-keyed (form params) or atom-keyed (internal callers);
the parent/cycle checks read either so they never silently skip on a key-shape
mismatch. `update_space/3` does `Map.put_new(attrs, "location_uuid", …)`, so
callers must pass **string-keyed** attrs: atom-keyed attrs become a mixed-key
map and `cast/3` raises `Ecto.CastError`. `LocationStructureLive` and the test
suite call it string-keyed throughout.

## Reads

- `list_for_location/1`: flat list ordered by `(parent_uuid NULLS FIRST, position, inserted_at)`.
- `list_tree/1`: nested shape assembled in memory from that single query; each
  node is a `%Space{}` with its children under the struct's own `:children` key
  (not a `%{space: …, children: …}` envelope).
- `full_path/2`: `"Location / Floor / Zone / Shelf"` breadcrumb, `nil` when the
  space or its Location cannot be found. `opts[:locale]` resolves each segment
  through `PhoenixKit.Utils.Multilang.get_language_data/2`; omitted, it reads the
  primary-language column with no `data` read at all. Ancestors come from one
  recursive CTE using `UNION` (not `UNION ALL`) so a corrupted or cyclic chain
  terminates.
- `count_descendants/1`: every descendant (children, grandchildren, …), `0` for a
  leaf and `0` for an unknown uuid. Backs the delete-confirmation modal, because
  a hard delete CASCADEs the whole subtree.
- `translated_name/2` (`@doc false`, shared with `LocationStructureLive`) checks
  `data[locale]["_name"]` before `data[locale]["name"]` before the column.
  `MultilangForm.merge_translatable_params/4`, the form write path, stores
  translatable fields under the underscore-prefixed key; a bare `"name"` lookup
  would always fall back to the primary language regardless of locale.

### Raw CTE uuids

The CTE's outer select is schema-less, so rows come back as the raw 16-byte
binary Postgrex decoded off the wire, not the 36-char textual form every loaded
`%Space{}.uuid` carries. Re-querying with those raw values in
`where: s.uuid in ^raw_uuids` fails (`UUIDv7.dump/1` only accepts the textual
form). Normalise with `Ecto.UUID.load/1` first (`load_uuid/1`).

## Writes

- `create_space/2`: when `attrs` carries no explicit `position`, the new space
  is appended to the end of its sibling group (`max(position) + 1`, or `0` for
  the first child). Without this, every space created through the form (which
  never sends `position`) would sit at the schema default `0` and jump to the
  front on the next reorder. An explicit `position` is always honoured. The
  read-then-write is not atomic; a lost race yields a duplicate position among
  siblings, a cosmetic hiccup that self-heals on the next reorder.
- `update_space/3`: re-parenting is allowed, subject to the two guards above.
- `delete_space/2`: hard delete; children CASCADE via the DB FK. The activity log
  records the delete of the named root only; children are not individually
  logged.
- `reorder_siblings/4`: takes the full ordered list of sibling uuids for one
  `(location, parent)` group and rewrites `position` in a transaction. Root
  siblings carry `parent_uuid == nil`, which must be matched with `is_nil/1`; a
  pinned `== ^nil` compiles to SQL `= NULL`, never matches, and floor reordering
  silently updates zero rows.

### Activity logging parity with `Locations`

Mutating functions accept `opts \\ []` and forward `:actor_uuid`. Logging is
guarded with `Code.ensure_loaded?(PhoenixKit.Activity)` and rescued so it never
crashes the mutation.

- `{:ok, space}` logs with space metadata (`name`, `kind`, `status`,
  `location_uuid`, `parent_uuid`).
- `{:error, %Ecto.Changeset{}}` logs a `db_pending: true` row with the invalid
  field names only.
- `{:error, atom}` (`:cycle`, `:parent_in_other_location`, `:parent_not_found`,
  `:location_not_found`) is **not** logged: these rejections carry no changeset
  or resource uuid to attach to.

Actions: `space.created`, `space.updated`, `space.deleted`, `space.reordered`
(resource `location_space`; reorder logs `parent_uuid` as the resource with
`location_uuid` + `count` metadata).

## The Structure tab (`LocationStructureLive`)

The "Structure" tab of a Location's admin page (`/admin/locations/:uuid/structure`,
hidden tab `:admin_locations_structure`) mounts the Location, loads its tree via
`Spaces.list_tree/1`, and renders it through `SpaceTree.space_tree/1` next to
`LocationTabs.location_tabs/1`, the tab strip it shares with `LocationFormLive`'s
"Details" tab. Each tab is a separate LiveView, so the strip links use
`navigate`, not `patch`. The strip renders only once the Location has a uuid;
there is no Structure tab for a not-yet-created Location.

The page owns the tree's CRUD surface: creating a root or child space through a
small inline form below the tree, inline rename, sibling reorder (move up/down),
and hard delete. Every mutating call commits straight to `Spaces`, the
"immediate commit" model: no staged drafts, no separate save step.

Delete is the one exception to "immediate": a hard delete CASCADEs to the whole
subtree, so the tree's trash button (`delete_space`) only opens a confirmation
modal reporting `Spaces.count_descendants/1`. The count runs once, when the
modal opens, so the copy and every re-render agree. The actual
`Spaces.delete_space/2` call happens from the modal's own Delete button
(`confirm_delete_space`), which re-fetches the space rather than trusting the
uuid captured when the modal opened. After a delete the selection is cleared
whenever it no longer resolves in the refreshed tree (the node itself, or an
ancestor, was deleted).

Selecting a node opens a detail panel below the tree: a multilang
(name/description) form with status, notes and kind, plus the Space's own Files
+ Featured Image card, scoped to that Space's uuid via
`PhoenixKitLocations.Attachments`. The Space already exists in the DB by the time
it can be selected, so the panel's Save commits straight to
`Spaces.update_space/3`. The Attachments scope is mounted lazily on selection
(`assign_selected_space/2`), not for the whole tree up front, because trees can
run deep. The panel keeps `:space_changeset` (read by `<.translatable_field>`)
and `:space_form` (read by `<.select>` / `<.textarea>`) in sync through
`assign_space_form/2`, mirroring `LocationFormLive.assign_form/2`. A rename of
the currently selected node refreshes the panel so its Name field does not keep
the pre-rename value.

The breadcrumb ("Location name / Floor 1 / Zone A / Shelf 3") walks the
already-loaded tree with `Spaces.translated_name/2`, no extra query.

## `SpaceTree` (presentation only)

An adaptation of core's `FolderExplorer.folder_tree_node/1` for
`Spaces.list_tree/1` nodes: a single full-width column, no drag/drop, no
connector lines. Every field is read straight off the struct (`node.kind`,
`node.uuid`, `node.children`), never `node.space.kind`.

The consumer owns all state (`expanded` MapSet, `selected_uuid`,
`renaming_uuid`/`renaming_text`); every control fires back via
`phx-target={@myself}`. Pass `myself={nil}` from a plain LiveView and
`phx-target` is omitted. Consumers implement: `toggle_space_node`, `select_space`,
`start_rename_space`, `rename_space_input`, `rename_space`, `cancel_rename_space`,
`move_space_up`, `move_space_down`, `open_add_child`, `delete_space` (opens a
confirmation, never deletes by itself), `open_add_root`.

Reorder and rename are the only "immediate" actions. `delete_space` carries no
`data-confirm`; the confirmation with the descendant count is the consumer's.
`show_actions={false}` is picker mode: click-to-select and expand/collapse only,
the shape `PlacePicker` reuses.

## `PlacePicker`

A LiveComponent that picks a Location and optionally a Space inside it in one
widget: a search-combobox for the Location half (filtered in Elixir over
`Locations.list_locations/1`, locations being few) and `SpaceTree` in picker
mode for the Space half. The parent reacts to one message:

    {:place_picker_select, id, %{location_uuid: uuid, space_uuid: uuid_or_nil}}

`space_uuid` is `nil` when the user picks "Use this location (no specific
space)". The tree stays open after a selection so a different node can be
picked without re-searching.

Attrs: `:id` (required, echoed in every message); `:location_type_uuid`
(restricts the search to one type; resolve the uuid yourself via
`Locations.get_location_type_by_name/1`, the component does not resolve names);
`:selected_space_uuid` seeds the tree's **initial** highlight with seed-once
semantics (applied on first mount only, then tracked locally, and kept when the
seeded node is present in the newly loaded tree); `:selected_location_uuid` is
accepted for symmetry but not consumed; `:locale` translates Location names in
results and the heading (Space names inside the tree are not translated).

No production consumer is wired yet; `PlacePickerHarnessLive` in `test/support`
mounts it for the component tests.

## Per-Space attachments

Each Space's detail panel gets its own `Attachments` scope keyed by the Space
uuid, with the Space's `data` pointers as the resource. Folder names are
deterministic: `location-space-<uuid>` (`Attachments.folder_name_for/1`). The
Location itself uses scope `"location"` and folder `location-<uuid>`. See the
`PhoenixKitLocations.Attachments` moduledoc for the multi-scope pattern.
