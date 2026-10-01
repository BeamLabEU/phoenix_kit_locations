# Follow-up Items for 0.5.0 — module-owned migrations, ownership, scoped access

Post-release check of CLAUDE_REVIEW.md findings against the current code on
`main`. This release had no PR (direct commits `34e5bac`, `0718a0a`); the
review applied most fixes itself. Triaged 2026-10-01.

## Fixed (pre-existing)

- ~~**BUG - CRITICAL** File events bypassed `locations.manage_all`~~ — both
  LiveViews route every file event through one `@attachment_events` clause
  gated on the live scope (`location_form_live.ex:48`, `:290`;
  `location_structure_live.ex:112`, `:218`). Uploads are only allowed for
  `manage_all` (`location_structure_live.ex:99`, `maybe_allow_uploads/2`).
  `inject_files_folder(params, nil)` removes a client pointer
  (`attachments.ex:737`), and `create_space` strips both pointers through
  `Attachments.drop_attachment_pointers/1` (`attachments.ex:445`,
  `location_structure_live.ex:261`).
- ~~**BUG - MEDIUM** Structure authorized only at mount~~ (the part the review
  fixed) — `@location_writes` re-resolve the location through
  `Policy.get_location/2` via the `location_rechecked` flag
  (`location_structure_live.ex:109-135`).
- ~~**NITPICK** Malformed uuids crashed LiveViews~~ — `space_in_location/2`
  (`location_structure_live.ex:775`) and `PlacePicker.selectable_location/2`
  (`place_picker.ex:251`) cast before reading; `open_add_child` accepts only a
  parent from the loaded tree (`location_structure_live.ex:232`).
- ~~**NITPICK** `filter_owner/2` raised on unexpected shapes~~ — malformed list
  entries are dropped and any other value matches no rows
  (`locations.ex:645-673`).
- ~~**NITPICK** `toggle_type` accepted any uuid~~ — limited to
  `allowed_type_uuids` (active types offered plus already-linked ones)
  (`location_form_live.ex:101-103`, `:213-214`).
- ~~**NITPICK** README drift~~ — the `PlacePicker` example uses
  `Policy.owner_uuids/1` (`README.md:100`), and the Owner column, filter and
  picker are described as `manage_all`-only (`README.md:51`, `:60`).
- ~~**NITPICK** Upgrade ordering~~ — CHANGELOG says to run
  `mix phoenix_kit.update` before deploying because `Location` reads
  `owner_uuid` (`CHANGELOG.md:100-103`).

## Files touched

None — documentation only.

## Verification

Read each referenced file on current `main` and confirmed the gates, casts and
filters described above are in place. AGENTS.md records both still-live items
below (the organization-refresh landmine at `AGENTS.md:97`, the Sites TODO at
`AGENTS.md:258`). No code was changed or run in this triage.

## Open

- **BUG - MEDIUM (organization part, awaiting Max's decision)** — an open
  LiveView keeps a stale `scope.user.organization_uuid` after core's
  `Auth.set_organization` / `remove_from_organization`, which broadcast no
  scope refresh. A removed member keeps access to the organization's locations
  until the next page load. The review left this as a core gap; documented at
  `AGENTS.md:97`, not fixed in code (`lib/phoenix_kit_locations/policy.ex`
  reads the scope as given).
- **IMPROVEMENT - MEDIUM (awaiting Max's decision)** — `ProjectSitesLive` is not
  owner-scoped: it shows every location named in the project config to every
  project viewer via `Locations.get_location/1`
  (`lib/phoenix_kit_locations/web/project_sites_live.ex:68`). Scoping needs the
  viewer's scope in the hub's embed session. Documented in the moduledoc
  (`project_sites_live.ex:12`) and `AGENTS.md:258`.
