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
  today. Once every folder already sits where its plan says, the plan
  filters the action out itself (see "Move planning" below) — a second run
  plans nothing.

  A host that has not configured `:attachments_parent_folder` is left
  entirely untouched: no move, no pointer back-fill, and the parent hook is
  never even called for a record without some existing candidate folder
  (pointer or legacy name) — see "Move planning". Pending-folder and orphan
  detection do not depend on a hook and still run.

  Covers locations and spaces (their own attachment folders), stale
  `location-attachment-pending-*` upload folders, and orphaned legacy
  folders whose record is gone (see "Orphaned legacy folders" below).

  ## Move planning

  For each live location/space (`Location`/`Space` have no soft-delete
  status — `Locations.delete_location/2` and `Spaces.delete_space/2` are
  hard deletes — so "live" is simply every row):

  1. A record is a *candidate* when it has a live pointer
     (`data["files_folder_uuid"]`, resolved without calling any hook) or a
     live folder anywhere named after its legacy deterministic name
     (`location-<uuid>` / `location-space-<uuid>`, also resolved without a
     hook — one batched query for the whole plan). A record with neither
     is left alone: nothing exists to move, and the host's parent hook is
     never called for it.
  2. Only for candidates, the host's own hooks resolve the desired parent
     and name — exactly the functions a fresh upload would call. D3: when
     the host-named folder under the resolved parent is already claimed
     (by a live pointer) by a *different* record, the desired name falls
     back to the deterministic legacy name instead — the same retry
     `Attachments.with_name_fallback/3` performs at upload time (a taken
     host name can't be adopted; the deterministic name never collides).
  3. The record's *current* folder is: its live pointer if it has one
     (kept as-is, `name: nil` — D6, the owner may have renamed it, this
     module never renames a cached folder); else the legacy-named live
     folder under the resolved parent; else the legacy-named live folder
     at root (this order matches `Attachments.find_resource_folder/2`). A
     legacy name live in **both** places is unresolvable — reported as one
     `kind: :duplicate` action naming both folders, nothing moved.
  4. Two (or more) records whose current folder resolves to the very same
     live folder are likewise unresolvable — one `kind: :duplicate` report
     per shared folder, no move for any of them.

  ## Pointer back-fill

  `Location`/`Space` have no `data_owned_keys`-style scoped update — unlike
  catalogue, `after_move` writes the pointer with a direct, locked
  (`FOR UPDATE`) repo update of the record's own `data` map, never through
  `Locations.update_location/3` / `Spaces.update_space/3` (those run the
  full context path — `Activity.log`, PubSub, full changeset validation —
  none of which belongs inside the engine's per-action transaction, and a
  broadcast for a move that then rolls back would be a lie).
  """

  import Ecto.Query, warn: false

  alias PhoenixKit.Modules.Storage.{File, Folder, FolderLink}
  alias PhoenixKitLocations.Attachments
  alias PhoenixKitLocations.Schemas.{Location, Space}

  @pending_prefix "location-attachment-pending-"
  @default_pending_days 7
  @legacy_prefix "location-"

  # `location-space-` must be checked before `location-` — a space folder
  # name also starts with the location prefix.
  @legacy_kinds [
    {"location-space-", :space},
    {"location-", :location}
  ]

  @uuid_regex ~r/\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/

  @doc """
  Builds the locations' reorganizer plan: one `:move` action per location and
  space whose current folder does not already match its hooks, `:report`
  (`kind: :duplicate`) actions for folders that cannot be unambiguously
  resolved, `:trash`/`:report` actions for stale pending folders, and a
  `:report` (`kind: :orphan`) per legacy folder whose record is gone.

  `opts[:pending_days]` (default #{@default_pending_days}) — how old an
  empty pending folder must be before it is reported as `:trash` instead of
  left alone.
  """
  @spec plan(String.t() | nil, keyword()) :: [map()]
  def plan(actor_uuid, opts \\ []) do
    pending_days = Keyword.get(opts, :pending_days, @default_pending_days)

    {resource_actions, claimed_uuids, resolved_parents} = resource_plan(actor_uuid)

    resource_actions ++
      orphan_actions(resolved_parents) ++
      pending_folder_actions(pending_days, claimed_uuids)
  end

  # ── Locations / spaces ──────────────────────────────────────────

  defp resource_plan(actor_uuid) do
    if hook_configured?() do
      tagged_records = tag(live_locations(), :location) ++ tag(live_spaces(), :space)
      build_resource_plan(tagged_records, actor_uuid)
    else
      {[], MapSet.new([]), []}
    end
  end

  defp hook_configured? do
    match?(
      {mod, fun} when is_atom(mod) and is_atom(fun),
      Application.get_env(:phoenix_kit_locations, :attachments_parent_folder)
    )
  end

  defp tag(records, kind), do: Enum.map(records, &{&1, kind})

  # Candidate detection needs no hook call: a live pointer (uuid lookup) or
  # a live folder anywhere named after the record's legacy name. Only
  # candidates go on to have the host's parent/name hooks resolved — a
  # record with nothing pointing at it never triggers a host hook.
  defp build_resource_plan(tagged_records, actor_uuid) do
    prelim =
      Enum.map(tagged_records, fn {record, kind} ->
        %{
          record: record,
          kind: kind,
          pointer: valid_uuid(pointer_uuid(record)),
          legacy_name: legacy_name(record)
        }
      end)

    by_pointer = preload_by_uuid(Enum.map(prelim, & &1.pointer))
    by_name = preload_by_name_anywhere(Enum.map(prelim, & &1.legacy_name))

    candidates =
      Enum.filter(prelim, fn p ->
        (p.pointer && Map.has_key?(by_pointer, p.pointer)) ||
          Map.has_key?(by_name, p.legacy_name)
      end)

    desired = resolve_desired(candidates, actor_uuid)
    entries = Enum.map(desired, &resolve_entry(&1, by_pointer, by_name))

    resolved_parents =
      desired |> Enum.map(& &1.parent_uuid) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    {unique, ambiguous_dup, shared_dup} = classify_entries(entries)

    move_actions = unique |> Enum.map(&build_move_action/1) |> Enum.reject(&is_nil/1)
    dup_actions = Enum.map(ambiguous_dup, &build_ambiguous_duplicate_action/1)
    shared_actions = Enum.map(shared_dup, &build_shared_duplicate_action/1)

    all_actions = move_actions ++ dup_actions ++ shared_actions
    claimed = claimed_folder_uuids(unique, ambiguous_dup, shared_dup)

    {finalize_counts(all_actions), claimed, resolved_parents}
  end

  defp legacy_name(record) do
    case Attachments.folder_name_for(record) do
      {:ok, name} -> name
      :pending -> nil
    end
  end

  # Resolves every candidate's desired parent/name in one pass. D3: the
  # host name is only trusted when the folder it names under the resolved
  # parent is not already claimed (by a live pointer) by a *different*
  # record — see `resolved_name/3`.
  defp resolve_desired(candidates, actor_uuid) do
    prelim =
      Enum.map(candidates, fn p ->
        parent_uuid = Attachments.parent_folder_uuid(p.record, actor_uuid)
        host_name = Attachments.folder_name(p.record, actor_uuid)
        Map.merge(p, %{parent_uuid: parent_uuid, host_name: host_name})
      end)

    claim_map = pointer_claim_map(prelim)
    by_host_parent = preload_by_name_parent(host_name_parent_pairs(prelim))

    Enum.map(prelim, fn d -> Map.put(d, :name, resolved_name(d, by_host_parent, claim_map)) end)
  end

  # Only host names that actually differ from the deterministic legacy name
  # need a collision check — when they're equal there is nothing a hook
  # could have claimed instead.
  defp host_name_parent_pairs(prelim) do
    prelim
    |> Enum.filter(&(&1.host_name != &1.legacy_name))
    |> Enum.map(&{&1.host_name, &1.parent_uuid})
    |> Enum.uniq()
  end

  # uuid of a live pointer target -> the uuid of the record that owns that
  # pointer, for every candidate with one. Mirrors `Attachments.unclaimed/2`,
  # which checks exactly this (another live record's `files_folder_uuid`
  # pointing at the folder), not a name match.
  defp pointer_claim_map(prelim) do
    prelim |> Enum.filter(& &1.pointer) |> Map.new(&{&1.pointer, &1.record.uuid})
  end

  defp resolved_name(%{host_name: name, legacy_name: name}, _by_host_parent, _claim_map),
    do: name

  defp resolved_name(d, by_host_parent, claim_map) do
    case Map.get(by_host_parent, {d.host_name, d.parent_uuid}) do
      %Folder{uuid: uuid} -> name_for_claim(d, uuid, claim_map)
      nil -> d.host_name
    end
  end

  defp name_for_claim(d, folder_uuid, claim_map) do
    if Map.get(claim_map, folder_uuid, d.record.uuid) == d.record.uuid do
      d.host_name
    else
      d.legacy_name
    end
  end

  # Resolves one record's current folder. `:pointer` when its live pointer
  # names a folder (kept as-is downstream — D6: never renamed). Otherwise
  # the legacy name is looked up under the resolved parent, then at root
  # (module's own order — same as `Attachments.find_resource_folder/2`);
  # a live match at both is ambiguous.
  defp resolve_entry(d, by_pointer, by_name) do
    pointer_folder = d.pointer && Map.get(by_pointer, d.pointer)

    if pointer_folder do
      Map.merge(d, %{folder: pointer_folder, via: :pointer, ambiguous: nil})
    else
      matches = Map.get(by_name, d.legacy_name, [])
      under_parent = d.parent_uuid && Enum.find(matches, &(&1.parent_uuid == d.parent_uuid))
      at_root = Enum.find(matches, &is_nil(&1.parent_uuid))

      case {under_parent, at_root} do
        {nil, nil} -> Map.merge(d, %{folder: nil, via: nil, ambiguous: nil})
        {same, same} -> Map.merge(d, %{folder: same, via: :name, ambiguous: nil})
        {f, nil} -> Map.merge(d, %{folder: f, via: :name, ambiguous: nil})
        {nil, f} -> Map.merge(d, %{folder: f, via: :name, ambiguous: nil})
        {f1, f2} -> Map.merge(d, %{folder: nil, via: nil, ambiguous: {f1, f2}})
      end
    end
  end

  # Splits resolved entries into: `unique` (one record ↔ one folder, safe
  # to plan a move for), `ambiguous_dup` (one record, legacy name live at
  # both root and under the resolved parent — X11), `shared_dup` (two or
  # more records resolving to the very same live folder — X5). Every entry
  # in the two dup buckets becomes a `:report kind: :duplicate` instead of
  # a `:move`.
  defp classify_entries(entries) do
    {ambiguous, normal} = Enum.split_with(entries, & &1.ambiguous)
    {with_folder, _without_folder} = Enum.split_with(normal, & &1.folder)

    grouped = Enum.group_by(with_folder, & &1.folder.uuid)

    {shared, unique} =
      Enum.reduce(grouped, {[], []}, fn {_uuid, group}, {shared_acc, unique_acc} ->
        if length(group) > 1 do
          {[group | shared_acc], unique_acc}
        else
          {shared_acc, group ++ unique_acc}
        end
      end)

    {unique, ambiguous, shared}
  end

  defp claimed_folder_uuids(unique, ambiguous_dup, shared_dup) do
    unique_uuids = Enum.map(unique, & &1.folder.uuid)

    ambiguous_uuids =
      Enum.flat_map(ambiguous_dup, fn %{ambiguous: {f1, f2}} -> [f1.uuid, f2.uuid] end)

    shared_uuids = Enum.map(shared_dup, fn [%{folder: f} | _] -> f.uuid end)

    MapSet.new(unique_uuids ++ ambiguous_uuids ++ shared_uuids)
  end

  # A `:move` whose folder already sits at `parent_uuid` under `name` (or
  # an accepted `"name (N)"` suffix variant) and needs no pointer back-fill
  # is a no-op — filtered here since this Source has no core
  # `Action.noop?/1` to lean on. D6: a folder found through the record's
  # pointer keeps `name: nil` (never renamed); only a folder found by
  # legacy name gets the desired name.
  defp build_move_action(%{via: :pointer} = entry), do: move_action(entry, nil)

  defp build_move_action(%{via: :name} = entry), do: move_action(entry, entry.name)

  defp move_action(
         %{record: record, kind: kind, folder: folder, parent_uuid: parent_uuid} = entry,
         name
       ) do
    after_move = after_move_fun(record, entry.pointer, folder)

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
        counts: nil,
        on_conflict: :suffix,
        after_move: after_move
      }
    end
  end

  # `name: nil` (a pointer-found folder, D6) — this module never renames
  # it, so only the parent needs to match for the move to be a no-op.
  defp noop_move?(%Folder{parent_uuid: parent_uuid}, parent_uuid, nil), do: true

  defp noop_move?(%Folder{parent_uuid: parent_uuid, name: name}, parent_uuid, name), do: true

  defp noop_move?(%Folder{parent_uuid: parent_uuid, name: folder_name}, parent_uuid, name)
       when is_binary(name) do
    suffixed_variant?(folder_name, name)
  end

  defp noop_move?(_folder, _parent_uuid, _name), do: false

  defp suffixed_variant?(folder_name, name) do
    Regex.match?(~r/^#{Regex.escape(name)} \(\d+\)$/, folder_name)
  end

  defp build_ambiguous_duplicate_action(%{record: record, ambiguous: {f1, f2}}) do
    %{
      source: "locations",
      kind: :duplicate,
      label: record.name,
      op: :report,
      counts: nil,
      reason:
        "legacy folder found live in two places (#{f1.uuid} and #{f2.uuid}) — pick one and remove the other"
    }
  end

  defp build_shared_duplicate_action([%{folder: folder} | _] = group) do
    labels = group |> Enum.map(& &1.record.name) |> Enum.uniq() |> Enum.join(", ")

    %{
      source: "locations",
      kind: :duplicate,
      label: folder.name,
      op: :report,
      counts: nil,
      reason: "folder #{folder.uuid} is claimed by more than one record: #{labels}"
    }
  end

  defp pointer_uuid(%{data: data}) when is_map(data), do: Map.get(data, "files_folder_uuid")
  defp pointer_uuid(_), do: nil

  # X3: a pointer that is not a well-formed UUID is treated as absent,
  # never sent into an `in ^uuids` query (which would raise a CastError).
  defp valid_uuid(uuid) when is_binary(uuid) do
    case Ecto.UUID.cast(uuid) do
      {:ok, _} -> uuid
      :error -> nil
    end
  end

  defp valid_uuid(_), do: nil

  # One query for every distinct (valid) pointer uuid in the batch — live
  # folders only (X2 — the unique index is partial, a trashed twin must
  # not hide the live folder).
  defp preload_by_uuid(uuids) do
    case uuids |> Enum.reject(&is_nil/1) |> Enum.uniq() do
      [] ->
        %{}

      uuids ->
        Folder
        |> where([f], f.uuid in ^uuids and is_nil(f.trashed_at))
        |> repo().all()
        |> Map.new(&{&1.uuid, &1})
    end
  end

  # One query for every distinct legacy name in the batch, matching a live
  # folder ANYWHERE (any parent, including root) — not filtered to a
  # resolved parent, since the parent hook has not run yet for records
  # without another candidate. Grouped by name so more than one live match
  # (different parents) is visible to `resolve_entry/3` (X11). Live only
  # (X2).
  defp preload_by_name_anywhere(names) do
    case names |> Enum.reject(&is_nil/1) |> Enum.uniq() do
      [] ->
        %{}

      names ->
        Folder
        |> where([f], f.name in ^names and is_nil(f.trashed_at))
        |> repo().all()
        |> Enum.group_by(& &1.name)
    end
  end

  # One (or two, root + parented) query for every distinct (host name,
  # parent) pair used to detect a D3 collision — never a per-record query.
  # Live only (X2), and filtered back down to the exact pairs asked for
  # (the `in`/`in` combination is a cross product, not a pair match).
  defp preload_by_name_parent([]), do: %{}

  defp preload_by_name_parent(pairs) do
    {root_pairs, parent_pairs} = Enum.split_with(pairs, fn {_name, parent} -> is_nil(parent) end)

    Map.merge(preload_root_names(root_pairs), preload_parented_names(parent_pairs, pairs))
  end

  defp preload_root_names([]), do: %{}

  defp preload_root_names(root_pairs) do
    names = root_pairs |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

    Folder
    |> where([f], f.name in ^names and is_nil(f.parent_uuid) and is_nil(f.trashed_at))
    |> repo().all()
    |> Map.new(&{{&1.name, nil}, &1})
  end

  defp preload_parented_names([], _all_pairs), do: %{}

  defp preload_parented_names(parent_pairs, all_pairs) do
    names = parent_pairs |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
    parents = parent_pairs |> Enum.map(&elem(&1, 1)) |> Enum.uniq()
    pair_set = MapSet.new(all_pairs)

    Folder
    |> where([f], f.name in ^names and f.parent_uuid in ^parents and is_nil(f.trashed_at))
    |> repo().all()
    |> Enum.filter(&MapSet.member?(pair_set, {&1.name, &1.parent_uuid}))
    |> Map.new(&{{&1.name, &1.parent_uuid}, &1})
  end

  # `nil` when the pointer already matches the current (pre-move) folder —
  # nothing to back-fill. Otherwise a fun the engine runs after the move,
  # inside the same transaction, to write/repair the pointer. D7: writes
  # the owned `data` key directly (locked row, plain changeset) — no
  # context `update_*`, no Activity log, no PubSub, no full validation.
  defp after_move_fun(record, pointer, %Folder{uuid: folder_uuid}) do
    if pointer == folder_uuid do
      nil
    else
      fn -> write_pointer(record, folder_uuid) end
    end
  end

  defp write_pointer(%Location{} = location, folder_uuid),
    do: write_pointer_directly(Location, location, folder_uuid)

  defp write_pointer(%Space{} = space, folder_uuid),
    do: write_pointer_directly(Space, space, folder_uuid)

  # No `data_owned_keys`-style scoping (unlike catalogue) — merges into
  # the record's own `data` map before writing the whole map back, so
  # other keys (`featured_image_uuid`, translations) already on the record
  # survive. Re-reads the row `FOR UPDATE` right here rather than reusing
  # the plan-time struct closed over by `after_move_fun/3`: `plan/2` may
  # have loaded that struct long before this action's `after_move` runs (a
  # multi-thousand-record `--apply` run), and another editor can have
  # changed a different `data` key in between — merging into the stale
  # struct would silently discard that edit on the full-map write below.
  # The lock is only meaningful because `after_move` runs inside the
  # engine's own per-action transaction (same connection).
  defp write_pointer_directly(schema, record, folder_uuid) do
    case locked(schema, record.uuid) do
      nil ->
        {:error, :not_found}

      current ->
        data = Map.put(current.data || %{}, "files_folder_uuid", folder_uuid)

        current
        |> Ecto.Changeset.change(data: data)
        |> repo().update()
        |> case do
          {:ok, _updated} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp locked(schema, uuid) do
    schema
    |> where([r], r.uuid == ^uuid)
    |> lock("FOR UPDATE")
    |> repo().one()
  end

  # ── Pending upload folders ──────────────────────────────────────

  # X4: a folder any live record currently points at (or claims by legacy
  # name) is never independently reported/trashed as a pending folder —
  # its move (or duplicate report) action above already covers it.
  defp pending_folder_actions(pending_days, claimed_uuids) do
    cutoff = DateTime.add(DateTime.utc_now(), -pending_days * 86_400, :second)

    folders =
      Folder
      |> where([f], is_nil(f.trashed_at))
      |> where([f], like(f.name, ^"#{@pending_prefix}%"))
      |> repo().all()
      |> Enum.reject(&MapSet.member?(claimed_uuids, &1.uuid))

    counts = counts_by_folder(Enum.map(folders, & &1.uuid))

    folders
    |> Enum.map(&pending_folder_action(&1, cutoff, counts))
    |> Enum.reject(&is_nil/1)
  end

  defp pending_folder_action(folder, cutoff, counts) do
    case folder_counts(counts, folder.uuid) do
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

  # Mirrors `counts_by_folder/1`'s definition of "this folder's content"
  # (own files plus files reachable via `FolderLink`) so a folder
  # `:report`'d purely because of a linked file still names it — but
  # excludes trashed files (unlike the counts used to detect and later
  # re-verify a mismatch) so a report's file list only names files someone
  # still needs to act on.
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
  # left to `build_move_action/1` above.
  #
  # Unlike catalogue's records, `Location`/`Space` are hard-deleted (no
  # "deleted" status) — a missing record is the only way to be orphaned.
  defp orphan_actions(resolved_parents) do
    case legacy_candidate_folders(resolved_parents) do
      [] ->
        []

      candidates ->
        records_by_key = load_candidate_records(candidates)
        counts = counts_by_folder(Enum.map(candidates, fn {folder, _kind} -> folder.uuid end))

        candidates
        |> Enum.map(&orphan_action(&1, records_by_key, counts))
        |> Enum.reject(&is_nil/1)
    end
  end

  # One SQL-filtered query (X6 — prefix filter in SQL, not loaded then
  # filtered in Elixir) for every live folder at root or under a resolved
  # parent whose name starts with the locations legacy prefix.
  defp legacy_candidate_folders(parent_uuids) do
    Folder
    |> where([f], is_nil(f.trashed_at))
    |> where([f], is_nil(f.parent_uuid) or f.parent_uuid in ^parent_uuids)
    |> where([f], like(f.name, ^"#{@legacy_prefix}%"))
    |> repo().all()
    |> Enum.map(&{&1, legacy_kind(&1.name)})
    |> Enum.filter(fn {_folder, kind} -> kind end)
  end

  defp legacy_kind(name) do
    if String.starts_with?(name, @pending_prefix) do
      nil
    else
      Enum.find_value(@legacy_kinds, &legacy_kind_match(name, &1))
    end
  end

  # X7: a strict UUID regex on the suffix (36-char canonical form) — not
  # `Ecto.UUID.cast/1`, which also accepts a raw 16-byte binary and would
  # key the map differently than the record's (lowercased) uuid.
  defp legacy_kind_match(name, {prefix, kind}) do
    if String.starts_with?(name, prefix) do
      suffix = String.replace_prefix(name, prefix, "")

      if Regex.match?(@uuid_regex, suffix) do
        {kind, String.downcase(suffix)}
      end
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

  defp orphan_action({folder, {kind, uuid}}, records_by_key, counts) do
    case Map.get(records_by_key, {kind, uuid}) do
      nil ->
        folder_counts = folder_counts(counts, folder.uuid)

        %{
          source: "locations",
          kind: :orphan,
          op: :report,
          label: folder.name,
          folder: folder,
          counts: folder_counts,
          reason: orphan_reason(folder_counts)
        }

      _record ->
        nil
    end
  end

  defp orphan_reason({files, _links}), do: "record missing, #{files} file(s)"

  # ── Shared helpers ───────────────────────────────────────────────

  # X1: two grouped queries (files by folder_uuid, links by folder_uuid)
  # for the whole plan's folder set — never a query per action. Counts ALL
  # rows regardless of status (including trashed files) — the core engine
  # re-measures the same way at apply time (any row with this
  # `folder_uuid`) and aborts the action on a mismatch, so a plan-time
  # count that excluded trashed files would fail every folder holding one.
  defp counts_by_folder(folder_uuids) do
    case Enum.uniq(folder_uuids) do
      [] ->
        {%{}, %{}}

      uuids ->
        files =
          File
          |> where([f], f.folder_uuid in ^uuids)
          |> group_by([f], f.folder_uuid)
          |> select([f], {f.folder_uuid, count(f.uuid)})
          |> repo().all()
          |> Map.new()

        links =
          FolderLink
          |> where([l], l.folder_uuid in ^uuids)
          |> group_by([l], l.folder_uuid)
          |> select([l], {l.folder_uuid, count(l.uuid)})
          |> repo().all()
          |> Map.new()

        {files, links}
    end
  end

  defp folder_counts({files, links}, folder_uuid) do
    {Map.get(files, folder_uuid, 0), Map.get(links, folder_uuid, 0)}
  end

  # Fills `counts: nil` placeholders left by `build_move_action/1` with a
  # single batched lookup across every `:move` action's folder — the whole
  # plan's move-folder counts come from one pair of grouped queries (X1),
  # not one pair per action.
  defp finalize_counts(actions) do
    counts =
      actions
      |> Enum.map(fn
        %{folder: %Folder{uuid: uuid}} -> uuid
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)
      |> counts_by_folder()

    Enum.map(actions, fn
      %{folder: %Folder{uuid: uuid}} = action -> %{action | counts: folder_counts(counts, uuid)}
      action -> action
    end)
  end

  # No status filter — `Locations.delete_location/2` and
  # `Spaces.delete_space/2` are hard deletes, so every row present is live.
  defp live_locations, do: repo().all(Location)
  defp live_spaces, do: repo().all(Space)

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
