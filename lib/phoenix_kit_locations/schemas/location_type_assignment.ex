defmodule PhoenixKitLocations.Schemas.LocationTypeAssignment do
  @moduledoc "Join table for many-to-many between locations and location types."

  use Ecto.Schema

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  schema "phoenix_kit_location_type_assignments" do
    belongs_to(:location, PhoenixKitLocations.Schemas.Location,
      foreign_key: :location_uuid,
      references: :uuid,
      type: UUIDv7
    )

    belongs_to(:location_type, PhoenixKitLocations.Schemas.LocationType,
      foreign_key: :location_type_uuid,
      references: :uuid,
      type: UUIDv7
    )

    timestamps(type: :utc_datetime)
  end
end
