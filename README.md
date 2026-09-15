# PhoenixKitLocations

[![Hex.pm](https://img.shields.io/hexpm/v/phoenix_kit_locations.svg)](https://hex.pm/packages/phoenix_kit_locations)
[![License](https://img.shields.io/hexpm/l/phoenix_kit_locations.svg)](https://github.com/BeamLabEU/phoenix_kit_locations/blob/main/LICENSE)

Locations module for [PhoenixKit](https://github.com/BeamLabEU/phoenix_kit) — manage physical locations with custom types, multilingual fields, and a full admin interface.

## Features

- **Location management** — addresses, contact info, admin notes, active/inactive status
- **Custom location types** — user-defined categories (e.g. Showroom, Storage, Office) with many-to-many assignments
- **Translatable fields** — name, description, and public notes via PhoenixKit's Multilang system
- **Feature flags** — track amenities like wheelchair access, parking, wifi, and more
- **Duplicate detection** — warns when entering addresses that match existing locations
- **Admin dashboard** — LiveView pages for managing locations and types, auto-discovered by PhoenixKit

## Installation

Add `phoenix_kit_locations` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:phoenix_kit_locations, "~> 0.4"}
  ]
end
```

The module is auto-discovered by PhoenixKit — no manual router configuration needed. Run `mix phoenix_kit.update`: it applies core's migrations, then this module's own chain (`PhoenixKitLocations.Migrations`), generating a wrapper migration in your repo's migrations directory. Commit that file.

## Usage

### Admin Interface

Once installed, the admin dashboard adds a **Locations** tab with two subtabs:

- **Locations** — list, create, and edit locations
- **Types** — manage location types that can be assigned to locations

Routes are registered automatically:

| Path | Description |
|------|-------------|
| `/admin/locations` | Locations list |
| `/admin/locations/new` | Create location |
| `/admin/locations/:uuid/edit` | Edit location |
| `/admin/locations/types` | Types list |
| `/admin/locations/types/new` | Create type |
| `/admin/locations/types/:uuid/edit` | Edit type |

With `locations.manage_all`, the list shows each location's **Owner** and filters by All / Global / Owned, and the location form has an owner picker. Users with only `locations` see neither (see Permissions below).

### Permissions: own locations vs. all locations

A location can belong to a user (a person or an organization account). Without an owner it is global. The same `/admin/locations` pages serve both kinds of user:

| Permission | Grants |
|------------|--------|
| `locations` | The Locations pages, scoped to locations owned by the user or by the user's organization: list, create, edit, delete, Structure |
| `locations.manage_all` | Every location (owned or global), assigning owners, internal notes, attachments, and the Types pages |

**Organizations:** a person who belongs to an organization account shares that organization's locations with its other members, and the locations they create belong to the organization. Teammates at one company therefore see and manage the same warehouses. A person without an organization owns what they create.

Grant `locations` alone to a role (for example "Seller") so its users manage only their own (or their company's) sites; grant `locations.manage_all` as well to staff who manage everything. Admin receives both automatically, and Owner holds every permission.

⚠️ **Upgrading:** before this change, `locations` opened every location. A custom role that holds `locations` now sees only its own locations until it is also granted `locations.manage_all`. Admin and Owner are unaffected.

Deleting a user deletes the locations they own, with their spaces.

### Programmatic Access

All business logic lives in the `PhoenixKitLocations.Locations` context:

```elixir
alias PhoenixKitLocations.Locations

# Locations
Locations.list_locations()
Locations.create_location(%{name: "HQ", city: "Berlin", country: "DE"})
Locations.list_locations(status: "active", type_uuid: some_uuid)

# Location types
Locations.list_location_types()
Locations.create_location_type(%{name: "Office"})

# Type assignments (take location_uuid, not the struct)
Locations.sync_location_types(location.uuid, [type_uuid_1, type_uuid_2])
Locations.has_type?(location.uuid, type_uuid)

# Ownership — the owner is never taken from attrs, only from these calls
{:ok, site} = Locations.create_location(%{name: "North Depot"}, owner_uuid: user.uuid)
Locations.set_location_owner(site, other_user.uuid, actor_uuid: admin.uuid)  # or nil for global
Locations.list_locations(owner_uuid: user.uuid)   # only this owner's locations
Locations.list_locations(owner_uuid: PhoenixKitLocations.Policy.owner_uuids(user))  # a person + their organization
Locations.list_locations(owner_uuid: nil)         # only global locations
Locations.list_locations(owner_uuid: :any)        # every owned location
Locations.list_locations()                        # everything — never for tenant-facing pages
Locations.get_location_for_owner(uuid, user.uuid) # nil unless user owns it
```

`PlacePicker` takes the same filter as an attr and enforces it on selection. For a person and their organization, pass `owner_uuid={PhoenixKitLocations.Policy.owner_uuids(@phoenix_kit_current_scope)}`; leaving the attr out lists every location.

### Error Handling

Non-changeset errors returned by `PhoenixKitLocations.Locations` are atoms (`:location_not_found`, `:type_assignment_failed`, …). At the UI boundary, LiveViews translate them via `PhoenixKitLocations.Errors.message/1`, which wraps each mapping in `gettext` so flashes render in the user's locale.

```elixir
case Locations.delete_location(loc, actor_uuid: user.uuid) do
  {:ok, _} -> :ok
  {:error, _changeset} -> {:error, PhoenixKitLocations.Errors.message(:location_delete_failed)}
end
```

### Activity Logging

Every mutating context function logs a business-level activity to `PhoenixKit.Activity` when an `actor_uuid:` opt is passed. Logging is fire-and-forget — failures (e.g. host hasn't run core's V90 migration) never crash the primary operation. The action format is `"resource.verb"`: `location.created`, `location.updated`, `location.deleted`, `location.owner_changed`, `location.types_synced`, `location_type.created`, etc.

### Location Features

Locations support a set of boolean feature flags stored as a JSONB map:

`wheelchair_accessible`, `elevator`, `parking`, `public_transport`, `loading_dock`, `air_conditioning`, `wifi`, `restrooms`, `security`, `cctv`

```elixir
Locations.create_location(%{
  name: "Warehouse",
  features: %{"loading_dock" => true, "parking" => true, "cctv" => true}
})
```

## Database Schemas

All schemas use UUIDv7 primary keys. The tables belong to this module's versioned migration chain, `PhoenixKitLocations.Migrations` (version tracked as a `pkloc_schema:<N>` comment on `phoenix_kit_locations`). Core's baseline also still creates them on existing installs; V1 of the chain adopts those tables without changing their shape, and rolling the chain back never drops a table.

| Table | Description |
|-------|-------------|
| `phoenix_kit_locations` | Locations with address, contact, features, multilang data, and an optional `owner_uuid` (chain V2) |
| `phoenix_kit_location_types` | User-defined location categories |
| `phoenix_kit_location_type_assignments` | Many-to-many join table |
| `phoenix_kit_location_spaces` | Per-location tree of floors, rooms, zones, sections, aisles, shelves |

## Development

```bash
mix deps.get          # Install dependencies
mix test              # Run tests
mix precommit         # compile + format + credo + dialyzer
mix quality           # format + credo + dialyzer
mix quality.ci        # format --check-formatted + credo + dialyzer
```

## License

MIT — see [LICENSE](LICENSE) for details.
