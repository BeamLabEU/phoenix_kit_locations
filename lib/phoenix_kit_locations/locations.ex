defmodule PhoenixKitLocations.Locations do
  @moduledoc """
  Context module for managing locations and location types.

  Locations and types have a many-to-many relationship via a join table,
  so a location can be both a "Showroom" and "Storage" at the same time.

  Both locations and types use hard-delete only (simple reference data).

  ## Activity logging

  Every mutating function accepts `opts \\ []`. When `actor_uuid:` is
  present in opts, the mutation is logged via `PhoenixKit.Activity.log/1`
  under the `"locations"` module key. Logging failures never crash the
  primary operation — the helper rescues and falls back to
  `Logger.warning`.

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

  @type opts :: keyword()
  @type status_filter :: [status: String.t()]
  @typedoc "`owner_uuid:` filter value — an owner's uuid, `nil` (unowned only) or `:any` (owned by anyone)."
  @type owner_filter :: String.t() | [String.t()] | nil | :any
  @type list_locations_opts :: [
          status: String.t(),
          type_uuid: String.t(),
          owner_uuid: owner_filter()
        ]

  defp repo, do: PhoenixKit.RepoHelper.repo()

  # ═══════════════════════════════════════════════════════════════════
  # Location Types
  # ═══════════════════════════════════════════════════════════════════

  @doc """
  Lists all location types, ordered by name.

  ## Options

    * `:status` — filter by status (e.g. `"active"`, `"inactive"`).
  """
  @spec list_location_types(status_filter) :: [LocationType.t()]
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
  @spec get_location_type(String.t()) :: LocationType.t() | nil
  def get_location_type(uuid), do: repo().get(LocationType, uuid)

  @doc "Fetches a location type by name (case-sensitive). Returns `nil` if not found."
  @spec get_location_type_by_name(String.t()) :: LocationType.t() | nil
  def get_location_type_by_name(name) do
    repo().get_by(LocationType, name: name)
  end

  @doc "Returns the total count of location types."
  @spec count_location_types(status_filter) :: non_neg_integer()
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
  @spec create_location_type(map(), opts) ::
          {:ok, LocationType.t()} | {:error, Ecto.Changeset.t()}
  def create_location_type(attrs, opts \\ []) do
    %LocationType{}
    |> LocationType.changeset(attrs)
    |> repo().insert()
    |> log_activity("location_type.created", "location_type", opts, &type_metadata/1)
  end

  @doc "Updates a location type with the given attributes."
  @spec update_location_type(LocationType.t(), map(), opts) ::
          {:ok, LocationType.t()} | {:error, Ecto.Changeset.t()}
  def update_location_type(%LocationType{} = location_type, attrs, opts \\ []) do
    location_type
    |> LocationType.changeset(attrs)
    |> repo().update()
    |> log_activity("location_type.updated", "location_type", opts, &type_metadata/1)
  end

  @doc "Hard-deletes a location type. Cascades to type assignments (locations keep existing, just lose the link)."
  @spec delete_location_type(LocationType.t(), opts) ::
          {:ok, LocationType.t()} | {:error, Ecto.Changeset.t()}
  def delete_location_type(%LocationType{} = location_type, opts \\ []) do
    location_type
    |> repo().delete()
    |> log_activity("location_type.deleted", "location_type", opts, &type_metadata/1)
  end

  @doc "Returns an `Ecto.Changeset` for tracking location type changes."
  @spec change_location_type(LocationType.t(), map()) :: Ecto.Changeset.t()
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
    * `:owner_uuid` — ownership filter. A user uuid returns only that owner's
      locations; a list of uuids returns locations owned by any of them (for
      example a person and their organization, `Policy.owner_uuids/1`; an
      empty list returns nothing); `nil` returns only unowned (global) locations; `:any` returns
      every owned location. **Omitting the option returns every location**,
      owned or not — so a tenant-facing caller must always pass it. A `nil`
      that reaches this option by mistake fails closed (global rows only),
      never open.

  All filters compose.
  """
  @spec list_locations(list_locations_opts) :: [Location.t()]
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

    query
    |> filter_owner(opts)
    |> repo().all()
  end

  @doc "Fetches a location by UUID with types preloaded. Returns `nil` if not found."
  @spec get_location(String.t()) :: Location.t() | nil
  def get_location(uuid) do
    case repo().get(Location, uuid) do
      nil -> nil
      location -> repo().preload(location, :location_types)
    end
  end

  @doc """
  Fetches a location by UUID only when it belongs to `owner_uuid` (one uuid, or
  a list meaning any of them), with types preloaded. Returns `nil` when the
  location does not exist, belongs to someone else, is unowned, or the uuids
  are malformed or empty.

  This is the lookup for anything tenant-facing: a user-supplied uuid never
  resolves to another owner's location.
  """
  @spec get_location_for_owner(String.t() | nil, String.t() | [String.t()] | nil) ::
          Location.t() | nil
  def get_location_for_owner(uuid, owner_uuid) when is_binary(uuid) and is_binary(owner_uuid),
    do: get_location_for_owner(uuid, [owner_uuid])

  def get_location_for_owner(uuid, owner_uuids) when is_binary(uuid) and is_list(owner_uuids) do
    owners =
      for owner <- owner_uuids, is_binary(owner), {:ok, cast} <- [Ecto.UUID.cast(owner)], do: cast

    with {:ok, uuid} <- Ecto.UUID.cast(uuid),
         [_ | _] <- owners,
         %Location{} = location <-
           repo().one(from(l in Location, where: l.uuid == ^uuid and l.owner_uuid in ^owners)) do
      repo().preload(location, :location_types)
    else
      _ -> nil
    end
  end

  def get_location_for_owner(_uuid, _owner_uuid), do: nil

  @doc """
  Fetches a location by a field value. Returns `nil` if not found.

  Only safe field names are accepted — unknown fields raise `ArgumentError`.

  ## Examples

      Locations.get_location_by(:name, "Main Office")
      Locations.get_location_by(:email, "hq@example.com")
  """
  @spec get_location_by(:name | :email | :phone, String.t()) :: Location.t() | nil
  def get_location_by(field, value) when field in [:name, :email, :phone] do
    case repo().get_by(Location, [{field, value}]) do
      nil -> nil
      location -> repo().preload(location, :location_types)
    end
  end

  @doc """
  Returns the total count of locations.

  Accepts `:status` and `:owner_uuid` with the same meaning as
  `list_locations/1`.
  """
  @spec count_locations(status: String.t(), owner_uuid: owner_filter()) :: non_neg_integer()
  def count_locations(opts \\ []) do
    query = from(l in Location, select: count(l.uuid))

    query =
      case Keyword.get(opts, :status) do
        nil -> query
        status -> where(query, [l], l.status == ^status)
      end

    query
    |> filter_owner(opts)
    |> repo().one()
  end

  @doc """
  Creates a location.

  Required: `:name`. Optional: `:description`, `:public_notes`, `:address_line_1`,
  `:address_line_2`, `:city`, `:state`, `:postal_code`, `:country`, `:phone`,
  `:email`, `:website`, `:notes`, `:status`, `:features`, `:data`.

  The owner never comes from `attrs`, even when they carry an `owner_uuid`
  key: pass `owner_uuid:` in `opts` (a `phoenix_kit_users` uuid, or `nil` for
  a global location). A form that forwards browser params therefore cannot
  assign the new location to somebody else.
  """
  @spec create_location(map(), opts) :: {:ok, Location.t()} | {:error, Ecto.Changeset.t()}
  def create_location(attrs, opts \\ []) do
    %Location{}
    |> Location.changeset(attrs)
    |> maybe_put_owner(opts)
    |> repo().insert()
    |> log_activity("location.created", "location", opts, &location_metadata/1)
  end

  @doc "Updates a location with the given attributes. Never changes the owner — see `set_location_owner/3`."
  @spec update_location(Location.t(), map(), opts) ::
          {:ok, Location.t()} | {:error, Ecto.Changeset.t()}
  def update_location(%Location{} = location, attrs, opts \\ []) do
    location
    |> Location.changeset(attrs)
    |> repo().update()
    |> log_activity("location.updated", "location", opts, &location_metadata/1)
  end

  @doc "Hard-deletes a location. Cascades to type assignments."
  @spec delete_location(Location.t(), opts) :: {:ok, Location.t()} | {:error, Ecto.Changeset.t()}
  def delete_location(%Location{} = location, opts \\ []) do
    location
    |> repo().delete()
    |> log_activity("location.deleted", "location", opts, &location_metadata/1)
  end

  @doc "Returns an `Ecto.Changeset` for tracking location changes."
  @spec change_location(Location.t(), map()) :: Ecto.Changeset.t()
  def change_location(%Location{} = location, attrs \\ %{}) do
    Location.changeset(location, attrs)
  end

  @doc """
  Sets or clears a location's owner. `owner_uuid` is a `phoenix_kit_users`
  uuid (a person or an organization account), or `nil` to make the location
  global.

  Logs `location.owner_changed` (`owner_from` / `owner_to`) when the owner
  actually changes. Setting the current owner again is a no-op: it returns
  `{:ok, location}` with no write and no log entry. An unknown user or a
  malformed uuid comes back as `{:error, changeset}` with an `:owner_uuid`
  error.
  """
  @spec set_location_owner(Location.t(), String.t() | nil, opts) ::
          {:ok, Location.t()} | {:error, Ecto.Changeset.t()}
  def set_location_owner(%Location{} = location, owner_uuid, opts \\ []) do
    changeset = Location.owner_changeset(location, owner_uuid)

    if changeset.valid? and changeset.changes == %{} do
      {:ok, location}
    else
      changeset
      |> repo().update()
      |> log_activity("location.owner_changed", "location", opts, fn updated ->
        %{
          "name" => updated.name,
          "owner_from" => location.owner_uuid,
          "owner_to" => updated.owner_uuid
        }
      end)
    end
  end

  # ═══════════════════════════════════════════════════════════════════
  # Location ↔ Type linking (many-to-many)
  # ═══════════════════════════════════════════════════════════════════

  @doc "Returns a list of type UUIDs linked to a location."
  @spec linked_type_uuids(String.t()) :: [String.t()]
  def linked_type_uuids(location_uuid) do
    from(a in LocationTypeAssignment,
      where: a.location_uuid == ^location_uuid,
      select: a.location_type_uuid
    )
    |> repo().all()
  end

  @doc "Returns a list of `LocationType` structs linked to a location."
  @spec linked_types(String.t()) :: [LocationType.t()]
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

  Logs `location.types_synced` only when the assignment set actually
  changed; a no-op sync is silent.
  """
  @spec sync_location_types(String.t(), [String.t()], opts) ::
          {:ok, :synced | :unchanged} | {:error, :type_assignment_failed}
  def sync_location_types(location_uuid, type_uuids, opts \\ []) do
    before_set = MapSet.new(linked_type_uuids(location_uuid))
    after_set = MapSet.new(type_uuids)

    if MapSet.equal?(before_set, after_set) do
      {:ok, :unchanged}
    else
      result =
        repo().transaction(fn ->
          from(a in LocationTypeAssignment, where: a.location_uuid == ^location_uuid)
          |> repo().delete_all()

          now = DateTime.utc_now() |> DateTime.truncate(:second)
          Enum.each(type_uuids, &insert_type_assignment!(location_uuid, &1, now))
          :synced
        end)

      case result do
        {:ok, :synced} ->
          maybe_log_activity("location.types_synced", "location", location_uuid, opts, %{
            "types_from" => MapSet.to_list(before_set),
            "types_to" => MapSet.to_list(after_set)
          })

          {:ok, :synced}

        {:error, reason} ->
          maybe_log_activity("location.types_synced", "location", location_uuid, opts, %{
            "db_pending" => true,
            "reason" => inspect(reason),
            "types_from" => MapSet.to_list(before_set),
            "types_to" => MapSet.to_list(after_set)
          })

          {:error, reason}
      end
    end
  end

  defp insert_type_assignment!(location_uuid, type_uuid, now) do
    changeset =
      LocationTypeAssignment.changeset(%LocationTypeAssignment{}, %{
        location_uuid: location_uuid,
        location_type_uuid: type_uuid,
        inserted_at: now,
        updated_at: now
      })

    case repo().insert(changeset) do
      {:ok, _} ->
        :ok

      {:error, %Ecto.Changeset{} = cs} ->
        Logger.error(
          "Failed to assign type #{type_uuid} to location #{location_uuid} (error count: #{length(cs.errors)})"
        )

        repo().rollback(:type_assignment_failed)
    end
  end

  @doc """
  Adds a single type to a location. No-op if already assigned.

  Returns `{:ok, assignment}` or `{:error, changeset}`.
  """
  @spec add_location_type(String.t(), String.t(), opts) ::
          {:ok, LocationTypeAssignment.t()} | {:error, Ecto.Changeset.t()}
  def add_location_type(location_uuid, type_uuid, opts \\ []) do
    existing =
      from(a in LocationTypeAssignment,
        where: a.location_uuid == ^location_uuid and a.location_type_uuid == ^type_uuid
      )
      |> repo().one()

    if existing do
      {:ok, existing}
    else
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      result =
        %LocationTypeAssignment{}
        |> LocationTypeAssignment.changeset(%{
          location_uuid: location_uuid,
          location_type_uuid: type_uuid,
          inserted_at: now,
          updated_at: now
        })
        |> repo().insert()

      case result do
        {:ok, _assignment} = ok ->
          maybe_log_activity("location.type_added", "location", location_uuid, opts, %{
            "type_uuid" => type_uuid
          })

          ok

        {:error, %Ecto.Changeset{} = changeset} = error ->
          maybe_log_activity("location.type_added", "location", location_uuid, opts, %{
            "db_pending" => true,
            "type_uuid" => type_uuid,
            "error_fields" =>
              changeset.errors |> Enum.map(fn {field, _} -> to_string(field) end) |> Enum.uniq()
          })

          error

        error ->
          error
      end
    end
  end

  @doc """
  Removes a single type from a location. No-op if not assigned.

  Returns `{:ok, count}` where count is 0 or 1.
  """
  @spec remove_location_type(String.t(), String.t(), opts) :: {:ok, 0 | 1}
  def remove_location_type(location_uuid, type_uuid, opts \\ []) do
    {count, _} =
      from(a in LocationTypeAssignment,
        where: a.location_uuid == ^location_uuid and a.location_type_uuid == ^type_uuid
      )
      |> repo().delete_all()

    if count > 0 do
      maybe_log_activity("location.type_removed", "location", location_uuid, opts, %{
        "type_uuid" => type_uuid
      })
    end

    {:ok, count}
  end

  @doc "Returns true if the location has the given type assigned."
  @spec has_type?(String.t(), String.t()) :: boolean()
  def has_type?(location_uuid, type_uuid) do
    query =
      from(a in LocationTypeAssignment,
        where: a.location_uuid == ^location_uuid and a.location_type_uuid == ^type_uuid,
        select: true
      )

    repo().one(query) == true
  end

  # ═══════════════════════════════════════════════════════════════════
  # Duplicate address detection
  # ═══════════════════════════════════════════════════════════════════

  @doc """
  Finds locations with the same address_line_1, city, and postal_code.

  Returns a list of matching locations, excluding the given `exclude_uuid`.
  Only checks if address_line_1 is non-empty. Returns `[]` on any error
  (with the error logged — treated as a soft-fail so the form still saves).

  ## Options

    * `:owner_uuid` — same meaning as in `list_locations/1`; omitted checks
      every location. Tenant-facing pages pass the current user's uuid, so the
      warning can never name another owner's location.
  """
  @spec find_similar_addresses(
          String.t() | nil,
          String.t() | nil,
          String.t() | nil,
          String.t() | nil,
          owner_uuid: owner_filter()
        ) :: [map()]
  def find_similar_addresses(address_line_1, city, postal_code, exclude_uuid \\ nil, opts \\ []) do
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

      query
      |> filter_owner(opts)
      |> repo().all()
    end
  rescue
    error ->
      Logger.warning("find_similar_addresses failed: #{Exception.message(error)}")
      []
  end

  # ═══════════════════════════════════════════════════════════════════
  # Ownership helpers
  # ═══════════════════════════════════════════════════════════════════

  # `Keyword.fetch/2`, not `Keyword.get/2`: an omitted option means "no
  # filter", while an explicit `nil` means "unowned only".
  defp filter_owner(query, opts) do
    case Keyword.fetch(opts, :owner_uuid) do
      :error ->
        query

      {:ok, nil} ->
        where(query, [l], is_nil(l.owner_uuid))

      {:ok, :any} ->
        where(query, [l], not is_nil(l.owner_uuid))

      {:ok, owner_uuid} when is_binary(owner_uuid) ->
        where(query, [l], l.owner_uuid == ^owner_uuid)

      {:ok, owner_uuids} when is_list(owner_uuids) ->
        where(query, [l], l.owner_uuid in ^owner_uuids)
    end
  end

  defp maybe_put_owner(changeset, opts) do
    case Keyword.fetch(opts, :owner_uuid) do
      {:ok, owner_uuid} -> Location.owner_changeset(changeset, owner_uuid)
      :error -> changeset
    end
  end

  # ═══════════════════════════════════════════════════════════════════
  # Activity logging helpers
  # ═══════════════════════════════════════════════════════════════════

  # Pipe-step: logs on {:ok, struct} with full metadata; on
  # {:error, changeset} logs a `db_pending: true` audit row so the
  # user-initiated action survives even when the primary write fails
  # (e.g. unique-constraint violation, FK rollback). Passes the
  # original tuple through unchanged.
  defp log_activity({:ok, %mod{} = record} = ok, action, resource_type, opts, metadata_fun)
       when is_function(metadata_fun, 1) do
    maybe_log_activity(
      action,
      resource_type,
      struct_uuid(record, mod),
      opts,
      metadata_fun.(record)
    )

    ok
  end

  defp log_activity(
         {:error, %Ecto.Changeset{} = changeset} = err,
         action,
         resource_type,
         opts,
         _metadata_fun
       ) do
    maybe_log_activity(
      action,
      resource_type,
      changeset_resource_uuid(changeset),
      opts,
      changeset_error_metadata(changeset)
    )

    err
  end

  defp log_activity({:error, _} = err, _action, _resource_type, _opts, _metadata_fun), do: err

  # Low-level: fire-and-forget log, guarded so it never crashes callers.
  defp maybe_log_activity(action, resource_type, resource_uuid, opts, metadata) do
    if Code.ensure_loaded?(PhoenixKit.Activity) do
      PhoenixKit.Activity.log(%{
        action: action,
        module: "locations",
        mode: Keyword.get(opts, :mode, "manual"),
        actor_uuid: Keyword.get(opts, :actor_uuid),
        resource_type: resource_type,
        resource_uuid: resource_uuid,
        metadata: metadata
      })
    end

    :ok
  rescue
    e in Postgrex.Error ->
      # Host hasn't run core's activity migration — swallow silently.
      if match?(%{postgres: %{code: :undefined_table}}, e) do
        :ok
      else
        Logger.warning("[Locations] Activity log failed: #{Exception.message(e)}")
        :ok
      end

    e ->
      Logger.warning("[Locations] Activity log error: #{Exception.message(e)}")
      :ok
  end

  defp struct_uuid(record, _mod), do: Map.get(record, :uuid)

  # On {:error, changeset} the record may not have a UUID yet (insert
  # failed) — fall back to the changeset's data UUID, which exists
  # for updates and is `nil` for inserts.
  defp changeset_resource_uuid(%Ecto.Changeset{data: data}), do: Map.get(data, :uuid)

  # PII-safe changeset metadata: invalid field names + a db_pending
  # marker. Never includes the rejected values themselves — only the
  # field set + which fields had errors.
  defp changeset_error_metadata(%Ecto.Changeset{errors: errors}) do
    %{
      "db_pending" => true,
      "error_fields" => errors |> Enum.map(fn {field, _} -> to_string(field) end) |> Enum.uniq()
    }
  end

  defp location_metadata(%Location{} = l) do
    %{
      "name" => l.name,
      "city" => l.city,
      "status" => l.status,
      "owner_uuid" => l.owner_uuid
    }
  end

  defp type_metadata(%LocationType{} = t) do
    %{
      "name" => t.name,
      "status" => t.status
    }
  end

  @doc """
  Writes a `location.deleted` activity entry (`mode: "auto"`, metadata
  `"reason" => "owner_deleted"`) for every location `owner_uuid` owns.

  Called from `PhoenixKitLocations.before_user_delete/1`, before core deletes
  the user row and the `owner_uuid` foreign key cascades those locations (with
  their type assignments and space trees) away — the database cascade itself
  leaves no trace. Best-effort: never raises.
  """
  @spec log_owner_deletion(String.t() | nil) :: :ok
  def log_owner_deletion(owner_uuid) when is_binary(owner_uuid) do
    from(l in Location, where: l.owner_uuid == ^owner_uuid)
    |> repo().all()
    |> Enum.each(fn location ->
      maybe_log_activity(
        "location.deleted",
        "location",
        location.uuid,
        [mode: "auto"],
        Map.put(location_metadata(location), "reason", "owner_deleted")
      )
    end)

    :ok
  rescue
    error ->
      Logger.warning("[Locations] owner deletion logging failed: #{Exception.message(error)}")
      :ok
  end

  def log_owner_deletion(_owner_uuid), do: :ok

  @doc """
  Logs a module enable/disable toggle. Called from the `enable_system` /
  `disable_system` module lifecycle functions.
  """
  @spec log_module_toggle(:enabled | :disabled, opts) :: :ok
  def log_module_toggle(state, opts \\ []) when state in [:enabled, :disabled] do
    maybe_log_activity(
      "locations_module.#{state}",
      "module",
      nil,
      opts,
      %{"module_key" => "locations"}
    )
  end
end
