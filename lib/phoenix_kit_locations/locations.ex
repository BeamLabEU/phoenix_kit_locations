defmodule PhoenixKitLocations.Locations do
  @moduledoc """
  Context module for managing locations and location types.

  Locations and types have a many-to-many relationship via a join table,
  so a location can be both a "Showroom" and "Storage" at the same time.

  Both locations and types use hard-delete only (simple reference data).

  ## Usage from IEx

      alias PhoenixKitLocations.Locations

      # Types
      {:ok, showroom} = Locations.create_location_type(%{name: "Showroom"})
      {:ok, storage} = Locations.create_location_type(%{name: "Storage"})

      # Locations
      {:ok, loc} = Locations.create_location(%{name: "HQ", address_line_1: "123 Main St"})

      # Assign types
      {:ok, _} = Locations.sync_location_types(loc.uuid, [showroom.uuid, storage.uuid])

      # Or add/remove individually
      {:ok, _} = Locations.add_location_type(loc.uuid, showroom.uuid)
      {:ok, _} = Locations.remove_location_type(loc.uuid, storage.uuid)

      # Query
      Locations.list_locations(type_uuid: showroom.uuid)
      Locations.count_locations()
      Locations.get_location_by(:name, "HQ")
  """

  import Ecto.Query, warn: false

  require Logger

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

  @doc "Fetches a location type by name (case-sensitive). Returns `nil` if not found."
  def get_location_type_by_name(name) do
    repo().get_by(LocationType, name: name)
  end

  @doc "Returns the total count of location types."
  def count_location_types(opts \\ []) do
    query = from(t in LocationType, select: count(t.uuid))

    query =
      case Keyword.get(opts, :status) do
        nil -> query
        status -> where(query, [t], t.status == ^status)
      end

    repo().one(query)
  end

  @doc "Creates a location type. Required: `:name`. Optional: `:description`, `:status`, `:data`."
  def create_location_type(attrs) do
    %LocationType{}
    |> LocationType.changeset(attrs)
    |> repo().insert()
  end

  @doc "Updates a location type with the given attributes."
  def update_location_type(%LocationType{} = location_type, attrs) do
    location_type
    |> LocationType.changeset(attrs)
    |> repo().update()
  end

  @doc "Hard-deletes a location type. Cascades to type assignments (locations keep existing, just lose the link)."
  def delete_location_type(%LocationType{} = location_type) do
    repo().delete(location_type)
  end

  @doc "Returns an `Ecto.Changeset` for tracking location type changes."
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
    * `:type_uuid` — filter to only locations that have this type assigned.
  """
  def list_locations(opts \\ []) do
    query = from(l in Location, order_by: [asc: :name], preload: [:location_types])

    query =
      case Keyword.get(opts, :status) do
        nil -> query
        status -> where(query, [l], l.status == ^status)
      end

    query =
      case Keyword.get(opts, :type_uuid) do
        nil ->
          query

        type_uuid ->
          from(l in query,
            join: a in LocationTypeAssignment,
            on: a.location_uuid == l.uuid,
            where: a.location_type_uuid == ^type_uuid
          )
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

  @doc """
  Fetches a location by a field value. Returns `nil` if not found.

  ## Examples

      Locations.get_location_by(:name, "Main Office")
      Locations.get_location_by(:email, "hq@example.com")
  """
  def get_location_by(field, value) when is_atom(field) do
    case repo().get_by(Location, [{field, value}]) do
      nil -> nil
      location -> repo().preload(location, :location_types)
    end
  end

  @doc "Returns the total count of locations."
  def count_locations(opts \\ []) do
    query = from(l in Location, select: count(l.uuid))

    query =
      case Keyword.get(opts, :status) do
        nil -> query
        status -> where(query, [l], l.status == ^status)
      end

    repo().one(query)
  end

  @doc """
  Creates a location.

  Required: `:name`. Optional: `:description`, `:public_notes`, `:address_line_1`,
  `:address_line_2`, `:city`, `:state`, `:postal_code`, `:country`, `:phone`,
  `:email`, `:website`, `:notes`, `:status`, `:features`, `:data`.
  """
  def create_location(attrs) do
    %Location{}
    |> Location.changeset(attrs)
    |> repo().insert()
  end

  @doc "Updates a location with the given attributes."
  def update_location(%Location{} = location, attrs) do
    location
    |> Location.changeset(attrs)
    |> repo().update()
  end

  @doc "Hard-deletes a location. Cascades to type assignments."
  def delete_location(%Location{} = location) do
    repo().delete(location)
  end

  @doc "Returns an `Ecto.Changeset` for tracking location changes."
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

  @doc "Returns a list of `LocationType` structs linked to a location."
  def linked_types(location_uuid) do
    from(t in LocationType,
      join: a in LocationTypeAssignment,
      on: a.location_type_uuid == t.uuid,
      where: a.location_uuid == ^location_uuid,
      order_by: [asc: t.name]
    )
    |> repo().all()
  end

  @doc """
  Syncs the type assignments for a location (full replace).

  Replaces all existing assignments with the given list of type UUIDs.
  Wrapped in a transaction for atomicity — if any insert fails, all
  changes are rolled back (existing assignments preserved).
  """
  def sync_location_types(location_uuid, type_uuids) do
    repo().transaction(fn ->
      from(a in LocationTypeAssignment, where: a.location_uuid == ^location_uuid)
      |> repo().delete_all()

      now = DateTime.utc_now() |> DateTime.truncate(:second)
      Enum.each(type_uuids, &insert_type_assignment!(location_uuid, &1, now))
    end)
  end

  defp insert_type_assignment!(location_uuid, type_uuid, now) do
    case repo().insert(%LocationTypeAssignment{
           location_uuid: location_uuid,
           location_type_uuid: type_uuid,
           inserted_at: now,
           updated_at: now
         }) do
      {:ok, _} ->
        :ok

      {:error, changeset} ->
        Logger.error(
          "Failed to assign type #{type_uuid} to location #{location_uuid}: #{inspect(changeset.errors)}"
        )

        repo().rollback(:type_assignment_failed)
    end
  end

  @doc """
  Adds a single type to a location. No-op if already assigned.

  Returns `{:ok, assignment}` or `{:error, changeset}`.
  """
  def add_location_type(location_uuid, type_uuid) do
    existing =
      from(a in LocationTypeAssignment,
        where: a.location_uuid == ^location_uuid and a.location_type_uuid == ^type_uuid
      )
      |> repo().one()

    if existing do
      {:ok, existing}
    else
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      repo().insert(%LocationTypeAssignment{
        location_uuid: location_uuid,
        location_type_uuid: type_uuid,
        inserted_at: now,
        updated_at: now
      })
    end
  end

  @doc """
  Removes a single type from a location. No-op if not assigned.

  Returns `{:ok, count}` where count is 0 or 1.
  """
  def remove_location_type(location_uuid, type_uuid) do
    {count, _} =
      from(a in LocationTypeAssignment,
        where: a.location_uuid == ^location_uuid and a.location_type_uuid == ^type_uuid
      )
      |> repo().delete_all()

    {:ok, count}
  end

  @doc "Returns true if the location has the given type assigned."
  def has_type?(location_uuid, type_uuid) do
    from(a in LocationTypeAssignment,
      where: a.location_uuid == ^location_uuid and a.location_type_uuid == ^type_uuid,
      select: true
    )
    |> repo().one()
    |> Kernel.==(true)
  end

  # ═══════════════════════════════════════════════════════════════════
  # Duplicate address detection
  # ═══════════════════════════════════════════════════════════════════

  @doc """
  Finds locations with the same address_line_1, city, and postal_code.

  Returns a list of matching locations, excluding the given `exclude_uuid`.
  Only checks if address_line_1 is non-empty. Returns `[]` on any error.
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
  rescue
    error ->
      Logger.error("Failed to check similar addresses: #{inspect(error)}")
      []
  end
end
