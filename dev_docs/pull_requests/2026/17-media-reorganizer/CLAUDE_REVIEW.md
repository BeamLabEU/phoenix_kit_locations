# PR #17 Review — Media reorganizer source

- **PR:** [#17](https://github.com/BeamLabEU/phoenix_kit_locations/pull/17)
- **Author:** timujinne
- **State:** MERGED (`98544d0`)
- **Reviewer:** Claude (Opus 5)
- **Date:** 2026-09-16
- **Skill applied first:** `elixir:ecto-thinking` (batched queries, jsonb pointer selects, locked pointer writes)

## Scope

Adds `PhoenixKitLocations.MediaReorganizer` (about 1,600 lines) and
`media_reorganizer/0` on the module. Core's `mix phoenix_kit.media.reorganize`
collects that source and applies what it plans. `plan/2` uses the host's
`:attachments_parent_folder` / `:attachments_folder_name` hooks to work out where
each location or space folder should live. It then plans one of:

- `:move` actions, with a pointer back-fill through `after_move`;
- `:trash` for stale empty pending folders;
- `:report` actions (`:duplicate`, `:relocated`, `:orphan`, `:pending`,
  `:hook_error`, `:hook_nil`).

The PR had already been through several review rounds on the branch, and its
tests cover 66 cases. The `mix.lock` bump to core 2.24.0 (`2f05633`) landed right
before this review, so the plan was checked against core's released `Source`
contract and `Reorganizer.Action` validator, not against the design doc.

## Verified

- **Action shape vs core 2.24.0.** Every map uses only the keys in `Action`'s
  known list (`source kind label op folder parent_uuid name counts on_conflict
  after_move reason`). `label` is always a binary: location and space names are
  required, and folder names are non-null. `after_move` is `nil` or a 0-arity fn.
  There was no test for this until now (see below).
- **Hook call shapes match `Attachments`.** The parent hook is called as
  `fun(kind, actor_uuid, resource)` or `fun(kind, actor_uuid)`, and the name hook
  as `fun(resource, actor_uuid)`. `actor_uuid` is a uuid string on both sides.
- **Lookup order matches `Attachments.find_resource_folder/2`:** host name under
  the parent (only if unclaimed), then the legacy name under the parent, then the
  legacy name at the root.
- **Query cost.** The light selects pull the pointer through
  `fragment("?->>'files_folder_uuid'", data)`. Full rows are loaded in one batched
  query per kind, and only for candidates. Counts, stray-parent names and pending
  file names are all grouped queries. `in ^[]` on an empty list is safe in each
  query.
- **`write_pointer_directly/3`** re-reads the row `FOR UPDATE` inside the
  engine's transaction and merges into the current `data`, so a concurrent edit to
  another `data` key survives.
- **LIKE patterns** (`location-%`, `location-attachment-pending-%`) contain no
  `_` or `%` wildcards in the literal part.

## Findings

### BUG - MEDIUM — A failing name hook dropped that record's parent from the orphan scan — FIXED

The contract (core `Source` moduledoc, `U4`) says the orphan scope covers every
parent returned by a successful parent-hook call, whatever happens to the
candidate afterwards. `resolved_parents` was built from `resolved_all`, which
leaves out records dropped by `split_hook_errors/1` and
`resolve_name_entries/4`. When the parent hook answered `Locations` but the name
hook raised, legacy orphans under `Locations` went unreported.

**Fix:** `resolve_candidates/7` now takes the parents from `pointer_track ++
name_track`, after the parent hook has run and before the name hook runs, and
returns them as a third element. Test: *a failing name hook skips the record but
keeps its resolved parent in the orphan scope* (fails on the merged code).

### BUG - MEDIUM — A pointer folder stuck on a pending name was never renamed — FIXED

`Attachments.maybe_rename_pending_folder_for/3` renames
`location-attachment-pending-<uuid>` after the insert, but a failed rename only
logs. The pointer then names a pending-named folder. The reorganizer keeps a
pointer folder's name unless it equals the legacy `location-<uuid>` exactly, so
that folder kept its random pending name on every run. The pointer claims it, so
it was never reported as pending either, and nothing would ever surface it.

**Fix:** `module_generated_name?/2` treats both the legacy name and the pending
prefix as names the module generated itself (the owner never chose them), so
either one gets the host name like any other candidate. The name hook is still
never called for a name the owner could have chosen. Test: *pointer folder still
carrying a pending upload name → renamed to the host name* (fails on the merged
code).

### IMPROVEMENT - MEDIUM — No test that the plan passes core's `Action.new!/1` — FIXED

The tests asserted on the plain maps only. If a key were misspelled or the wrong
type, core would drop it with a warning or turn the action into an invalid-action
report, and every test here would still pass. Added a test that builds a plan
with a move and back-fill, a relocated copy, an orphan and a stale pending folder.
It asserts `Action.unknown_keys/1 == []` and runs `Action.new!/1` on every action.

### NITPICK — `suffixed_variant?/2` accepted suffixes core rejects — FIXED

The local regex `^name \(\d+\)$` matched `(0)`, `(1)` and `(02)`, and `$`
allowed a trailing newline. Core's `Action.matches_name?/2` accepts only `N >= 2`
with no leading zero. It is now aligned with core. The branch can't be reached
with the current resolution rules: a folder with a host or legacy name never
carries a suffix of a different desired name. So there is no dedicated test; the
change only prevents drift.

### NITPICK — Stale "core does not ship the engine yet" comments — FIXED

The moduledoc and the comment on `PhoenixKitLocations.media_reorganizer/0`
described core 2.23.x. Both now say that core 2.24.0 ships the `Source`
contract. They explain that `@behaviour`/`@impl` stay off because the
requirement is still `~> 2.0` (`core_pin_conformance_test` admits 2.0.0), and
that the behaviour module doesn't exist on older cores. AGENTS.md gains the
architecture line and a feature-note row.

### IMPROVEMENT - MEDIUM — Live `Attachments.find_folder_under/2` does not filter trashed folders — NOT FIXED

The reorganizer filters `trashed_at IS NULL` on every by-name lookup. The live
upload path in `Attachments` does not, so at upload time it can adopt a trashed
`location-<uuid>` folder that the reorganizer treats as absent. This predates
PR #17 and changes live upload behaviour, so it is out of scope for this review.
Recorded here so the next `Attachments` change aligns the two.

## Gate

`mix precommit` (compile --warnings-as-errors, format, credo --strict, dialyzer,
deps.unlock --check-unused, hex.audit) and the full `mix test` run after the
fixes; see the release commit.
