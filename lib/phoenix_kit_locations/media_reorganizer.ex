defmodule PhoenixKitLocations.MediaReorganizer do
  @moduledoc """
  Locations' media-reorganizer plan source.

  Not compiled against a core `PhoenixKit.Modules.Storage.Reorganizer.Source`
  behaviour — today's hex core (2.23.x) does not ship the engine yet. This
  module declares no `@behaviour` and returns plain maps; see
  `PhoenixKitLocations.media_reorganizer/0` for the registration comment.
  Once core ships the engine, `plan/2`'s contract (`plan(actor_uuid, opts)
  :: [map()]`) already matches `Source.plan/2` — the only follow-up is
  adding `@behaviour`/`@impl`.

  `plan/2` derives the desired parent/name from the exact hooks
  (`Attachments.parent_folder_uuid/2`, `Attachments.folder_name/2`) that a
  fresh upload uses, so a plan describes exactly what the module would do
  today. Once every folder already sits where its plan says, the engine's
  `Action.noop?/1` filters the action out — a second run plans nothing.

  Covers locations and spaces (their own attachment folders) and stale
  `location-attachment-pending-*` upload folders and orphaned legacy
  folders whose record is gone (see "Orphaned legacy folders" below).

  ## Departures from the catalogue template

  Unlike catalogue's records, `Location`/`Space` have no soft-delete status
  (`@statuses` is only `~w(active inactive)`) — `Locations.delete_location/2`
  and `Spaces.delete_space/2` are hard deletes. So:

    * "live" records is simply every row — no status filter is needed or
      possible;
    * an orphan can only be "record missing", never "record soft-deleted".

  Also, `Location`/`Space` have no `data_owned_keys`-style scoped update (the
  mechanism catalogue's `write_pointer/2` uses to touch only the pointer key)
  — `after_move` re-reads the record `FOR UPDATE` and merges the pointer
  into its `data` map before writing the whole map back, same as
  `Attachments.inject_files_folder/2` does at upload time, except for the
  fresh locked read (see `write_data_pointer/4`'s comment for why).
  """

  import Ecto.Query, warn: false

  alias PhoenixKit.Modules.Storage.{File, Folder, FolderLink}
  alias PhoenixKitLocations.Attachments
  alias PhoenixKitLocations.Locations
  alias PhoenixKitLocations.Schemas.{Location, Space}
  alias PhoenixKitLocations.Spaces

  @pending_prefix "location-attachment-pending-"
  @default_pending_days 7

  @doc """
  Builds the locations' reorganizer plan: one `:move` action per location and
  space whose current folder does not already match its hooks, plus
  `:trash`/`:report` actions for stale pending folders, and a `:report`
  (`kind: :orphan`) per legacy folder whose record is gone.

  `opts[:pending_days]` (default #{@default_pending_days}) — how old an
  empty pending folder must be before it is reported as `:trash` instead of
  left alone.
  """
  @spec plan(String.t() | nil, keyword()) :: [map()]
  def plan(actor_uuid, opts \\ []) do
    pending_days = Keyword.get(opts, :pending_days, @default_pending_days)

    tagged_records =
      tag(live_locations(), :location) ++
        tag(live_spaces(), :space)

    # Desired parent/name (the host hooks, possibly a DB lookup or a
    # lazily-created folder on the host side) is resolved exactly once per
    # record here and threaded into both passes below — `orphan_actions/1`
    # reuses `desired`'s `parent_uuid`s instead of re-running the hook.
    desired = resolve_desired(tagged_records, actor_uuid)

    resource_actions(desired) ++
      orphan_actions(desired) ++
      pending_folder_actions(pending_days)
  end

  # ── Locations / spaces ──────────────────────────────────────────

  defp tag(records, kind), do: Enum.map(records, &{&1, kind})

  defp resolve_desired(tagged_records, actor_uuid) do
    Enum.map(tagged_records, fn {record, kind} ->
      %{
        record: record,
        kind: kind,
        parent_uuid: Attachments.parent_folder_uuid(record, actor_uuid),
        name: Attachments.folder_name(record, actor_uuid),
        legacy_name: legacy_name(record),
        pointer: pointer_uuid(record)
      }
    end)
  end

  defp legacy_name(record) do
    case Attachments.folder_name_for(record) do
      {:ok, name} -> name
      :pending -> nil
    end
  end

  # Every folder lookup for the whole batch runs as three preloaded queries
  # (pointer uuids, legacy names at root, legacy names under a parent)
  # instead of one-to-three individual round trips per record.
  defp resource_actions(desired) do
    by_pointer = preload_by_uuid(Enum.map(desired, & &1.pointer))
    by_root_name = preload_by_root_name(Enum.map(desired, & &1.legacy_name))
    by_parent_name = preload_by_parent_name(desired)

    desired
    |> Enum.map(&resource_action(&1, by_pointer, by_root_name, by_parent_name))
    |> Enum.reject(&is_nil/1)
  end

  defp resource_action(desired, by_pointer, by_root_name, by_parent_name) do
    %{record: record, kind: kind, parent_uuid: parent_uuid, name: name} = desired

    case current_folder(desired, by_pointer, by_root_name, by_parent_name) do
      nil ->
        nil

      %Folder{} = folder ->
        after_move = after_move_fun(record, desired.pointer, folder)

        if noop_move?(folder, parent_uuid, name) and is_nil(after_move) do
          nil
        else
          %{
            source: "locations",
            kind: kind,
            label: record.name,
            op: :move,
            folder: folder,
            parent_uuid: parent_uuid,
            name: name,
            counts: counts(folder.uuid),
            on_conflict: :suffix,
            after_move: after_move
          }
        end
    end
  end

  # A `:move` whose folder already sits at `parent_uuid` under `name` (or an
  # accepted `"name (N)"` suffix variant) is a no-op — filtered here since
  # this Source has no core `Action.noop?/1` to lean on. A pointer
  # back-fill still needs the action even when the folder itself would not
  # move (`after_move_fun/3` is checked by the caller).
  defp noop_move?(%Folder{parent_uuid: parent_uuid, name: name}, parent_uuid, name), do: true

  defp noop_move?(%Folder{parent_uuid: parent_uuid, name: folder_name}, parent_uuid, name) do
    suffixed_variant?(folder_name, name)
  end

  defp noop_move?(_folder, _parent_uuid, _name), do: false

  defp suffixed_variant?(folder_name, name) do
    Regex.match?(~r/^#{Regex.escape(name)} \(\d+\)$/, folder_name)
  end

  defp pointer_uuid(%{data: data}) when is_map(data), do: Map.get(data, "files_folder_uuid")
  defp pointer_uuid(_), do: nil

  # One query for every distinct pointer uuid in the batch.
  defp preload_by_uuid(uuids) do
    case Enum.reject(Enum.uniq(uuids), &is_nil/1) do
      [] -> %{}
      uuids -> Folder |> where([f], f.uuid in ^uuids) |> repo().all() |> Map.new(&{&1.uuid, &1})
    end
  end

  # One query for every distinct legacy name in the batch, at root.
  defp preload_by_root_name(names) do
    case Enum.reject(Enum.uniq(names), &is_nil/1) do
      [] ->
        %{}

      names ->
        Folder
        |> where([f], f.name in ^names and is_nil(f.parent_uuid))
        |> repo().all()
        |> Map.new(&{&1.name, &1})
    end
  end

  # One query for every distinct legacy name under every distinct resolved
  # parent in the batch (a name × parent cross-match, filtered client-side
  # to exact pairs when read) — still one round trip for the whole batch.
  defp preload_by_parent_name(desired) do
    names = desired |> Enum.map(& &1.legacy_name) |> Enum.reject(&is_nil/1) |> Enum.uniq()
    parents = desired |> Enum.map(& &1.parent_uuid) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    if names == [] or parents == [] do
      %{}
    else
      Folder
      |> where([f], f.name in ^names and f.parent_uuid in ^parents)
      |> repo().all()
      |> Map.new(&{{&1.name, &1.parent_uuid}, &1})
    end
  end

  # Pointer, if it still resolves to a live folder; else the legacy
  # deterministic name at root; else the legacy name under the resolved
  # parent. `nil` when none of those exist — nothing to move.
  defp current_folder(desired, by_pointer, by_root_name, by_parent_name) do
    %{legacy_name: legacy_name, parent_uuid: parent_uuid, pointer: pointer} = desired

    live_or_nil(pointer && Map.get(by_pointer, pointer)) ||
      (legacy_name && live_or_nil(Map.get(by_root_name, legacy_name))) ||
      (legacy_name && parent_uuid &&
         live_or_nil(Map.get(by_parent_name, {legacy_name, parent_uuid})))
  end

  defp live_or_nil(%Folder{trashed_at: nil} = folder), do: folder
  defp live_or_nil(_), do: nil

  # `nil` when the pointer already matches the current (pre-move) folder —
  # nothing to back-fill. Otherwise a fun the engine runs after the move,
  # inside the same transaction, to write/repair the pointer.
  defp after_move_fun(record, pointer, %Folder{uuid: folder_uuid}) do
    if pointer == folder_uuid do
      nil
    else
      fn -> write_pointer(record, folder_uuid) end
    end
  end

  defp write_pointer(%Location{uuid: uuid}, folder_uuid) do
    write_data_pointer(Location, &Locations.update_location/2, uuid, folder_uuid)
  end

  defp write_pointer(%Space{uuid: uuid}, folder_uuid) do
    write_data_pointer(Space, &Spaces.update_space/2, uuid, folder_uuid)
  end

  # No `data_owned_keys` scoping here (unlike catalogue) — merges into the
  # record's own `data` map before writing the whole map back, so other keys
  # (`featured_image_uuid`, translations) already on the record survive.
  # Re-reads the row `FOR UPDATE` right here rather than reusing the
  # plan-time struct closed over by `after_move_fun/3`: `plan/2` may have
  # loaded that struct long before this action's `after_move` runs (a
  # multi-thousand-record `--apply` run), and another editor can have
  # changed a different `data` key in between — merging into the stale
  # struct would silently discard that edit on the full-map write below.
  # The lock is only meaningful because `after_move` runs inside the
  # engine's own per-action transaction (same connection), matching how
  # catalogue's `data_owned_keys` (`narrow_data_ownership/4`) takes its
  # own `FOR UPDATE` lock. String-keyed: `Spaces.update_space/3` adds its own
  # `"location_uuid"` key to `attrs` internally, and `Ecto.Changeset.cast/4`
  # raises on a map mixing atom and string keys.
  defp write_data_pointer(schema, update_fun, uuid, folder_uuid) do
    query = from(r in schema, where: r.uuid == ^uuid, lock: "FOR UPDATE")

    case repo().one(query) do
      nil ->
        {:error, :not_found}

      record ->
        data = Map.put(record.data || %{}, "files_folder_uuid", folder_uuid)

        case update_fun.(record, %{"data" => data}) do
          {:ok, _updated} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  # ── Pending upload folders ──────────────────────────────────────

  defp pending_folder_actions(pending_days) do
    cutoff = DateTime.add(DateTime.utc_now(), -pending_days * 86_400, :second)

    Folder
    |> where([f], is_nil(f.trashed_at))
    |> where([f], like(f.name, ^"#{@pending_prefix}%"))
    |> repo().all()
    |> Enum.map(&pending_folder_action(&1, cutoff))
    |> Enum.reject(&is_nil/1)
  end

  defp pending_folder_action(folder, cutoff) do
    case counts(folder.uuid) do
      {0, 0} ->
        if DateTime.compare(folder.inserted_at, cutoff) == :lt do
          %{
            source: "locations",
            kind: :pending,
            label: folder.name,
            op: :trash,
            folder: folder,
            counts: {0, 0},
            reason: "empty pending upload folder older than the retention window"
          }
        end

      {files, links} ->
        names = pending_file_names(folder.uuid)

        %{
          source: "locations",
          kind: :pending,
          label: folder.name,
          op: :report,
          folder: folder,
          counts: {files, links},
          reason: "pending folder still has files: #{Enum.join(names, ", ")}"
        }
    end
  end

  # Mirrors `counts/1`'s definition of "this folder's content" (own files
  # plus files reachable via `FolderLink`, same union the reference's
  # `Attachments.folder_files_query/1` uses) so a folder :report'd purely
  # because of a linked file still names it — and excludes trashed files
  # (unlike `counts/1`, which counts every status so a plan-time count
  # matches the engine's own re-measure at apply time) so a report's file
  # list only names files someone still needs to act on.
  defp pending_file_names(folder_uuid) do
    linked_subq =
      from(fl in FolderLink, where: fl.folder_uuid == ^folder_uuid, select: fl.file_uuid)

    File
    |> where(
      [f],
      (f.folder_uuid == ^folder_uuid or f.uuid in subquery(linked_subq)) and
        f.status != "trashed"
    )
    |> repo().all()
    |> Enum.map(& &1.original_file_name)
  end

  # ── Orphaned legacy folders ──────────────────────────────────────

  # A legacy-named folder (`location-<uuid>`, `location-space-<uuid>`) at
  # the media root or under a parent this batch's hooks resolved to, whose
  # uuid no longer names a live record, is reported so a host can collect
  # it. Never `:move`d or `:trash`ed here — this module owns no "orphans"
  # container; a legacy folder that IS a live record's current folder is
  # left to `resource_action/4` above. Reuses `desired`'s `parent_uuid`s
  # (already resolved once per record in `plan/2`) rather than calling the
  # host hook again.
  #
  # Unlike catalogue's records, `Location`/`Space` are hard-deleted (no
  # "deleted" status) — a missing record is the only way to be orphaned.
  defp orphan_actions(desired) do
    resolved_parents =
      desired
      |> Enum.map(& &1.parent_uuid)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    case legacy_candidate_folders(resolved_parents) do
      [] ->
        []

      candidates ->
        records_by_key = load_candidate_records(candidates)

        candidates
        |> Enum.map(&orphan_action(&1, records_by_key))
        |> Enum.reject(&is_nil/1)
    end
  end

  # One query for every legacy-named folder at root or under a resolved
  # parent — not a query per folder.
  defp legacy_candidate_folders(parent_uuids) do
    Folder
    |> where([f], is_nil(f.trashed_at))
    |> where([f], is_nil(f.parent_uuid) or f.parent_uuid in ^parent_uuids)
    |> repo().all()
    |> Enum.map(&{&1, legacy_kind(&1.name)})
    |> Enum.filter(fn {_folder, kind} -> kind end)
  end

  # `location-space-` must be checked before `location-` — a space folder
  # name also starts with the location prefix.
  @legacy_kinds [
    {"location-space-", :space},
    {"location-", :location}
  ]

  defp legacy_kind(name) do
    if String.starts_with?(name, @pending_prefix) do
      nil
    else
      Enum.find_value(@legacy_kinds, &legacy_kind_match(name, &1))
    end
  end

  defp legacy_kind_match(name, {prefix, kind}) do
    with true <- String.starts_with?(name, prefix),
         uuid <- String.replace_prefix(name, prefix, ""),
         {:ok, _} <- Ecto.UUID.cast(uuid) do
      {kind, uuid}
    else
      _ -> nil
    end
  end

  # One query per record kind present among the candidates — not per folder.
  defp load_candidate_records(candidates) do
    by_kind =
      Enum.group_by(
        candidates,
        fn {_folder, {kind, _uuid}} -> kind end,
        fn {_folder, {_kind, uuid}} -> uuid end
      )

    %{}
    |> Map.merge(load_records(Location, :location, Map.get(by_kind, :location, [])))
    |> Map.merge(load_records(Space, :space, Map.get(by_kind, :space, [])))
  end

  defp load_records(_schema, _kind, []), do: %{}

  defp load_records(schema, kind, uuids) do
    schema
    |> where([r], r.uuid in ^uuids)
    |> repo().all()
    |> Map.new(&{{kind, &1.uuid}, &1})
  end

  defp orphan_action({folder, {kind, uuid}}, records_by_key) do
    case Map.get(records_by_key, {kind, uuid}) do
      nil ->
        counts = counts(folder.uuid)

        %{
          source: "locations",
          kind: :orphan,
          op: :report,
          label: folder.name,
          folder: folder,
          counts: counts,
          reason: orphan_reason(counts)
        }

      _record ->
        nil
    end
  end

  defp orphan_reason({files, _links}), do: "record missing, #{files} file(s)"

  # ── Shared helpers ───────────────────────────────────────────────

  # Counts ALL rows regardless of status (including trashed files) — the
  # core engine re-measures the same way at apply time (any row with this
  # `folder_uuid`) and aborts the action on a mismatch, so a plan-time
  # count that excluded trashed files would fail every folder holding one.
  defp counts(folder_uuid) do
    files =
      File
      |> where([f], f.folder_uuid == ^folder_uuid)
      |> repo().aggregate(:count)

    links =
      FolderLink
      |> where([l], l.folder_uuid == ^folder_uuid)
      |> repo().aggregate(:count)

    {files, links}
  end

  # No status filter — `Locations.delete_location/2` and
  # `Spaces.delete_space/2` are hard deletes, so every row present is live.
  defp live_locations, do: repo().all(Location)
  defp live_spaces, do: repo().all(Space)

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
