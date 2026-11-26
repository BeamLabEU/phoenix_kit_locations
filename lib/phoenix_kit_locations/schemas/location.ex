defmodule PhoenixKitLocations.Schemas.Location do
  @moduledoc "Schema for locations."

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix
  use Gettext, backend: PhoenixKitLocations.Gettext
  import Ecto.Changeset

  alias PhoenixKitLocations.Geo
  alias PhoenixKitLocations.TranslatedData

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

    # Coordinates (WGS 84 decimal degrees, `numeric(9,6)`; V3). Both or
    # neither: a lone latitude is rejected. Typed by hand or filled by the
    # opt-in geocoder (`PhoenixKitLocations.Geocoding`).
    field(:latitude, :decimal)
    field(:longitude, :decimal)

    # Contact
    field(:phone, :string)
    field(:email, :string)
    field(:website, :string)

    # Internal
    field(:notes, :string)
    field(:status, :string, default: "active")

    # Owner (a `phoenix_kit_users` uuid — a person or an organization
    # account). `nil` is a global location. Deliberately NOT in the
    # `changeset/2` cast list: only `owner_changeset/2` sets it.
    field(:owner_uuid, UUIDv7)

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
  @address_fields [:address_line_1, :address_line_2, :city, :state, :postal_code, :country]
  @optional_fields [
    :description,
    :public_notes,
    :address_line_1,
    :address_line_2,
    :city,
    :state,
    :postal_code,
    :country,
    :latitude,
    :longitude,
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
    |> validate_length(:description, max: 2000)
    |> validate_length(:public_notes, max: 2000)
    |> validate_length(:notes, max: 5000)
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
    |> validate_coordinates()
    |> maybe_validate_email()
    |> maybe_validate_website()
    |> Geo.normalize_changeset()
    |> TranslatedData.normalize_changeset([:name, :description, :public_notes])
  end

  @doc """
  Changeset for a location's owner, kept apart from `changeset/2` so the
  general create/update path (and any form that forwards browser params into
  it) can never set it. Accepts a `Location` or an existing changeset;
  `owner_uuid` is a `phoenix_kit_users` uuid or `nil`. An unknown user comes
  back from the repo as an `:owner_uuid` error rather than a raise.
  """
  @spec owner_changeset(t() | Ecto.Changeset.t(), String.t() | nil) :: Ecto.Changeset.t()
  def owner_changeset(location_or_changeset, owner_uuid) do
    location_or_changeset
    |> cast(%{owner_uuid: owner_uuid}, [:owner_uuid])
    |> foreign_key_constraint(:owner_uuid)
  end

  @doc """
  The address fields a geocoder reads, in order. A change to any of them makes
  stored coordinates (and a queued geocode job) stale.
  """
  @spec address_fields() :: [atom()]
  def address_fields, do: @address_fields

  @doc """
  Changeset that writes only coordinates (the geocode job's write). Same range
  and both-or-neither rules as `changeset/2`.
  """
  @spec coordinates_changeset(t(), map()) :: Ecto.Changeset.t()
  def coordinates_changeset(location, attrs) do
    location
    |> cast(attrs, [:latitude, :longitude])
    |> validate_coordinates()
  end

  defp validate_coordinates(changeset) do
    changeset
    |> round_coordinate(:latitude)
    |> round_coordinate(:longitude)
    |> validate_number(:latitude,
      greater_than_or_equal_to: -90,
      less_than_or_equal_to: 90,
      message: gettext("must be between -90 and 90")
    )
    |> validate_number(:longitude,
      greater_than_or_equal_to: -180,
      less_than_or_equal_to: 180,
      message: gettext("must be between -180 and 180")
    )
    |> validate_coordinate_pair()
  end

  # The column is `numeric(9,6)`: round here so the struct a write returns
  # holds what the database stores.
  defp round_coordinate(changeset, field) do
    case get_change(changeset, field) do
      # Only a finite value of sane size: rounding a huge one (1e28) raises,
      # and the range check below rejects it anyway. The bound is loose so
      # 180.0000004 still rounds to 180 before the range check.
      %Decimal{} = value ->
        if Decimal.inf?(value) or Decimal.nan?(value) or
             Decimal.gt?(Decimal.abs(value), 1000),
           do: changeset,
           else: put_change(changeset, field, Decimal.round(value, 6))

      _ ->
        changeset
    end
  end

  defp validate_coordinate_pair(changeset) do
    case {get_field(changeset, :latitude), get_field(changeset, :longitude)} do
      {nil, nil} ->
        changeset

      {_, nil} ->
        add_error(changeset, :longitude, gettext("enter both latitude and longitude"))

      {nil, _} ->
        add_error(changeset, :latitude, gettext("enter both latitude and longitude"))

      _ ->
        changeset
    end
  end

  defp maybe_validate_email(changeset) do
    case get_field(changeset, :email) do
      nil ->
        changeset

      "" ->
        changeset

      _ ->
        validate_format(changeset, :email, ~r/@/,
          message: gettext("must be a valid email address")
        )
    end
  end

  defp maybe_validate_website(changeset) do
    case get_field(changeset, :website) do
      nil ->
        changeset

      "" ->
        changeset

      _ ->
        validate_format(changeset, :website, ~r/^https?:\/\//,
          message: gettext("must start with http:// or https://")
        )
    end
  end
end
