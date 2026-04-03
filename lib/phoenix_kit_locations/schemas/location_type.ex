defmodule PhoenixKitLocations.Schemas.LocationType do
  @moduledoc "Schema for location types (e.g., Showroom, Storage, Office)."

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  @statuses ~w(active inactive)

  schema "phoenix_kit_location_types" do
    field(:name, :string)
    field(:description, :string)
    field(:status, :string, default: "active")
    field(:data, :map, default: %{})

    has_many(:location_type_assignments, PhoenixKitLocations.Schemas.LocationTypeAssignment,
      foreign_key: :location_type_uuid,
      references: :uuid
    )

    has_many(:locations, through: [:location_type_assignments, :location])

    timestamps(type: :utc_datetime)
  end

  @required_fields [:name]
  @optional_fields [:description, :status, :data]

  def changeset(location_type, attrs) do
    location_type
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:name, min: 1, max: 255)
    |> validate_inclusion(:status, @statuses)
  end
end
