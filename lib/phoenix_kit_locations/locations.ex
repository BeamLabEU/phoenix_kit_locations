defmodule PhoenixKitLocations.Locations do
  @moduledoc """
  Context module for managing locations and location types.

  Locations and types have a many-to-many relationship via a join table,
  so a location can be both a "Showroom" and "Storage" at the same time.

  Both locations and types use hard-delete only (simple reference data).
  """

  import Ecto.Query, warn: false

  alias PhoenixKitLocations.Schemas.{Location, LocationType, LocationTypeAssignment}

  defp repo, do: PhoenixKit.RepoHelper.repo()

  # ═══════════════════════════════════════════════════════════════════
  # Location Types
  # ═══════════════════════════════════════════════════════════════════

  @doc """
  Lists all location types, ordered by name.

  ## Options

    * `:status` — filter by status (e.g. `"active"`, `"inactive"`).
  """
  def list_location_types(opts \\ []) do
    query = from(t in LocationType, order_by: [asc: :name])

    query =
      case Keyword.get(opts, :status) do
        nil -> query
        status -> where(query, [t], t.status == ^status)
      end

    repo().all(query)
  end

  @doc "Fetches a location type by UUID. Returns `nil` if not found."
  def get_location_type(uuid), do: repo().get(LocationType, uuid)

  @doc "Fetches a location type by UUID. Raises `Ecto.NoResultsError` if not found."
  def get_location_type!(uuid), do: repo().get!(LocationType, uuid)

  def create_location_type(attrs) do
    %LocationType{}
    |> LocationType.changeset(attrs)
    |> repo().insert()
  end

  def update_location_type(%LocationType{} = location_type, attrs) do
    location_type
    |> LocationType.changeset(attrs)
    |> repo().update()
  end

  def delete_location_type(%LocationType{} = location_type) do
    repo().delete(location_type)
  end

  def change_location_type(%LocationType{} = location_type, attrs \\ %{}) do
    LocationType.changeset(location_type, attrs)
  end

  # ═══════════════════════════════════════════════════════════════════
  # Locations
  # ═══════════════════════════════════════════════════════════════════

  @doc """
  Lists all locations, ordered by name, with their types preloaded.

  ## Options

    * `:status` — filter by status (e.g. `"active"`, `"inactive"`).
  """
  def list_locations(opts \\ []) do
    query = from(l in Location, order_by: [asc: :name], preload: [:location_types])

    query =
      case Keyword.get(opts, :status) do
        nil -> query
        status -> where(query, [l], l.status == ^status)
      end

    repo().all(query)
  end

  @doc "Fetches a location by UUID with types preloaded. Returns `nil` if not found."
  def get_location(uuid) do
    case repo().get(Location, uuid) do
      nil -> nil
      location -> repo().preload(location, :location_types)
    end
  end

  @doc "Fetches a location by UUID with types preloaded. Raises if not found."
  def get_location!(uuid) do
    Location
    |> repo().get!(uuid)
    |> repo().preload(:location_types)
  end

  def create_location(attrs) do
    %Location{}
    |> Location.changeset(attrs)
    |> repo().insert()
  end

  def update_location(%Location{} = location, attrs) do
    location
    |> Location.changeset(attrs)
    |> repo().update()
  end

  def delete_location(%Location{} = location) do
    repo().delete(location)
  end

  def change_location(%Location{} = location, attrs \\ %{}) do
    Location.changeset(location, attrs)
  end

  # ═══════════════════════════════════════════════════════════════════
  # Location ↔ Type linking (many-to-many)
  # ═══════════════════════════════════════════════════════════════════

  @doc "Returns a list of type UUIDs linked to a location."
  def linked_type_uuids(location_uuid) do
    from(a in LocationTypeAssignment,
      where: a.location_uuid == ^location_uuid,
      select: a.location_type_uuid
    )
    |> repo().all()
  end

  @doc """
  Syncs the type assignments for a location.

  Replaces all existing assignments with the given list of type UUIDs.
  Wrapped in a transaction for atomicity.
  """
  def sync_location_types(location_uuid, type_uuids) do
    repo().transaction(fn ->
      from(a in LocationTypeAssignment, where: a.location_uuid == ^location_uuid)
      |> repo().delete_all()

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Enum.each(type_uuids, fn type_uuid ->
        repo().insert!(%LocationTypeAssignment{
          location_uuid: location_uuid,
          location_type_uuid: type_uuid,
          inserted_at: now,
          updated_at: now
        })
      end)
    end)
  end

  # ═══════════════════════════════════════════════════════════════════
  # Duplicate address detection
  # ═══════════════════════════════════════════════════════════════════

  @doc """
  Finds locations with the same address_line_1, city, and postal_code.

  Returns a list of matching locations, excluding the given `exclude_uuid`.
  Only checks if address_line_1 is non-empty.
  """
  def find_similar_addresses(address_line_1, city, postal_code, exclude_uuid \\ nil) do
    address_line_1 = (address_line_1 || "") |> String.trim()
    city = (city || "") |> String.trim()
    postal_code = (postal_code || "") |> String.trim()

    if address_line_1 == "" do
      []
    else
      query =
        from(l in Location,
          where:
            fragment("LOWER(TRIM(?))", l.address_line_1) ==
              ^String.downcase(address_line_1) and
              fragment("LOWER(TRIM(COALESCE(?, '')))", l.city) ==
                ^String.downcase(city) and
              fragment("LOWER(TRIM(COALESCE(?, '')))", l.postal_code) ==
                ^String.downcase(postal_code),
          select: %{uuid: l.uuid, name: l.name, address_line_1: l.address_line_1, city: l.city},
          limit: 5
        )

      query =
        if exclude_uuid,
          do: where(query, [l], l.uuid != ^exclude_uuid),
          else: query

      repo().all(query)
    end
  end
end
