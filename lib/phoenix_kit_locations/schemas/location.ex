defmodule PhoenixKitLocations.Schemas.Location do
  @moduledoc "Schema for locations."

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:uuid, UUIDv7, autogenerate: true}
  @foreign_key_type UUIDv7

  @statuses ~w(active inactive)

  schema "phoenix_kit_locations" do
    field(:name, :string)
    field(:description, :string)
    field(:public_notes, :string)

    # Address fields (international standard)
    field(:address_line_1, :string)
    field(:address_line_2, :string)
    field(:city, :string)
    field(:state, :string)
    field(:postal_code, :string)
    field(:country, :string)

    # Contact
    field(:phone, :string)
    field(:email, :string)
    field(:website, :string)

    # Internal
    field(:notes, :string)
    field(:status, :string, default: "active")

    # Features (wheelchair_accessible, elevator, parking, etc.)
    field(:features, :map, default: %{})

    # Multilang translations
    field(:data, :map, default: %{})

    has_many(:location_type_assignments, PhoenixKitLocations.Schemas.LocationTypeAssignment,
      foreign_key: :location_uuid,
      references: :uuid
    )

    has_many(:location_types, through: [:location_type_assignments, :location_type])

    timestamps(type: :utc_datetime)
  end

  @required_fields [:name]
  @optional_fields [
    :description,
    :public_notes,
    :address_line_1,
    :address_line_2,
    :city,
    :state,
    :postal_code,
    :country,
    :phone,
    :email,
    :website,
    :notes,
    :status,
    :features,
    :data
  ]

  def changeset(location, attrs) do
    location
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_length(:name, min: 1, max: 255)
    |> validate_length(:address_line_1, max: 500)
    |> validate_length(:address_line_2, max: 500)
    |> validate_length(:city, max: 255)
    |> validate_length(:state, max: 255)
    |> validate_length(:postal_code, max: 20)
    |> validate_length(:country, max: 255)
    |> validate_length(:phone, max: 50)
    |> validate_length(:email, max: 255)
    |> validate_length(:website, max: 500)
    |> validate_inclusion(:status, @statuses)
  end
end
