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

  Contract (design §9/§10 of `2026-09-15-media-reorganizer-design.md`):

    * **No configured `:attachments_parent_folder` hook → `:report`-only.**
      Orphan and pending-folder reports are still produced (informational,
      no writes); no `:move`, no `:trash`, no pointer back-fill happen.
    * **Claims are hook-independent.** Every live record's valid, live
      pointer folder is "claimed" regardless of whether a hook is
      configured — a pending folder any live record points at is never
      trashed, hook or no hook, and a claimed folder is never reported as
      an orphan even when its own name happens to match no record.
    * **A hook that raises, exits, or returns anything but `{:ok, uuid}` or
      an explicit `nil`** is a hook FAILURE: the record is skipped (no
      move planned for it) and counted into one `kind: :hook_error` report
      for the whole plan. Only an explicit `nil` means "root". Every
      `{:ok, uuid}` answer is cast through `Ecto.UUID.cast/1` and
      downcased before use — a non-UUID answer is a failure too, and an
      upper-case answer never looks "different" from the same answer
      lower-cased on the next run. A configured `{mod, fun}` that isn't
      actually callable is reported the same way, once, distinct from "no
      hook configured". The (optional) `:attachments_folder_name` hook is
      held to the same standard — a raising/garbage-returning name hook
      also counts into `:hook_error`, not a silent legacy-name fallback.
    * **An explicit `nil`/`{:ok, nil}` answer never pulls a folder that is
      currently live under a real parent out to root.** For such a
      candidate, `nil` yields only a pointer back-fill (if any); the
      folder's actual parent and name are left untouched and the record is
      counted into one `kind: :hook_nil` report for the whole plan.
    * **Current-folder lookup mirrors `Attachments.find_resource_folder/2`:**
      host-named folder under the resolved parent (unclaimed by another
      record's live pointer), then the legacy deterministic name under the
      resolved parent, then the legacy name at root. A host-named folder
      found live and unclaimed IS the current folder (already-correct
      case — the plan then only needs a pointer back-fill). Host-named and
      legacy-named both live at once, two legacy matches (parent + root),
      or two records both actually resolving to the very same live folder
      are all unresolvable — each is a `kind: :duplicate` report, never a
      `:move`. A host name already claimed (by a *different* record's live
      pointer) can't be adopted either — the desired name falls back to
      the deterministic legacy name instead (D3), same as the retry
      `Attachments.with_name_fallback/3` performs at upload time.
    * **A folder found through a record's live pointer keeps its own name**
      (never renamed) unless that name is still the legacy deterministic
      one — a record whose pointer folder still literally reads
      `location-<uuid>` / `location-space-<uuid>` gets the host name like
      any other candidate.
    * **A legacy-named folder live somewhere other than root or the
      resolved parent** (e.g. an old container from a previous layout) is
      left alone and reported `kind: :relocated` — never adopted or moved.
      Every such stray copy gets its own report, not only the first one,
      unless the copy is itself another record's claimed (adopted or
      pointed-at) folder.
    * **Two records whose resolved *targets* would coincide** (same
      `{parent, desired name}`) are reported `kind: :duplicate` instead of
      both being planned as moves (the second would collide at apply
      time).
    * Only records that already have SOME live folder (a live pointer, or
      a folder anywhere matching the legacy name) are *candidates* — a
      record with neither never triggers a (possibly writing) host hook.
    * **Candidate detection runs against the light select** (uuid/name/
      status/pointer only), but a host hook is opaque — it may read any
      column (Andi's location hook reads `space.location_uuid` and other
      fields the same way a light `Category` select without `parent_uuid`
      once made a catalogue hook plan wrong moves). Every candidate's
      record is swapped for its FULL row — one batched
      `where uuid in ^candidate_uuids` query per kind — before it ever
      reaches `attachments_parent_folder`, `attachments_folder_name`, or
      `after_move`.

  Also covers stale `location-attachment-pending-*` upload folders and
  orphaned legacy folders whose record is gone — see the section comments
  below. Unlike catalogue's records, `Location`/`Space` are hard-deleted
  (`Locations.delete_location/2`, `Spaces.delete_space/2`) — a missing
  record is the only way to be orphaned.

  ## Pointer back-fill

  `Location`/`Space` have no `data_owned_keys`-style scoped update — unlike
  catalogue, `after_move` writes the pointer with a direct, locked
  (`FOR UPDATE`) repo update of the record's own `data` map, never through
  `Locations.update_location/3` / `Spaces.update_space/3` (those run the
  full context path — `Activity.log`, PubSub, full changeset validation —
  none of which belongs inside the engine's per-action transaction, and a
  broadcast for a move that then rolls back would be a lie).
  """

  import Ecto.Query

  require Logger

  alias PhoenixKit.Modules.Storage.{Folder, FolderLink}
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
  Builds the locations' reorganizer plan. See the moduledoc for the full
  contract.

  `opts[:pending_days]` (default #{@default_pending_days}) — how old an
  empty pending folder must be before it is planned as `:trash` (or,
  without a configured hook, merely reported) instead of left alone.
  """
  @spec plan(String.t() | nil, keyword()) :: [map()]
  def plan(actor_uuid, opts \\ []) do
    pending_days = Keyword.get(opts, :pending_days, @default_pending_days)

    # R10: locations before their spaces, each ordered inserted_at/uuid —
    # a deterministic, readable report order.
    tagged_records = tag(light_locations(), :location) ++ tag(light_spaces(), :space)

    # R1: independent of whether a hook is configured — a folder any live
    # record's pointer names is never a pending-trash/orphan candidate.
    pointer_claims = live_pointer_claims(tagged_records)

    {resource_actions, resolved_claims, resolved_parents, hook_on?} =
      case hook_status() do
        :ok ->
          {actions, claims, parents} =
            build_resource_plan(tagged_records, pointer_claims, actor_uuid)

          {actions, claims, parents, true}

        {:not_callable, mod, fun} ->
          {[not_callable_hook_action(mod, fun)], claimed_folder_uuids([], [], [], []), [], false}

        {:bad_config, other} ->
          {[bad_config_hook_action(other)], claimed_folder_uuids([], [], [], []), [], false}

        :none ->
          {[], claimed_folder_uuids([], [], [], []), [], false}
      end

    claimed_uuids = MapSet.union(pointer_claims, resolved_claims)

    resource_actions ++
      orphan_actions(resolved_parents, claimed_uuids) ++
      pending_folder_actions(pending_days, claimed_uuids, hook_on?)
  end

  # ── Locations / spaces ──────────────────────────────────────────

  # T3: a configured `{mod, fun}` that is not actually callable (a typo,
  # a removed function) is a distinct failure from "no hook configured at
  # all" — it must not silently degrade to report-only (E1) without
  # telling the owner why nothing moved. U7/V3: anything configured that
  # is not even a `{mod, fun}` shape (garbage config) is the SAME
  # failure — never silently treated as "no hook configured" either.
  defp hook_status do
    case Application.get_env(:phoenix_kit_locations, :attachments_parent_folder) do
      nil ->
        :none

      {mod, fun} when is_atom(mod) and is_atom(fun) ->
        if callable?(mod, fun), do: :ok, else: {:not_callable, mod, fun}

      other ->
        {:bad_config, other}
    end
  end

  defp callable?(mod, fun) do
    Code.ensure_loaded?(mod) and
      (function_exported?(mod, fun, 3) or function_exported?(mod, fun, 2))
  end

  defp not_callable_hook_action(mod, fun) do
    %{
      source: "locations",
      kind: :hook_error,
      op: :report,
      label: "attachments parent hook",
      counts: nil,
      reason: "configured parent hook {#{inspect(mod)}, #{inspect(fun)}} is not callable"
    }
  end

  defp bad_config_hook_action(other) do
    %{
      source: "locations",
      kind: :hook_error,
      op: :report,
      label: "attachments parent hook",
      counts: nil,
      reason:
        "configured parent hook #{inspect(other)} is not a {module, function} tuple — " <>
          "invalid config, not callable"
    }
  end

  defp tag(records, kind),
    do: Enum.map(records, fn {record, pointer} -> {record, pointer, kind} end)

  # E1/D1: candidate detection needs no hook call, so build_resource_plan
  # is only reached at all when a parent hook is configured (see plan/2).
  # Even then, a record with no existing live folder (pointer or legacy
  # name) never triggers the host's (possibly writing) hooks.
  defp build_resource_plan(tagged_records, pointer_claims, actor_uuid) do
    {mod, fun} = Application.get_env(:phoenix_kit_locations, :attachments_parent_folder)

    prelim =
      Enum.map(tagged_records, fn {record, pointer, kind} ->
        %{
          record: record,
          kind: kind,
          pointer: valid_uuid(pointer),
          legacy_name: legacy_name(record)
        }
      end)

    by_pointer = preload_by_uuid(Enum.map(prelim, & &1.pointer))
    by_name = preload_by_name_anywhere(Enum.map(prelim, & &1.legacy_name))

    # R10/T6: candidates keep the light query's deterministic order
    # (location → space, each by inserted_at/uuid) via `order_index` —
    # splitting into pointer/name tracks below and re-merging them must
    # not scramble it.
    candidates =
      prelim
      |> Enum.filter(fn p ->
        (p.pointer && Map.has_key?(by_pointer, p.pointer)) ||
          Map.has_key?(by_name, p.legacy_name)
      end)
      |> hydrate_candidate_records()
      |> Enum.with_index()
      |> Enum.map(fn {c, idx} -> Map.put(c, :order_index, idx) end)

    {resolved_all, hook_error_labels} =
      resolve_candidates(candidates, by_pointer, by_name, mod, fun, pointer_claims, actor_uuid)

    # U4: orphan scope = every parent a hook call for ANY candidate
    # actually returned, regardless of that candidate's outcome (moved,
    # relocated, duplicate, hook_nil) — captured from the raw hook
    # answers, before `apply_nil_root_guard` below can rewrite a
    # hook-nil entry's `parent_uuid` to its folder's own (a value the
    # hook never returned). Never derived from where a folder happens to
    # end up living.
    resolved_parents =
      resolved_all
      |> Enum.map(& &1.parent_uuid)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    resolved_all =
      resolved_all
      |> Enum.sort_by(& &1.order_index)
      |> Enum.map(&apply_nil_root_guard/1)

    hook_nil_labels =
      resolved_all |> Enum.filter(& &1.hook_nil) |> Enum.map(& &1.record.name)

    {ambiguous, normal} = Enum.split_with(resolved_all, & &1.ambiguous)
    {with_folder, without_folder} = Enum.split_with(normal, & &1.folder)

    {shared, unique} = split_shared(with_folder)

    # E3/F6/U2: convergence collisions are only meaningful among entries
    # that actually need to move — a folder already sitting exactly
    # where it belongs (`noop_move?`) can never collide with anything at
    # apply time, so it must never be swept into a `:duplicate` report
    # merely for sharing its resolved name with a real mover.
    {movers, _noops} =
      Enum.split_with(unique, &(!noop_move?(&1.folder, &1.parent_uuid, &1.name)))

    {converging, _solo_movers} = split_converging(movers)

    converging_record_uuids = converging |> List.flatten() |> MapSet.new(& &1.record.uuid)

    move_actions =
      unique
      |> Enum.reject(&MapSet.member?(converging_record_uuids, &1.record.uuid))
      |> Enum.map(&build_move_action/1)
      |> Enum.reject(&is_nil/1)

    dup_actions = Enum.map(ambiguous, &build_ambiguous_duplicate_action/1)
    shared_actions = Enum.map(shared, &build_shared_duplicate_action/1)
    converging_actions = Enum.map(converging, &build_converging_duplicate_action/1)
    hook_error_actions = hook_error_action(hook_error_labels)
    hook_nil_actions = hook_nil_action(hook_nil_labels)

    claimed = claimed_folder_uuids(unique, ambiguous, shared, converging)
    all_claimed = MapSet.union(claimed, pointer_claims)

    # F5/T5: every live legacy-named copy other than the record's adopted
    # current folder (if any) gets its own `:relocated` report — all of
    # them, not only the first — except a copy that is itself another
    # record's claimed (adopted) folder, which is never also reported as
    # relocated. U9: includes `ambiguous` too — a THIRD live copy beyond
    # the two the duplicate report already names must still surface here,
    # not be dropped.
    stray_actions =
      stray_relocated_actions(with_folder ++ without_folder ++ ambiguous, all_claimed)

    all_actions =
      move_actions ++
        dup_actions ++
        shared_actions ++
        converging_actions ++ stray_actions ++ hook_error_actions ++ hook_nil_actions

    {finalize_counts(all_actions), claimed, resolved_parents}
  end

  # F5/T5: a live legacy-named copy of a record other than its adopted
  # current folder — one `:relocated` report per copy, all of them, never
  # just the first. A copy that is itself claimed by another record (its
  # own resolved current folder, or a live pointer) is excluded — a
  # claimed folder is never also reported `:relocated`.
  # Batched over the whole plan so naming a stray copy's actual
  # (third-party) parent for the report never costs a query per copy.
  defp stray_relocated_actions(entries, claimed) do
    pairs =
      Enum.flat_map(entries, fn entry ->
        entry.stray_legacy
        |> Enum.reject(&MapSet.member?(claimed, &1.uuid))
        |> Enum.map(&{entry, &1})
      end)

    parent_names = load_stray_parent_names(pairs)

    Enum.map(pairs, fn {entry, folder} ->
      build_relocated_action(%{
        record: entry.record,
        kind: entry.kind,
        relocated: folder,
        target_parent_uuid: entry.parent_uuid,
        parent_names: parent_names
      })
    end)
  end

  # Only parents that are neither root nor the record's own target need a
  # name — those two cases already have their own wording.
  defp load_stray_parent_names(pairs) do
    uuids =
      pairs
      |> Enum.map(fn {entry, folder} -> other_parent_uuid(folder, entry.parent_uuid) end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    case uuids do
      [] ->
        %{}

      uuids ->
        Folder
        |> where([f], f.uuid in ^uuids)
        |> select([f], {f.uuid, f.name})
        |> repo().all()
        |> Map.new()
    end
  end

  defp other_parent_uuid(%Folder{parent_uuid: nil}, _target_parent_uuid), do: nil
  defp other_parent_uuid(%Folder{parent_uuid: parent_uuid}, parent_uuid), do: nil
  defp other_parent_uuid(%Folder{parent_uuid: parent_uuid}, _target_parent_uuid), do: parent_uuid

  # F1: an explicit `nil`/`{:ok, nil}` answer from the parent hook never
  # pulls a folder that currently lives under a real parent out to root —
  # only a pointer back-fill (if any) is kept; the parent and name stay
  # exactly as they are (no rename either). Named/pointer resolution above
  # already guarantees `entry.folder` is the record's actual current
  # folder when set, so this is safe regardless of resolution route.
  defp apply_nil_root_guard(%{folder: %Folder{parent_uuid: parent_uuid}} = entry)
       when not is_nil(parent_uuid) and is_nil(entry.parent_uuid) do
    entry
    |> Map.put(:parent_uuid, parent_uuid)
    |> Map.put(:name, nil)
    |> Map.put(:hook_nil, true)
  end

  defp apply_nil_root_guard(entry), do: Map.put(entry, :hook_nil, false)

  defp legacy_name(record) do
    case Attachments.folder_name_for(record) do
      {:ok, name} -> name
      :pending -> nil
    end
  end

  # R9: candidate detection above only needed the light select — a host
  # hook is opaque and may read any column, so every candidate's `record`
  # is swapped here for its FULL row before it can ever reach a hook (or
  # `after_move`'s closure). One batched `where uuid in ^uuids` query per
  # kind, ordered deterministically. A candidate whose row vanished
  # between the light load and here (hard-deleted mid-plan) simply keeps
  # its light record and proceeds through the rest of the plan like any
  # other candidate — there is no separate check that excludes it.
  defp hydrate_candidate_records(candidates) do
    full_by_key = full_records_by_kind_and_uuid(candidates)

    Enum.map(candidates, fn p ->
      case Map.get(full_by_key, {p.kind, p.record.uuid}) do
        nil -> p
        full_record -> %{p | record: full_record}
      end
    end)
  end

  defp full_records_by_kind_and_uuid(candidates) do
    {location_uuids, space_uuids} =
      Enum.reduce(candidates, {[], []}, fn
        %{kind: :location, record: %{uuid: uuid}}, {locs, spaces} -> {[uuid | locs], spaces}
        %{kind: :space, record: %{uuid: uuid}}, {locs, spaces} -> {locs, [uuid | spaces]}
      end)

    Map.merge(
      full_records_by_uuid(Location, :location, location_uuids),
      full_records_by_uuid(Space, :space, space_uuids)
    )
  end

  defp full_records_by_uuid(_schema, _kind, []), do: %{}

  defp full_records_by_uuid(schema, kind, uuids) do
    schema
    |> where([r], r.uuid in ^Enum.uniq(uuids))
    |> order_by([r], asc: r.inserted_at, asc: r.uuid)
    |> repo().all()
    |> Map.new(&{{kind, &1.uuid}, &1})
  end

  # R2: resolves the desired parent for every candidate via the host's
  # exact hook, distinguishing an explicit `nil` (root) from a hook that
  # raised/exited/returned anything else (failure — the record is
  # skipped, never treated as "root"). Only candidates with a live
  # pointer folder are separated from the rest (`pointer_track`) — those
  # never need the batched host-name-under-parent lookup (R3/R8) that the
  # remaining candidates (`name_track`) do.
  defp resolve_candidates(candidates, by_pointer, by_name, mod, fun, pointer_claims, actor_uuid) do
    {pointer_track, name_track, hook_error_labels} =
      Enum.reduce(candidates, {[], [], []}, fn p, acc ->
        sort_candidate(p, by_pointer, mod, fun, actor_uuid, acc)
      end)

    pointer_results =
      pointer_track |> Enum.reverse() |> Enum.map(&resolve_pointer_entry(&1, by_name, actor_uuid))

    {pointer_entries, pointer_error_labels} = split_hook_errors(pointer_results)

    {name_entries, name_error_labels} =
      resolve_name_entries(Enum.reverse(name_track), by_name, pointer_claims, actor_uuid)

    all_error_labels = hook_error_labels ++ pointer_error_labels ++ name_error_labels
    {pointer_entries ++ name_entries, all_error_labels}
  end

  # U8: keeps the record label of each hook failure (rather than only a
  # count) so the aggregated `:hook_error` report can name the affected
  # records.
  defp split_hook_errors(results) do
    {errors, ok} = Enum.split_with(results, &match?({:hook_error, _label}, &1))
    {ok, Enum.map(errors, fn {:hook_error, label} -> label end)}
  end

  defp sort_candidate(p, by_pointer, mod, fun, actor_uuid, {ptrs, names, errs}) do
    case resolve_parent(mod, fun, p.kind, actor_uuid, p.record) do
      {:ok, parent_uuid} ->
        base = Map.put(p, :parent_uuid, parent_uuid)
        pointer_folder = p.pointer && Map.get(by_pointer, p.pointer)
        push_candidate(base, pointer_folder, ptrs, names, errs)

      :error ->
        {ptrs, names, [p.record.name | errs]}
    end
  end

  defp push_candidate(base, nil, ptrs, names, errs), do: {ptrs, [base | names], errs}

  defp push_candidate(base, pointer_folder, ptrs, names, errs),
    do: {[Map.put(base, :pointer_folder, pointer_folder) | ptrs], names, errs}

  defp resolve_parent(mod, fun, kind, actor_uuid, resource) do
    cond do
      Code.ensure_loaded?(mod) and function_exported?(mod, fun, 3) ->
        guarded_hook_call(fn -> apply(mod, fun, [kind, actor_uuid, resource]) end, mod, fun, kind)

      Code.ensure_loaded?(mod) and function_exported?(mod, fun, 2) ->
        guarded_hook_call(fn -> apply(mod, fun, [kind, actor_uuid]) end, mod, fun, kind)

      true ->
        :error
    end
  end

  # T1: every answer is cast through `Ecto.UUID.cast/1` and downcased —
  # `{:ok, ""}` / `{:ok, "not-a-uuid"}` are hook FAILURES (`:error`), never
  # sent into a later `in ^uuids` query (which would raise a CastError and
  # take down the whole plan). This also normalises case, so an upper-case
  # parent answer never looks "different" from the same lower-case answer
  # on the next run. F2: an explicit `{:ok, nil}` or bare `nil` means root.
  # U6: every log line names the failing hook (`{mod, fun}`) and the
  # record kind it was called for — including a BAD RETURN value, not
  # only a raise/exit.
  defp guarded_hook_call(fun, mod, fun_name, kind) do
    case fun.() do
      {:ok, uuid} when is_binary(uuid) ->
        case valid_uuid(uuid) do
          nil ->
            log_bad_hook_return(:parent, mod, fun_name, kind, {:ok, uuid})
            :error

          cast ->
            {:ok, cast}
        end

      {:ok, nil} ->
        {:ok, nil}

      nil ->
        {:ok, nil}

      other ->
        log_bad_hook_return(:parent, mod, fun_name, kind, other)
        :error
    end
  rescue
    error ->
      Logger.warning(
        "Attachments parent hook {#{inspect(mod)}, #{inspect(fun_name)}} (#{kind}) raised: " <>
          Exception.format(:error, error, __STACKTRACE__)
      )

      :error
  catch
    error_kind, reason ->
      Logger.warning(
        "Attachments parent hook {#{inspect(mod)}, #{inspect(fun_name)}} (#{kind}) " <>
          "#{error_kind}: #{inspect(reason)}"
      )

      :error
  end

  defp log_bad_hook_return(hook, mod, fun_name, kind, value) do
    Logger.warning(
      "Attachments #{hook} hook {#{inspect(mod)}, #{inspect(fun_name)}} (#{kind}) returned " <>
        "an unexpected value: #{inspect(value)}"
    )
  end

  # D6/E2: a folder found through the record's live pointer keeps its own
  # name — UNLESS that name is still the legacy deterministic one, in
  # which case it gets the host name like any other candidate (R8: the
  # name hook is skipped entirely otherwise).
  defp resolve_pointer_entry(%{pointer_folder: folder} = d, by_name, actor_uuid) do
    name_result =
      if folder.name == d.legacy_name do
        resolve_folder_name(d.record, actor_uuid, d.kind)
      else
        {:ok, nil}
      end

    case name_result do
      :error ->
        {:hook_error, d.record.name}

      {:ok, name} ->
        %{
          record: d.record,
          kind: d.kind,
          pointer: d.pointer,
          legacy_name: d.legacy_name,
          parent_uuid: d.parent_uuid,
          order_index: d.order_index,
          name: name,
          folder: folder,
          via: :pointer,
          ambiguous: nil,
          stray_legacy: stray_legacy_matches(d.legacy_name, by_name, folder.uuid)
        }
    end
  end

  # F5/T5: every live match for the legacy name other than the record's
  # own current folder — a list, not just the first one. A live record's
  # actual current folder (its pointer, or a host/legacy match) can still
  # leave SEPARATE legacy-named folders live somewhere else entirely — not
  # this record's current folder, and not an orphan either (the record is
  # alive) — so each of them gets its own report so none is silently
  # dropped.
  defp stray_legacy_matches(legacy_name, by_name, current_folder_uuid) do
    by_name
    |> Map.get(legacy_name, [])
    |> Enum.reject(&(&1.uuid == current_folder_uuid))
  end

  # R3: the module's own lookup order for a record with no live pointer —
  # host-named folder under the resolved parent (D3: only when NOT already
  # claimed by a different record's live pointer), then the legacy name
  # under the resolved parent, then the legacy name at root. Host-named
  # and legacy-named both live at once (or two legacy matches) are
  # unresolvable duplicates. A legacy match that is live under neither the
  # resolved parent nor root is left alone and reported `:relocated`. F3:
  # a candidate whose name hook fails is skipped entirely (counted as a
  # hook error) before the batched host-name lookup even runs for it.
  defp resolve_name_entries(candidates, by_name, pointer_claims, actor_uuid) do
    {ok_candidates, error_labels} =
      Enum.reduce(candidates, {[], []}, fn c, {acc, errs} ->
        case resolve_folder_name(c.record, actor_uuid, c.kind) do
          {:ok, name} -> {[Map.put(c, :host_name, name) | acc], errs}
          :error -> {acc, [c.record.name | errs]}
        end
      end)

    with_host_name = Enum.reverse(ok_candidates)
    host_map = preload_host_named_under_parent(with_host_name)

    entries =
      Enum.map(with_host_name, &resolve_name_entry(&1, by_name, host_map, pointer_claims))

    {entries, error_labels}
  end

  # Only host names that actually differ from the deterministic legacy
  # name need this lookup — when they're equal there is nothing to adopt
  # or fall back from.
  defp preload_host_named_under_parent(entries) do
    pairs =
      entries
      |> Enum.filter(&(&1.host_name != &1.legacy_name))
      |> Enum.map(&{&1.host_name, &1.parent_uuid})
      |> Enum.uniq()

    case pairs do
      [] ->
        %{}

      pairs ->
        {root_pairs, parent_pairs} =
          Enum.split_with(pairs, fn {_name, parent} -> is_nil(parent) end)

        Map.merge(preload_root_names(root_pairs), preload_parented_names(parent_pairs, pairs))
    end
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

  # D3: a host-named folder that physically exists is only adoptable when
  # it isn't already another (necessarily different — this entry has no
  # live pointer of its own) live record's claimed pointer target; a
  # claimed one can't be renamed onto, so the desired name falls back to
  # the deterministic legacy name instead of colliding with it.
  defp resolve_name_entry(d, by_name, host_map, pointer_claims) do
    raw_host_folder = Map.get(host_map, {d.host_name, d.parent_uuid})
    host_claimed? = raw_host_folder && MapSet.member?(pointer_claims, raw_host_folder.uuid)
    host_folder = unless host_claimed?, do: raw_host_folder
    desired_name = if host_claimed?, do: d.legacy_name, else: d.host_name

    matches = Map.get(by_name, d.legacy_name, [])
    under_parent = d.parent_uuid && Enum.find(matches, &(&1.parent_uuid == d.parent_uuid))
    at_root = Enum.find(matches, &is_nil(&1.parent_uuid))
    legacy_folder = under_parent || at_root

    base = %{
      record: d.record,
      kind: d.kind,
      pointer: d.pointer,
      legacy_name: d.legacy_name,
      parent_uuid: d.parent_uuid,
      order_index: d.order_index,
      folder: nil,
      via: nil,
      name: nil,
      ambiguous: nil,
      stray_legacy: []
    }

    # F5: every match live under neither the resolved parent nor root —
    # all of them, not only the first — left over once the chosen
    # `legacy_folder` (if any) is accounted for. Only meaningful for the
    # "host wins" / "legacy wins" / "nothing resolves" branches below; the
    # ambiguous branches already consume every match into their own
    # report.
    stray_legacy = Enum.reject(matches, &(&1 == legacy_folder))

    base
    |> resolve_name_entry_result(
      desired_name,
      host_folder,
      legacy_folder,
      under_parent,
      at_root,
      matches,
      stray_legacy
    )
    |> apply_name_track_f1(d.parent_uuid, matches)
  end

  # U1/F1 on the name track: the hook answered root (`d.parent_uuid ==
  # nil`) and nothing else resolved a current folder (no host name, no
  # legacy match at root or under the resolved — root — parent), but a
  # legacy-named folder already lives under some OTHER real parent.
  # `find_resource_folder(parent: nil)` only ever looks at root, so
  # without this the link stays broken forever. Instead of leaving the
  # record with no current folder (which would report every live match
  # as `:relocated`), adopt that folder as the current one — parent and
  # name left exactly as they are — and let the caller-wide
  # `apply_nil_root_guard/1` pass turn this into a pointer back-fill
  # only, counted as `:hook_nil`, never a `:move` to root.
  # R5-1: TWO (or more) live legacy copies under different real parents can
  # never be picked between deterministically from an unordered query result
  # — adopting whichever the database happens to return first is a bug, not
  # a resolution. Sorted by uuid so the pair named in the report is at least
  # stable across runs. This is reported the same way as the module's other
  # unresolvable pairs (host+legacy, under_parent+at_root) — `:duplicate`,
  # no adoption, no move, no back-fill — and, because `entry.folder` stays
  # `nil`, `apply_nil_root_guard/1` never counts the record into
  # `:hook_nil` either. Any further live copy beyond the reported pair still
  # gets its own `:relocated` report via `stray_legacy` (U9 parity).
  defp apply_name_track_f1(%{folder: nil, ambiguous: nil} = result, nil, matches) do
    case matches |> Enum.filter(&(!is_nil(&1.parent_uuid))) |> Enum.sort_by(& &1.uuid) do
      [] ->
        result

      [folder] ->
        %{
          result
          | folder: folder,
            via: :name,
            stray_legacy: Enum.reject(matches, &(&1 == folder))
        }

      [folder1, folder2 | _rest] ->
        %{
          result
          | ambiguous: {folder1, folder2},
            stray_legacy: Enum.reject(matches, &(&1.uuid in [folder1.uuid, folder2.uuid]))
        }
    end
  end

  defp apply_name_track_f1(result, _hook_parent_uuid, _matches), do: result

  # U9/F5: the ambiguous pair claims two folders, but any FURTHER live
  # legacy-named copy is not part of the ambiguity at all — it must still
  # get its own `:relocated` report (via `stray_relocated_actions/2`
  # downstream), never silently dropped just because this record already
  # has a duplicate report.
  defp resolve_name_entry_result(
         base,
         _name,
         host_folder,
         legacy_folder,
         _under,
         _root,
         matches,
         _stray
       )
       when not is_nil(host_folder) and not is_nil(legacy_folder) do
    stray = Enum.reject(matches, &(&1.uuid in [host_folder.uuid, legacy_folder.uuid]))
    %{base | ambiguous: {host_folder, legacy_folder}, stray_legacy: stray}
  end

  defp resolve_name_entry_result(
         base,
         _name,
         _host_folder,
         _legacy_folder,
         under_parent,
         at_root,
         matches,
         _stray
       )
       when not is_nil(under_parent) and not is_nil(at_root) do
    stray = Enum.reject(matches, &(&1.uuid in [under_parent.uuid, at_root.uuid]))
    %{base | ambiguous: {under_parent, at_root}, stray_legacy: stray}
  end

  defp resolve_name_entry_result(
         base,
         name,
         host_folder,
         _legacy_folder,
         _under,
         _root,
         _matches,
         stray_legacy
       )
       when not is_nil(host_folder) do
    %{base | folder: host_folder, via: :name, name: name, stray_legacy: stray_legacy}
  end

  defp resolve_name_entry_result(
         base,
         name,
         _host_folder,
         legacy_folder,
         _under,
         _root,
         _matches,
         stray_legacy
       )
       when not is_nil(legacy_folder) do
    %{base | folder: legacy_folder, via: :name, name: name, stray_legacy: stray_legacy}
  end

  # Nothing resolves as the current folder at all — every live match is a
  # stray copy, reported `:relocated` (F5: every one of them).
  defp resolve_name_entry_result(
         base,
         _name,
         _host_folder,
         _legacy_folder,
         _under,
         _root,
         matches,
         _stray
       ),
       do: %{base | stray_legacy: matches}

  # Splits entries whose current folder is claimed by exactly one record
  # (`unique`) from those two or more records resolve to the very same
  # live folder (`shared`, X5) — order-preserving (a plain `group_by`
  # would scramble R10's enumeration order).
  defp split_shared(entries) do
    freq = Enum.frequencies_by(entries, & &1.folder.uuid)
    {shared_entries, unique} = Enum.split_with(entries, &(Map.get(freq, &1.folder.uuid) > 1))
    shared_groups = shared_entries |> Enum.group_by(& &1.folder.uuid) |> Map.values()
    {shared_groups, unique}
  end

  # R7/E3: two records whose *desired* target (parent + name, or parent +
  # the folder's own kept name when `name` is nil) coincide — the second
  # move would collide with the first at apply time.
  defp split_converging(entries) do
    freq = Enum.frequencies_by(entries, &convergence_key/1)

    {converging_entries, solo} =
      Enum.split_with(entries, &(Map.get(freq, convergence_key(&1)) > 1))

    converging_groups = converging_entries |> Enum.group_by(&convergence_key/1) |> Map.values()
    {converging_groups, solo}
  end

  defp convergence_key(entry), do: {entry.parent_uuid, entry.name || entry.folder.name}

  defp claimed_folder_uuids(unique, ambiguous, shared_groups, converging_groups) do
    unique_uuids = Enum.map(unique, & &1.folder.uuid)

    ambiguous_uuids =
      Enum.flat_map(ambiguous, fn %{ambiguous: {f1, f2}} -> [f1.uuid, f2.uuid] end)

    shared_uuids = Enum.flat_map(shared_groups, fn [%{folder: f} | _] -> [f.uuid] end)

    converging_uuids =
      Enum.flat_map(converging_groups, fn group -> Enum.map(group, & &1.folder.uuid) end)

    MapSet.new(unique_uuids ++ ambiguous_uuids ++ shared_uuids ++ converging_uuids)
  end

  # A `:move` whose folder already sits at `parent_uuid` under `name` (or
  # an accepted `"name (N)"` suffix variant) and needs no pointer back-fill
  # is a no-op — filtered here before it reaches the engine.
  defp build_move_action(entry) do
    move_action(entry, entry.name)
  end

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

  defp build_converging_duplicate_action([entry | _] = group) do
    labels = group |> Enum.map(& &1.record.name) |> Enum.uniq() |> Enum.join(", ")
    {parent_uuid, name} = convergence_key(entry)
    parent_label = parent_uuid || "root"

    %{
      source: "locations",
      kind: :duplicate,
      label: labels,
      op: :report,
      counts: nil,
      reason:
        "multiple records would move to the same destination (parent #{parent_label}, name #{name}): #{labels}"
    }
  end

  defp build_relocated_action(%{record: record, kind: kind, relocated: folder} = ctx) do
    reason =
      relocated_reason(
        folder,
        kind,
        Map.get(ctx, :target_parent_uuid),
        Map.get(ctx, :parent_names, %{})
      )

    %{
      source: "locations",
      kind: :relocated,
      op: :report,
      label: record.name,
      folder: folder,
      counts: nil,
      reason: reason
    }
  end

  # F5: the reason names the copy's actual place — at the media root,
  # already under the very parent the record is headed to (where an
  # eventual move will land next to it as a `"name (N)"` suffixed twin),
  # or by name under a genuine third-party parent — instead of a blanket
  # "under a different parent" that reads wrong for all three cases.
  defp relocated_reason(%Folder{parent_uuid: nil} = folder, kind, _target_parent_uuid, _names) do
    "legacy folder #{folder.uuid} (#{kind}) is live at the media root — left alone, never adopted"
  end

  defp relocated_reason(%Folder{parent_uuid: parent_uuid} = folder, kind, parent_uuid, _names) do
    "legacy folder #{folder.uuid} (#{kind}) is already live as a twin under the target parent " <>
      "— left alone; an eventual move there will collide, landing as \"name (N)\""
  end

  defp relocated_reason(
         %Folder{parent_uuid: parent_uuid} = folder,
         kind,
         _target_parent_uuid,
         names
       ) do
    parent_label = Map.get(names, parent_uuid, parent_uuid)

    "legacy folder #{folder.uuid} (#{kind}) is live under #{parent_label} — left alone, never adopted"
  end

  # F3: the (optional) `:attachments_folder_name` hook, called directly
  # (not through `Attachments.folder_name/2`, which is deliberately
  # defensive for the live UI) so a raising/garbage-returning hook is a
  # reportable failure here instead of a silent legacy-name fallback. Not
  # configured (unset) is NOT a failure — it is simply "no host name",
  # same as `Attachments.folder_name/2` treats it. U7/V3: configured but
  # not a `{mod, fun}` shape, or a `{mod, fun}` that is not actually
  # callable, are BOTH the same failure — parity with the parent hook.
  defp resolve_folder_name(record, actor_uuid, kind) do
    case Application.get_env(:phoenix_kit_locations, :attachments_folder_name) do
      nil ->
        {:ok, legacy_name(record)}

      {mod, fun} when is_atom(mod) and is_atom(fun) ->
        resolve_configured_folder_name(mod, fun, record, actor_uuid, kind)

      other ->
        log_bad_hook_config(kind, other)
        :error
    end
  end

  defp resolve_configured_folder_name(mod, fun, record, actor_uuid, kind) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, fun, 2) do
      case guarded_name_hook_call(mod, fun, record, actor_uuid, kind) do
        {:ok, nil} -> {:ok, legacy_name(record)}
        {:ok, name} -> {:ok, name}
        :error -> :error
      end
    else
      Logger.warning(
        "Attachments name hook {#{inspect(mod)}, #{inspect(fun)}} (#{kind}) is not callable"
      )

      :error
    end
  end

  defp log_bad_hook_config(kind, other) do
    Logger.warning(
      "Attachments name hook #{inspect(other)} (#{kind}) is not a {module, function} tuple"
    )
  end

  # U6: mirrors `guarded_hook_call/4` — every log line names the hook
  # `{mod, fun}` and the record kind, and a bad RETURN value is logged
  # too (not only a raise/exit).
  defp guarded_name_hook_call(mod, fun, record, actor_uuid, kind) do
    case apply(mod, fun, [record, actor_uuid]) do
      {:ok, name} when is_binary(name) and name != "" -> {:ok, name}
      nil -> {:ok, nil}
      other -> bad_name_hook_return(mod, fun, kind, other)
    end
  rescue
    error ->
      Logger.warning(
        "Attachments name hook {#{inspect(mod)}, #{inspect(fun)}} (#{kind}) raised: " <>
          Exception.format(:error, error, __STACKTRACE__)
      )

      :error
  catch
    error_kind, reason ->
      Logger.warning(
        "Attachments name hook {#{inspect(mod)}, #{inspect(fun)}} (#{kind}) " <>
          "#{error_kind}: #{inspect(reason)}"
      )

      :error
  end

  defp bad_name_hook_return(mod, fun, kind, value) do
    log_bad_hook_return(:name, mod, fun, kind, value)
    :error
  end

  # R5/X3: a pointer that is not a well-formed UUID is treated as absent,
  # never sent into an `in ^uuids` query (which would raise a CastError).
  # Returns the CAST/downcased value — not the raw string — so an
  # upper-case pointer still matches the (lower-case) keys `by_pointer`
  # and the live-claims set are keyed by.
  defp valid_uuid(uuid) when is_binary(uuid) do
    case Ecto.UUID.cast(uuid) do
      {:ok, cast} -> cast
      :error -> nil
    end
  end

  defp valid_uuid(_), do: nil

  # One query for every distinct (valid) pointer uuid in the batch — live
  # folders only (X2).
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
  # (different parents) is visible downstream. Live only (X2 — the unique
  # index is partial, a trashed twin must not hide the live folder).
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

  # R1: every valid, live pointer of every LIVE record — independent of
  # whether a parent hook is configured. Used to keep a claimed folder out
  # of the pending-trash and orphan sweeps; never triggers a hook.
  defp live_pointer_claims(tagged_records) do
    pointers =
      tagged_records
      |> Enum.map(fn {_record, pointer, _kind} -> valid_uuid(pointer) end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    Folder
    |> where([f], f.uuid in ^pointers and is_nil(f.trashed_at))
    |> select([f], f.uuid)
    |> repo().all()
    |> MapSet.new()
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
  # survive. Re-reads the row `FOR UPDATE` right here (re-checking the
  # record still exists) rather than reusing the plan-time struct closed
  # over by `after_move_fun/3`: `plan/2` may have loaded that struct long
  # before this action's `after_move` runs (a multi-thousand-record
  # `--apply` run), the record can have been hard-deleted in the meantime,
  # and another editor can have changed a different `data` key — merging
  # into the stale struct would silently discard that edit on the
  # full-map write below. The lock is only meaningful because `after_move`
  # runs inside the engine's own per-action transaction (same connection).
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

  defp hook_error_action([]), do: []

  defp hook_error_action(labels) do
    [
      %{
        source: "locations",
        kind: :hook_error,
        op: :report,
        label: "attachments parent hook",
        counts: nil,
        reason:
          "#{length(labels)} record(s) skipped: the configured parent or name hook raised, " <>
            "exited, or returned neither {:ok, uuid} nor nil (#{label_list(labels)})"
      }
    ]
  end

  # F1: one aggregated report, not one per record — mirrors hook_error_action.
  defp hook_nil_action([]), do: []

  defp hook_nil_action(labels) do
    [
      %{
        source: "locations",
        kind: :hook_nil,
        op: :report,
        label: "attachments parent hook",
        counts: nil,
        reason:
          "#{length(labels)} record(s): the parent hook answered root for a folder living " <>
            "under a parent — left in place (#{label_list(labels)})"
      }
    ]
  end

  # U8: lists up to 10 record labels so the owner can tell where to look,
  # instead of a bare count — "… and N more" once there are more than 10.
  defp label_list(labels) do
    {shown, rest} = Enum.split(labels, 10)

    case rest do
      [] -> Enum.join(shown, ", ")
      more -> Enum.join(shown, ", ") <> ", … and #{length(more)} more"
    end
  end

  # ── Pending upload folders ──────────────────────────────────────

  # X4/R1: a folder any live record currently points at is never
  # independently reported/trashed as a pending folder — its move (or
  # duplicate report) action, if any, already covers it, and `claimed`
  # includes the hook-independent pointer claims regardless.
  defp pending_folder_actions(pending_days, claimed_uuids, hook_on?) do
    cutoff = DateTime.add(DateTime.utc_now(), -pending_days * 86_400, :second)

    folders =
      Folder
      |> where([f], is_nil(f.trashed_at))
      |> where([f], like(f.name, ^"#{@pending_prefix}%"))
      |> order_by([f], asc: f.inserted_at, asc: f.uuid)
      |> repo().all()
      |> Enum.reject(&MapSet.member?(claimed_uuids, &1.uuid))

    counts = counts_by_folder(Enum.map(folders, & &1.uuid))
    files_by_folder = pending_files_by_folder(Enum.map(folders, & &1.uuid))

    folders
    |> Enum.map(&pending_folder_action(&1, cutoff, counts, files_by_folder, hook_on?))
    |> Enum.reject(&is_nil/1)
  end

  defp pending_folder_action(folder, cutoff, counts, files_by_folder, hook_on?) do
    case folder_counts(counts, folder.uuid) do
      {0, 0} ->
        if DateTime.compare(folder.inserted_at, cutoff) == :lt do
          pending_stale_action(folder, hook_on?)
        end

      {files, links} ->
        %{
          source: "locations",
          kind: :pending,
          label: folder.name,
          op: :report,
          folder: folder,
          counts: {files, links},
          reason: "pending folder still has #{pending_reason(folder.uuid, files_by_folder)}"
        }
    end
  end

  # E1: without a configured hook, a stale empty pending folder is
  # reported, never trashed.
  defp pending_stale_action(folder, true) do
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

  defp pending_stale_action(folder, false) do
    %{
      source: "locations",
      kind: :pending,
      label: folder.name,
      op: :report,
      folder: folder,
      counts: {0, 0},
      reason:
        "empty pending upload folder older than the retention window " <>
          "(no attachments hook configured — not trashed)"
    }
  end

  # R6: one batched query (home files + linked files) for every non-empty
  # pending folder in the batch — never a query per folder. The reason is
  # never empty — a folder whose only files are trashed says so
  # explicitly instead of rendering an empty file list.
  defp pending_files_by_folder(folder_uuids) do
    case folder_uuids do
      [] ->
        %{}

      uuids ->
        home_rows =
          PhoenixKit.Modules.Storage.File
          |> where([f], f.folder_uuid in ^uuids)
          |> select([f], {f.folder_uuid, f.original_file_name, f.status})
          |> repo().all()

        linked_rows =
          FolderLink
          |> join(:inner, [l], f in PhoenixKit.Modules.Storage.File, on: f.uuid == l.file_uuid)
          |> where([l, _f], l.folder_uuid in ^uuids)
          |> select([l, f], {l.folder_uuid, f.original_file_name, f.status})
          |> repo().all()

        Enum.group_by(home_rows ++ linked_rows, fn {folder_uuid, _name, _status} ->
          folder_uuid
        end)
    end
  end

  defp pending_reason(folder_uuid, files_by_folder) do
    rows = Map.get(files_by_folder, folder_uuid, [])

    live_names =
      rows
      |> Enum.reject(fn {_f, _n, status} -> status == "trashed" end)
      |> Enum.map(&elem(&1, 1))

    case live_names do
      [] -> "#{length(rows)} trashed file(s)"
      names -> "files: #{Enum.join(names, ", ")}"
    end
  end

  # ── Orphaned legacy folders ──────────────────────────────────────

  # A legacy-named folder (`location-<uuid>`, `location-space-<uuid>`) at
  # the media root or under a parent this batch's hooks resolved to, whose
  # uuid no longer names a live record, is reported so a host can collect
  # it. Never `:move`d or `:trash`ed here — this module owns no "orphans"
  # container; a legacy folder claimed by a live record (its current
  # folder, a duplicate, or a converging-target group — or simply any live
  # record's pointer target, R1/R4) is excluded — one folder gets at most
  # one action.
  defp orphan_actions(resolved_parents, claimed_uuids) do
    case legacy_candidate_folders(resolved_parents, claimed_uuids) do
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
  defp legacy_candidate_folders(parent_uuids, claimed_uuids) do
    Folder
    |> where([f], is_nil(f.trashed_at))
    |> where([f], is_nil(f.parent_uuid) or f.parent_uuid in ^parent_uuids)
    |> where([f], like(f.name, ^"#{@legacy_prefix}%"))
    |> order_by([f], asc: f.inserted_at, asc: f.uuid)
    |> repo().all()
    |> Enum.reject(&MapSet.member?(claimed_uuids, &1.uuid))
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

  # One query per record kind present among the candidates — not per
  # folder.
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

  # R9: only the uuid column — an orphan report needs nothing else off the
  # record (existence alone decides it; Location/Space are hard-deleted),
  # never the full jsonb-heavy row.
  defp load_records(schema, kind, uuids) do
    schema
    |> where([r], r.uuid in ^uuids)
    |> select([r], r.uuid)
    |> repo().all()
    |> Map.new(&{{kind, &1}, true})
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
          PhoenixKit.Modules.Storage.File
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

  # R9/R10: only the columns a plan needs (never the full jsonb-heavy
  # `data` column) — including the FKs a resource-aware host hook might
  # reasonably need once a candidate's record is swapped for its FULL row
  # (`location_uuid`/`parent_uuid` for a space) — ordered by
  # `inserted_at`/`uuid` for a deterministic, readable report order. T8:
  # the pointer is extracted via a jsonb fragment instead of selecting the
  # whole `data` column — a light row returns `{struct, pointer_uuid_or_nil}`.
  defp light_locations do
    Location
    |> order_by([l], asc: l.inserted_at, asc: l.uuid)
    |> select([l], {
      struct(l, [:uuid, :name, :status, :inserted_at]),
      fragment("?->>'files_folder_uuid'", l.data)
    })
    |> repo().all()
  end

  defp light_spaces do
    Space
    |> order_by([s], asc: s.inserted_at, asc: s.uuid)
    |> select([s], {
      struct(s, [:uuid, :name, :status, :location_uuid, :parent_uuid, :kind, :inserted_at]),
      fragment("?->>'files_folder_uuid'", s.data)
    })
    |> repo().all()
    |> spaces_parent_first()
  end

  # U5/T6: a space can nest under another space (`parent_uuid`), so a
  # plain `inserted_at` order can list a child space before its own
  # parent — the SQL order above only remains the tiebreak at each level.
  defp spaces_parent_first(spaces) do
    by_uuid = Map.new(spaces, fn {space, _pointer} = row -> {space.uuid, row} end)

    {ordered, _emitted} =
      Enum.reduce(spaces, {[], MapSet.new()}, fn row, {acc, emitted} ->
        emit_parent_first(row, by_uuid, acc, emitted)
      end)

    Enum.reverse(ordered)
  end

  defp emit_parent_first({%Space{uuid: uuid}, _pointer} = row, by_uuid, acc, emitted) do
    if MapSet.member?(emitted, uuid) do
      {acc, emitted}
    else
      # Mark `uuid` emitted before recursing into its parent — guards
      # against a (should-never-happen) cycle looping forever instead of
      # trusting the data to always be a tree.
      emitted = MapSet.put(emitted, uuid)
      {acc, emitted} = emit_parent_row(row, by_uuid, acc, emitted)
      {[row | acc], emitted}
    end
  end

  defp emit_parent_row({%Space{parent_uuid: nil}, _pointer}, _by_uuid, acc, emitted),
    do: {acc, emitted}

  defp emit_parent_row({%Space{parent_uuid: parent_uuid}, _pointer}, by_uuid, acc, emitted) do
    case Map.get(by_uuid, parent_uuid) do
      nil -> {acc, emitted}
      parent_row -> emit_parent_first(parent_row, by_uuid, acc, emitted)
    end
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
