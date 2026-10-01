# Follow-up Items for PR #16 — Attachment folders under a host-configured parent

Post-merge check of CLAUDE_REVIEW.md findings against the current code on
`main`. The review fixed its findings itself; the folder code has since moved
to core's `Storage.ResourceFolders` (`d934df5`). Triaged 2026-10-01.

## Fixed (pre-existing)

- ~~**BUG - HIGH** A same-named location adopted another location's folder~~ —
  a host-named folder is adopted only when unclaimed
  (`attachments.ex:532-556`, `ResourceFolders.resolve/1` with
  `claimed?: &claimed_by_other?/2`); an unsaved resource never adopts one
  (`:pending` branch, `attachments.ex:546`).
- ~~**Residual** a host-named folder nobody points at could still be adopted
  (abandoned edit-form upload)~~ — the folder is now found or created and the
  pointer written in one locked step (`attachments.ex:652-683`,
  `claim: &claim_folder(resource, &1)` → `ResourceFolders.write_pointer/4`).
  Fixed in `fdb953d`.
- ~~**BUG - MEDIUM** The pending-folder rename moved the folder out of its
  parent~~ — `maybe_rename_pending_folder_for/3` takes the actor and only
  renames through `ResourceFolders.name_pending/…` (`attachments.ex:461-480`;
  moduledoc at `:95` states it never moves the folder).
- ~~**BUG - MEDIUM** A raising host hook crashed the form~~ — both hooks go
  through core (`ResourceFolders.parent_uuid/4`, `ResourceFolders.host_name/3`
  at `attachments.ex:501-529`), which degrade to the root and the deterministic
  name; `d934df5` also covers a hook that exits.
- ~~**NITPICK** CHANGELOG and AGENTS.md~~ — fixed by the review; AGENTS.md
  documents both hooks.
- ~~**Verified, no change** Trashed folders still matched by name lookups~~ —
  fixed in `d934df5`: a trashed folder is no longer found by name, and a stored
  pointer to a folder trashed since is replaced on the next upload
  (`attachments.ex:86`, `:638-642`, `ResourceFolders.live_folder/1`).

## Files touched

None — documentation only.

## Verification

Read the current `attachments.ex` lookup, claim, rename and hook paths, and
the commit messages of `d934df5` and `fdb953d`, which name the fixes and add
tests to `attachments_parent_folder_test.exs`. No code was changed or run in
this triage.

## Open

None.
