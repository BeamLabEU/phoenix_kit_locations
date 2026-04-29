defmodule PhoenixKitLocations.Schemas.LocationTypeAssignment do
  @moduledoc "Join table for many-to-many between locations and location types."

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

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

  @doc """
  Builds an insert changeset for a location ↔ type assignment.

  Casts the two FK columns + timestamps and wires `assoc_constraint/2`
  on both `:location` and `:location_type` so an FK violation comes
  back as a clean `{:error, changeset}` instead of an
  `Ecto.ConstraintError` raise. Without these the Batch 3a `:error`-branch
  activity-logging code would never fire.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(assignment, attrs) do
    assignment
    |> cast(attrs, [:location_uuid, :location_type_uuid, :inserted_at, :updated_at])
    |> validate_required([:location_uuid, :location_type_uuid])
    |> assoc_constraint(:location)
    |> assoc_constraint(:location_type)
  end
end
