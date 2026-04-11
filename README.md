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
    {:phoenix_kit_locations, "~> 0.1"}
  ]
end
```

The module is auto-discovered by PhoenixKit — no manual router configuration needed. Run the PhoenixKit migrations to create the required database tables.

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

### Programmatic Access

All business logic lives in the `PhoenixKitLocations.Locations` context:

```elixir
alias PhoenixKitLocations.Locations

# Locations
Locations.list_locations()
Locations.create_location(%{name: "HQ", city: "Berlin", country: "DE"})
Locations.list_locations(status: :active, type_uuid: some_uuid)

# Location types
Locations.list_location_types()
Locations.create_location_type(%{name: "Office"})

# Type assignments
Locations.sync_location_types(location, [type_uuid_1, type_uuid_2])
Locations.has_type?(location, type_uuid)
```

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

All schemas use UUIDv7 primary keys. Tables are created by PhoenixKit migrations.

| Table | Description |
|-------|-------------|
| `phoenix_kit_locations` | Locations with address, contact, features, and multilang data |
| `phoenix_kit_location_types` | User-defined location categories |
| `phoenix_kit_location_type_assignments` | Many-to-many join table |

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
