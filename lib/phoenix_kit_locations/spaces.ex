defmodule PhoenixKitLocations.Spaces do
  @moduledoc """
  Context for nested spaces under a Location — rooms, floors, zones,
  etc. forming a per-location tree.

  ## Same-Location parent invariant

  A space's `parent_uuid` (when set) must reference another space in
  the **same** Location. The DB doesn't enforce this directly — a
  composite FK on `(parent_uuid, location_uuid)` would, but it's
  heavier than the consumer surface justifies. We guard at the
  context boundary instead: `create_space/2` and `update_space/3`
  reject any cross-location parent with `{:error, :parent_in_other_location}`.

  ## Cycle prevention

  Direct self-loop is caught by the schema changeset. Indirect cycles
  (A → B → A) are blocked here in `validate_no_cycle/3` before any
  `parent_uuid` change is persisted: the new parent's ancestors come from
  one recursive query (`PhoenixKit.Utils.TreeQuery`, no depth cap), read
  under the location's tree lock, so two re-parents in opposite
  directions cannot both pass.

  ## Activity logging

  Mutating functions accept `opts \\ []` and forward `:actor_uuid`
  for the activity log, written through core's `PhoenixKit.Activity.log/3`,
  which never raises — logging never crashes the mutation.

  Parity with `Locations`:
  - `{:ok, space}` — logs with space metadata, same as `Locations`.
  - `{:error, %Ecto.Changeset{}}` — logs a `db_pending: true` audit row, same as `Locations`.
  - `{:error, atom}` (`:cycle`, `:parent_in_other_location`, `:parent_not_found`,
    `:location_not_found`) — **not logged**: these rejections carry no changeset or
    resource UUID to attach to, so no partial audit row is written.
  """

  import Ecto.Query, warn: false

  alias PhoenixKit.Utils.Multilang
  alias PhoenixKit.Utils.TreeQuery
  alias PhoenixKitLocations.Locations
  alias PhoenixKitLocations.Schemas.Location
  alias PhoenixKitLocations.Schemas.Space

  @type opts :: keyword()
  @type uuid :: String.t()

  defp repo, do: PhoenixKit.RepoHelper.repo()

  # ═══════════════════════════════════════════════════════════════════
  # Reads
  # ═══════════════════════════════════════════════════════════════════

  @doc """
  All spaces for a Location, ordered by (parent_uuid, position).
  Returns a flat list; use `list_tree/1` for a nested shape.
  """
  @spec list_for_location(uuid) :: [Space.t()]
  def list_for_location(location_uuid) when is_binary(location_uuid) do
    from(s in Space,
      where: s.location_uuid == ^location_uuid,
      order_by: [asc_nulls_first: s.parent_uuid, asc: s.position, asc: s.inserted_at]
    )
    |> repo().all()
  end

  @doc """
  Nested tree of spaces for a Location. Each node carries a `:children`
  key as a list (empty for leaves). Root-level nodes have `parent_uuid == nil`.

  Single DB read — the tree is assembled in memory from the flat list.
  """
  @spec list_tree(uuid) :: [map()]
  def list_tree(location_uuid) when is_binary(location_uuid) do
    spaces = list_for_location(location_uuid)
    by_parent = Enum.group_by(spaces, & &1.parent_uuid)
    build_tree(by_parent, nil)
  end

  defp build_tree(by_parent, parent_uuid) do
    by_parent
    |> Map.get(parent_uuid, [])
    |> Enum.map(fn space ->
      Map.put(space, :children, build_tree(by_parent, space.uuid))
    end)
  end

  @doc "Fetches a space by UUID. Returns `nil` if not found."
  @spec get_space(uuid) :: Space.t() | nil
  def get_space(uuid), do: repo().get(Space, uuid)

  @doc "Builds an empty changeset (for `:new` forms)."
  @spec change_space(Space.t(), map()) :: Ecto.Changeset.t()
  def change_space(%Space{} = space, attrs \\ %{}),
    do: Space.changeset(space, attrs)

  @doc """
  Full breadcrumb path for a Space, root Location through the Space
  itself: `"Location / Floor / Zone / Shelf"`. `nil` when the space
  (or its Location) can't be found.

  `opts[:locale]` — when given, each segment's name resolves through
  `PhoenixKit.Utils.Multilang.get_language_data/2` for that language
  (falling back to the primary-language column when no translation
  override exists). Omitted (or `nil`) uses the primary-language
  column directly for every segment — no `data` JSONB read at all.
  """
  @spec full_path(uuid, opts) :: String.t() | nil
  def full_path(space_uuid, opts \\ []) when is_binary(space_uuid) do
    locale = Keyword.get(opts, :locale)

    with %Space{} = space <- get_space(space_uuid),
         %Location{} = location <- repo().get(Location, space.location_uuid) do
      ancestors = ancestors_in_order(space)

      Enum.map_join([location] ++ ancestors ++ [space], " / ", &translated_name(&1, locale))
    else
      nil -> nil
    end
  end

  @doc """
  Counts every descendant of `space_uuid` — children, grandchildren,
  and so on — not including the space itself. `0` for a leaf, and `0`
  for an unknown uuid (rather than raising) so callers don't need a
  defensive existence check first.

  Backs `LocationStructureLive`'s delete-confirmation modal: before
  showing "Delete \\"X\\" and its N descendants?", the caller needs the
  true blast radius of a hard delete (children CASCADE — see
  `delete_space/2`).
  """
  @spec count_descendants(uuid) :: non_neg_integer()
  def count_descendants(space_uuid) when is_binary(space_uuid) do
    Space |> TreeQuery.descendant_uuids(space_uuid) |> length()
  end

  # ═══════════════════════════════════════════════════════════════════
  # Writes
  # ═══════════════════════════════════════════════════════════════════

  @doc """
  Creates a new space. Rejects parents that live in a different
  Location with `{:error, :parent_in_other_location}`.

  When `attrs` doesn't include an explicit `position`, the new space
  is appended to the end of its `(location_uuid, parent_uuid)` sibling
  group — `max(position) + 1`, or `0` for the first child. Without
  this, every space created through the "Add space" form (which never
  sends `position`) would sit at the schema default of `0` and jump to
  the *front* of its siblings the next time anything reorders that
  group. An explicit `position` in `attrs` — used throughout the test
  suite to pre-seed sibling order — is always honored as-is.
  """
  @spec create_space(map(), opts) ::
          {:ok, Space.t()}
          | {:error,
             Ecto.Changeset.t()
             | :parent_in_other_location
             | :parent_not_found
             | :location_not_found}
  def create_space(attrs, opts \\ []) do
    with :ok <- validate_parent_location(attrs) do
      %Space{}
      |> Space.changeset(maybe_put_next_position(attrs))
      |> repo().insert()
      |> log_activity("space.created", "location_space", opts, &space_metadata/1)
    end
  end

  @doc """
  Updates an existing space. Re-parenting is allowed but rejected if
  the new parent lives in another Location, or if the change would
  create a cycle. A space deleted since the caller loaded it comes back
  as `{:error, :space_not_found}`.
  """
  @spec update_space(Space.t(), map(), opts) ::
          {:ok, Space.t()}
          | {:error,
             Ecto.Changeset.t()
             | :space_not_found
             | :parent_in_other_location
             | :parent_not_found
             | :location_not_found
             | :cycle}
  def update_space(%Space{} = space, attrs, opts \\ []) do
    attrs = own_location(attrs, space.location_uuid)

    with :ok <- validate_parent_location(attrs),
         {:ok, _} = result <- repo().transaction(fn -> locked_update(space, attrs) end) do
      log_activity(result, "space.updated", "location_space", opts, &space_metadata/1)
    else
      {:error, %Ecto.Changeset{}} = error ->
        log_activity(error, "space.updated", "location_space", opts, &space_metadata/1)

      error ->
        error
    end
  end

  # A re-parent takes the location's tree lock first, so its cycle check
  # reads the chain after any other re-parent there has committed — two at
  # once in opposite directions otherwise both passed and committed a loop.
  # The row lock keeps the stored folder pointer a save does not name
  # (`Locations.keep_folder_pointer/2`), and the changeset starts from the
  # locked row's `data` when the attrs name none (`Locations.with_stored_data/3`).
  defp locked_update(space, attrs) do
    parent = fetch_attr(attrs, :parent_uuid)
    # Any change of parent, a move to the top level included: it closes no
    # cycle, but it must not slip past the lock the other tree writers hold.
    if reparenting?(space, attrs), do: lock_tree(space.location_uuid)
    stored = Locations.lock_row(Space, space.uuid)

    # Gone since the caller loaded it (another session's delete, or its
    # parent's cascade): refused rather than raised as a stale update.
    with %Space{} <- stored || {:error, :space_not_found},
         :ok <- validate_no_cycle(space.uuid, parent, space.location_uuid),
         {:ok, updated} <-
           space
           |> Locations.with_stored_data(stored, attrs)
           |> Space.changeset(Locations.keep_folder_pointer(attrs, stored))
           |> repo().update() do
      updated
    else
      {:error, reason} -> repo().rollback(reason)
    end
  end

  defp reparenting?(%Space{parent_uuid: current}, attrs) do
    if Map.has_key?(attrs, "parent_uuid") or Map.has_key?(attrs, :parent_uuid),
      do: normalize_parent(fetch_attr(attrs, :parent_uuid)) != normalize_parent(current),
      else: false
  end

  defp normalize_parent(parent) when parent in [nil, ""], do: nil
  defp normalize_parent(parent), do: to_string(parent)

  defp lock_tree(location_uuid) do
    repo().query!("SELECT pg_advisory_xact_lock(hashtext($1))", [
      "phoenix_kit_locations:spaces:#{location_uuid}"
    ])
  end

  @doc """
  Hard-deletes a space. Children CASCADE via the DB FK — the entire
  subtree is removed. The activity log records the delete of the
  named root; children deletes aren't individually logged (would be
  noisy on deep trees).
  """
  @spec delete_space(Space.t(), opts) :: {:ok, Space.t()} | {:error, Ecto.Changeset.t()}
  def delete_space(%Space{} = space, opts \\ []) do
    space
    |> repo().delete()
    |> log_activity("space.deleted", "location_space", opts, &space_metadata/1)
  end

  @doc """
  Reorders a sibling group under a single (location, parent) — accepts
  the full ordered list of sibling UUIDs and rewrites their `position`
  to match. Runs in a transaction; returns `{:ok, :reordered}` or
  `{:error, reason}`.
  """
  @spec reorder_siblings(uuid, uuid | nil, [uuid], opts) ::
          {:ok, :reordered} | {:error, term()}
  def reorder_siblings(location_uuid, parent_uuid, ordered_uuids, opts \\ [])
      when is_binary(location_uuid) and is_list(ordered_uuids) do
    repo().transaction(fn ->
      ordered_uuids
      |> Enum.with_index()
      |> Enum.each(fn {uuid, position} ->
        uuid
        |> sibling_position_query(location_uuid, parent_uuid)
        |> repo().update_all(set: [position: position])
      end)
    end)
    |> case do
      {:ok, _} ->
        maybe_log_activity(
          "space.reordered",
          "location_space",
          parent_uuid,
          opts,
          %{"location_uuid" => location_uuid, "count" => length(ordered_uuids)}
        )

        {:ok, :reordered}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Scopes a single space to its (location, parent) sibling group. Root
  # siblings carry `parent_uuid == nil`, which must be matched with
  # `is_nil/1` — a pinned `== ^nil` compiles to SQL `= NULL` and never
  # matches, so floor reordering would silently update zero rows.
  defp sibling_position_query(uuid, location_uuid, nil) do
    from(s in Space,
      where: s.uuid == ^uuid and s.location_uuid == ^location_uuid and is_nil(s.parent_uuid)
    )
  end

  defp sibling_position_query(uuid, location_uuid, parent_uuid) do
    from(s in Space,
      where:
        s.uuid == ^uuid and s.location_uuid == ^location_uuid and
          s.parent_uuid == ^parent_uuid
    )
  end

  # ═══════════════════════════════════════════════════════════════════
  # Internals — sibling position (create_space/2 auto-append)
  # ═══════════════════════════════════════════════════════════════════

  # Appends the next-in-group `position` to `attrs` when the caller
  # didn't supply one explicitly — see `create_space/2`'s doc. Written
  # back using whichever key shape (`String.t()` vs `atom()`) `attrs`
  # already uses, so `Space.changeset/2`'s `cast/3` never sees a
  # mixed-key map (Ecto raises `ArgumentError` on that combination).
  defp maybe_put_next_position(attrs) do
    if has_position?(attrs) do
      attrs
    else
      location_uuid = fetch_attr(attrs, :location_uuid)
      parent_uuid = blank_to_nil(fetch_attr(attrs, :parent_uuid))
      put_attr(attrs, :position, next_position(location_uuid, parent_uuid))
    end
  end

  defp has_position?(attrs), do: fetch_attr(attrs, :position) not in [nil, ""]

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp put_attr(attrs, key, value) do
    if Enum.any?(Map.keys(attrs), &is_binary/1),
      do: Map.put(attrs, Atom.to_string(key), value),
      else: Map.put(attrs, key, value)
  end

  # `location_uuid` missing (or invalid) is left for the changeset's
  # `assoc_constraint(:location)` — or `validate_parent_location/1`,
  # already run before this is called — to reject. `0` here is a
  # harmless placeholder that never reaches the DB in that case.
  #
  # Read-then-write, not a single atomic SQL expression or row lock —
  # matches this module's existing tolerance for a low-concurrency
  # race elsewhere (see the moduledoc on the same-Location invariant
  # and cycle prevention: guarded at the context boundary, not against
  # concurrent writers). A lost race here would produce a duplicate
  # `position` among siblings — a cosmetic ordering hiccup that
  # self-heals on the next manual reorder, not a data-integrity
  # problem.
  defp next_position(nil, _parent_uuid), do: 0

  defp next_position(location_uuid, parent_uuid) do
    location_uuid
    |> sibling_group_query(parent_uuid)
    |> repo().aggregate(:max, :position)
    |> case do
      nil -> 0
      max -> max + 1
    end
  end

  defp sibling_group_query(location_uuid, nil) do
    from(s in Space, where: s.location_uuid == ^location_uuid and is_nil(s.parent_uuid))
  end

  defp sibling_group_query(location_uuid, parent_uuid) do
    from(s in Space, where: s.location_uuid == ^location_uuid and s.parent_uuid == ^parent_uuid)
  end

  # ═══════════════════════════════════════════════════════════════════
  # Internals — validations
  # ═══════════════════════════════════════════════════════════════════

  defp validate_parent_location(attrs) do
    check_parent_under_location(
      fetch_attr(attrs, :location_uuid),
      fetch_attr(attrs, :parent_uuid)
    )
  end

  # A space stays in its location: one sent with an update (a crafted form
  # field) would move it out of its tree and leave its children behind.
  # Written in the key shape `attrs` already uses — cast refuses a mix.
  defp own_location(attrs, location_uuid) do
    attrs = Map.drop(attrs, [:location_uuid, "location_uuid"])

    if Enum.any?(Map.keys(attrs), &is_atom/1),
      do: Map.put(attrs, :location_uuid, location_uuid),
      else: Map.put(attrs, "location_uuid", location_uuid)
  end

  # `attrs` may arrive string-keyed (form params) or atom-keyed (internal
  # callers); read either so parent/cycle checks never silently skip on a
  # key-shape mismatch.
  defp fetch_attr(attrs, key) when is_atom(key) do
    Map.get(attrs, Atom.to_string(key)) || Map.get(attrs, key)
  end

  defp check_parent_under_location(_location_uuid, nil), do: :ok
  defp check_parent_under_location(_location_uuid, ""), do: :ok
  defp check_parent_under_location(nil, _parent_uuid), do: {:error, :location_not_found}

  defp check_parent_under_location(location_uuid, parent_uuid) do
    case get_space(parent_uuid) do
      nil -> {:error, :parent_not_found}
      %Space{location_uuid: ^location_uuid} -> :ok
      %Space{} -> {:error, :parent_in_other_location}
    end
  end

  # Walk up the parent chain from `new_parent_uuid` — if we ever hit
  # `space_uuid`, the change would create a cycle. Bounded walk so a
  # corrupted chain can't spin forever.
  defp validate_no_cycle(_space_uuid, nil, _location_uuid), do: :ok
  defp validate_no_cycle(_space_uuid, "", _location_uuid), do: :ok

  defp validate_no_cycle(space_uuid, new_parent_uuid, _location_uuid)
       when space_uuid == new_parent_uuid,
       do: {:error, :cycle}

  # The new parent's ancestors in one recursive query (no depth cap: the
  # old walk stopped at 64 hops and called any deeper chain a cycle).
  defp validate_no_cycle(space_uuid, new_parent_uuid, _location_uuid) do
    if space_uuid in TreeQuery.ancestor_uuids(Space, new_parent_uuid),
      do: {:error, :cycle},
      else: :ok
  end

  # ═══════════════════════════════════════════════════════════════════
  # Internals — path resolution (full_path/2)
  # ═══════════════════════════════════════════════════════════════════

  # Ancestors of `space`, ordered root → direct parent. `[]` when
  # `space` is already a root (`parent_uuid == nil`) — skips the query
  # entirely in the common case. One recursive query
  # (`PhoenixKit.Utils.TreeQuery`, cycle-safe) for the uuids, one read for
  # the rows, then `walk_up/3` puts them in order.
  defp ancestors_in_order(%Space{parent_uuid: nil}), do: []

  defp ancestors_in_order(%Space{} = space) do
    case TreeQuery.ancestor_uuids(Space, space.uuid) do
      [] ->
        []

      uuids ->
        by_uuid =
          from(s in Space, where: s.uuid in ^uuids)
          |> repo().all()
          |> Map.new(&{&1.uuid, &1})

        walk_up(space.parent_uuid, by_uuid, [])
    end
  end

  # Walks `by_uuid` from `uuid` up to the root, prepending each node as
  # it climbs — comes out root-first with no separate reverse (the
  # direct parent is added first so it ends up at the tail; the root
  # is added last so it ends up at the head).
  defp walk_up(uuid, by_uuid, acc) do
    case Map.get(by_uuid, uuid) do
      %Space{parent_uuid: nil} = s -> [s | acc]
      %Space{parent_uuid: parent_uuid} = s -> walk_up(parent_uuid, by_uuid, [s | acc])
      nil -> acc
    end
  end

  # Resolves a translated `name` for a Location or Space (any map or
  # struct with a `:name` field and, for the locale-aware clause, a
  # `:data` field). `locale: nil` skips the JSONB read entirely and
  # returns the primary-language column as-is.
  #
  # The column is the main language's name; `data` holds the other
  # languages' overrides (`PhoenixKitLocations.TranslatedData`). So the
  # main language, and a language with no name of its own, read the
  # column, and another language reads its OWN entry, never the merged
  # main ⊕ override map core's `get_language_data/2` builds: there a
  # main-entry `"_name"` (core's form writes it) shadows a bare `"name"`
  # override (a bulk or AI translation writes those), and a main entry
  # left stale by an older release would stand in for the column.
  # `get_raw_language_data/2` finds the entry with core's dialect fallback
  # ("fr" for "fr-FR"); when that falls through to the main entry, it is
  # the main language. `"_name"` is read before the bare `"name"`. Flat
  # (single-language) data is read as one entry.
  #
  # Public (not part of the documented API — `@doc false`) so that
  # `LocationStructureLive` and `PlacePicker` share this resolver.
  @doc false
  def translated_name(%{name: name}, nil), do: name

  def translated_name(%{data: data, name: name}, locale) do
    if Multilang.multilang_data?(data) do
      main_entry = Map.get(data, data["_primary_language"])

      case Multilang.get_raw_language_data(data, locale) do
        ^main_entry -> name
        own -> entry_name(own) || name
      end
    else
      entry_name(data || %{}) || name
    end
  end

  defp entry_name(entry) do
    Enum.find_value(["_name", "name"], fn key ->
      case Map.get(entry, key) do
        value when is_binary(value) and value != "" -> value
        _ -> nil
      end
    end)
  end

  # ═══════════════════════════════════════════════════════════════════
  # Internals — activity logging (mirrors Locations context)
  # ═══════════════════════════════════════════════════════════════════

  defp log_activity({:ok, %Space{} = record} = ok, action, resource_type, opts, metadata_fun)
       when is_function(metadata_fun, 1) do
    maybe_log_activity(action, resource_type, record.uuid, opts, metadata_fun.(record))
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

  # On {:error, changeset} the space may not have a UUID yet (insert
  # failed) — fall back to the changeset's data UUID, which exists
  # for updates and is `nil` for inserts.
  defp changeset_resource_uuid(%Ecto.Changeset{data: data}), do: Map.get(data, :uuid)

  # PII-safe changeset metadata: invalid field names + a db_pending marker.
  # Never includes the rejected values themselves.
  defp changeset_error_metadata(%Ecto.Changeset{errors: errors}) do
    %{
      "db_pending" => true,
      "error_fields" => errors |> Enum.map(fn {field, _} -> to_string(field) end) |> Enum.uniq()
    }
  end

  defp maybe_log_activity(action, resource_type, resource_uuid, opts, metadata) do
    PhoenixKit.Activity.log("locations", action,
      mode: Keyword.get(opts, :mode, "manual"),
      actor_uuid: Keyword.get(opts, :actor_uuid),
      resource_type: resource_type,
      resource_uuid: resource_uuid,
      metadata: metadata
    )

    :ok
  end

  defp space_metadata(%Space{} = s) do
    %{
      "name" => s.name,
      "kind" => s.kind,
      "status" => s.status,
      "location_uuid" => s.location_uuid,
      "parent_uuid" => s.parent_uuid
    }
  end
end
