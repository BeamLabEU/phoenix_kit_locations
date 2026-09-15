# PR #16 Review — Attachment folders under a host-configured parent

- **PR:** [#16](https://github.com/BeamLabEU/phoenix_kit_locations/pull/16)
- **Author:** timujinne
- **State:** MERGED (`9737db5`; branch commits `f07d013`, `37038c0`, main merged in at `bfa4906`)
- **Reviewer:** Claude (Opus 5)
- **Date:** 2026-09-15
- **Skill applied first:** `elixir:phoenix-thinking` (LiveView upload and save paths)
- **Focus requested:** confirm the PR did not break the 0.5.0 user- and
  organization-owned locations work (`34e5bac`, `0718a0a`, `243a52b`).

## Scope

`Attachments` gains two optional host hooks:

- `:attachments_parent_folder` puts new folders under a container.
- `:attachments_folder_name` gives folders people-facing names.

`find_resource_folder/2` looks a folder up in this order:

1. the host name under the parent;
2. the deterministic name under the parent;
3. the deterministic name at the root.

The pending-folder rename writes both the name and the parent. Also included:
a CHANGELOG `Unreleased` entry and a 4-test file.

The only real host is `tim-dev-manager-andi` (`Andi.Media.Containers` /
`LocationTree`). It names folders after the sanitized resource name and adds
`" (n)"` for twins. Every location sits under one shared `Locations`
container, and each space sits under its parent's folder.

## Ownership / organization work: not broken

Checked against the 0.5.0 hardening:

- **The merge resolution kept every guard.** `git diff 1a266fe 9737db5`
  touches only the folder lookup and creation code in `attachments.ex`.
  `inject_attachment_data/3` (removes a client pointer when the scope has
  none) and `drop_attachment_pointers/1` are unchanged. So are both
  LiveViews' `@attachment_events` gates and the `manage_all`-only
  `allow_attachment_upload/1`.
- **Owner-scoped users never reach the new code.** `ensure_folder/2` (and so
  both hooks) runs only from `open_featured_image_picker` and upload progress.
  Both sit behind the live-scope `manage_all` gate. A base-`locations` user has
  no folder state, so the post-insert rename is a no-op for them.
- `Policy`, `Locations`, the migrations and the owner filters are untouched.
  The suite before any change: 430 tests, 0 failures.

The PR did, however, add a new way for one account's files to reach another
account's location. That is the first finding.

## Findings

### BUG - HIGH — a same-named location adopted another location's folder

Without a stored pointer, `find_resource_folder/2` matched a folder by the
host name alone. Host names carry no uuid. With Andi's hook, two locations
called "Warehouse", owned by different users or organizations, both map to
`Locations/Warehouse`.

The second location has no pointer yet. When a manager opens its Files card
or uploads, it found and adopted the first location's folder:

- it showed that location's floor plans and photos;
- it uploaded into that folder;
- on save, it stored the folder uuid in its own `data`.

That is the cross-account pointer 0.5.0 closed for forged client input, now
reachable through ordinary use. Spaces were worse, because names like
"Floor 1" repeat within a single parent. The create path had the mirror
problem: had the lookup missed, a taken host name failed the
`(name, parent_uuid)` unique index, and the upload failed with "Could not
prepare the files folder".

**Fixed:**

- A folder found by host name is adopted only when no *other* Location or
  Space has it in `data->>'files_folder_uuid'`. The check fails closed if the
  query errors. The two deterministic lookups carry the uuid and need no check.
- An unsaved (`:pending`) resource never adopts a folder. Andi names an
  unnamed one `"untitled"`.
- When core rejects the host name on `:name` (taken, or invalid such as over
  255 characters), create and rename retry once with the deterministic
  `location-<uuid>` name, which cannot collide. The host can rename it later
  (Andi's `reconcile` adds `" (n)"`).

**Tests:**

- *a host-named folder another location points at is not adopted*: two owned
  locations, the owner keeps its own folder;
- *opening the picker creates this location's own folder, never theirs*:
  end to end through `open_featured_image_picker/2`;
- *the pending rename falls back to the deterministic name when the host name
  is taken*;
- *an unsaved location never adopts a same-named folder*.

**Residual, not fixed:** a host-named folder nobody points at can still be
adopted by a same-named resource. This happens when a manager uploads on an
edit form and leaves without saving. Closing it would mean writing the
pointer at folder creation, outside the save the module deliberately
commits through, or dropping the host-name lookup (which then orphans that
same unsaved upload for its own location). The window is narrow (manager-only,
an abandoned edit, an identical name under the same parent), so I recorded it
here instead.

### BUG - MEDIUM — the pending-folder rename moved the folder out of its parent

`maybe_rename_pending_folder_for/2` changed from a rename to
`update_folder(folder, %{name: …, parent_uuid: parent_folder_uuid(resource, nil)})`.
Two problems:

- **Core treats this as a move.** `Storage.update_folder/3` treats an explicit
  `parent_uuid` as a move, including `nil` (move to the system root).
- **The rename passed no actor.** The pending folder was created by
  `ensure_folder/2` under the parent resolved with the real uploading actor.
  An actor-dependent hook (per-user or per-tenant containers, the reason the
  contract passes an actor) returns `nil` here and moves the freshly uploaded
  files to the storage root. `find_resource_folder/2` then misses the folder
  under the actor's parent.

The move was never needed, because the folder is already under the right
parent. The PR's moduledoc claim ("a resource created before either hook was
configured is moved into place") could not happen either: the one call site
passes a `:new` resource's pending folder.

**Fixed:**

- The rename changes only the name again.
- It now touches only folders still named `location-attachment-pending-…`.
- It takes the actor as a third argument (default `nil`), which
  `LocationFormLive` passes, so an actor-dependent *name* hook gets the same
  answer as at upload.

This is the same fix `phoenix_kit_manufacturing` shipped for its copy of this
PR (#12, 0.4.3).

**Tests:**

- *pending rename never moves the folder, even when the hook needs an actor*;
- *pending rename leaves a folder that is not pending alone*.

The PR's own *pending rename keeps the parent* test created the pending
folder at the **root** and asserted the rename moved it, so it encoded the
bug. It now creates the folder under the parent, as `ensure_folder/2` does.

### BUG - MEDIUM — a raising host hook crashed the form

`parent_folder_uuid/2` and `folder_name/2` called `apply/3` with no guard.
If a hook raised, the LiveView crashed from `handle_progress/3` mid-upload
or from opening the picker. Examples: Andi's `LocationTree.expected_parent/2`
does `Repo.get!`, a host DB error, or a mistyped hook. Before the
rename fix, the same call also ran after `create_location` had committed.
AGENTS.md's convention is that host and DB problems degrade instead of crashing.

**Fixed:** both hooks rescue, log a warning and return `nil` (storage root /
deterministic name). **Test:** *raising hooks degrade to the root and the
deterministic name*.

### NITPICK — CHANGELOG and AGENTS.md

- The `Unreleased` entry had no blank line before `## 0.5.0`, and it described
  the rename as moving the folder.
- AGENTS.md did not mention either config key.

**Fixed:** added a `### Fixed` section. The AGENTS.md Attachments bullet now
documents both hooks, the name-only rename and the claim check.

### Verified, no change

- **Without config, behaviour is unchanged.** The parent is `nil`, the name is
  deterministic, and the lookup is the old root lookup. The one extra query is
  the deterministic name under a `nil` parent, which is skipped.
- **The lookup falls back to the root and never migrates.** A pre-existing
  `location-<uuid>` folder at the root is reused where it is.
- **A hook returning a non-existent parent** fails `create_folder` on the
  `parent_uuid` foreign key, which surfaces as the existing flash and does
  not crash.
- **Trashed folders are still matched** by the name lookups. This predates
  the PR (the old `find_folder_by_name/1` did the same) and is left alone.

## Tests verified against the merged code

With `lib/` stashed back to `9737db5`, the rewritten file ran 11 tests with
7 failures. The adoption, create-fallback, rename-fallback, pending-adoption,
no-move and non-pending tests all fail, and *raising hooks* fails with the
`RuntimeError` propagating. All 11 pass with the fixes.

## Gate

- `mix format`: applied
- `mix test`: 437 tests, 0 failures (PostgreSQL available, integration tests
  ran; 430 before the review, +7 new tests)
- `mix precommit` (compile `--warnings-as-errors`, `deps.unlock --check-unused`,
  `hex.audit`, format, `credo --strict`, dialyzer): **passed**, exit 0;
  dialyzer 0 errors, 0 skips
