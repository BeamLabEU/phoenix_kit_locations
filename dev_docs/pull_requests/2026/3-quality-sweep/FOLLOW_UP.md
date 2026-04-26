# Follow-up Items for PR #3 — Quality sweep

The original quality sweep landed in commit `4dfc445` ("Bring locations
module up to quality") on top of an earlier PR #2 follow-up commit
(`a341c50`). At the time of merge there were no external reviews — the
sweep itself implemented the entire C2–C10 + part of C11 from the
workspace playbook.

This file tracks subsequent re-validation passes that bring the module
forward to the evolving post-Apr pipeline (new C-step requirements
added since the original sweep).

## Batch 2 — re-validation 2026-04-26

Second module under the post-Apr re-validation template (canonical
template: AI module, BeamLabEU/phoenix_kit_ai#5). Phase 1 PR triage
re-verified clean; Phase 2 mainly adds C-step deltas the original
sweep didn't have prompts for.

### Async UX (C5)

- ~~`phx-disable-with` on `show_delete_confirm` buttons (4 sites in
  `locations_live.ex:293/303/348/358`)~~ — **FALSE POSITIVE**.
  `show_delete_confirm` opens a modal (`@confirm_delete = {type, uuid}`)
  and is UI-state-only per AGENTS.md C5 ("`UI-state-only buttons
  (modal_close, switch_view) don't need it`"). The actual destructive
  click is the modal's confirm button (in core's
  `PhoenixKitWeb.Components.Core.Modal.confirm_modal/1`), which is
  out-of-scope for this module sweep.

### Defensive `handle_info` catch-all (C10)

- `locations_live.ex`, `location_form_live.ex`, `location_type_form_live.ex`
  had no `handle_info/2` clause at all. Phoenix.LiveView's default
  silently drops unmatched messages, but adding an explicit
  `Logger.debug` catch-all means a future PubSub subscribe (or a
  multilang-hook fall-through) won't go unnoticed in dev. Pattern matches
  the workspace sync precedent at AGENTS.md:678-680.

### `enabled?/0` `catch :exit` (AGENTS.md:911)

- `phoenix_kit_locations.ex:40-44` had only `rescue _ -> false`; added
  `catch :exit, _ -> false` so a sandbox-shutdown trap (the 1-in-N
  flake AGENTS.md:911 describes) returns the documented fallback
  rather than surfacing the exit. Matches the AI module's
  `enabled?/0` shape exactly.

### Test infrastructure (C7)

- Added `phoenix_kit_settings` table to `test/support/postgres/migrations/`.
  Mirrors core's real schema (uuid/key/value/value_json/module/
  date_added/date_updated per AGENTS.md:921-925). Without it, every
  test that triggered a `Settings.get_boolean_setting` call from the
  LV mount path (multilang languages_enabled, locations_enabled) saw
  a `relation "phoenix_kit_settings" does not exist` Logger.error.
  With the table present, the table lookup succeeds (empty row →
  default value) but core still logs a `DBConnection.OwnershipError`
  for processes outside the sandbox owner — a pre-existing log-noise
  pattern that lives upstream in core's `Settings.get_boolean_setting/2`
  Logger.error (fires *before* our outer rescue point). See AGENTS.md:1075-1076
  for the AI module's identical observation.

### Errors test pin (C8)

- `errors_test.exs` removed the `is_binary/1`-loop smell (the
  per-atom EXACT-string asserts above are sufficient pinning). Same
  shape as AI module batch 2.

### `@spec` backfill on small public surfaces (C12 #3)

- `paths.ex` — added `@spec` to all 6 public functions
  (`index/0`, `location_new/0`, `location_edit/1`, `types/0`,
  `type_new/0`, `type_edit/1`).

### Documentation (C13)

- `AGENTS.md` — added the canonical "What This Module Does NOT Have"
  section at the bottom (no PubSub, no soft-delete, no Oban, no
  external HTTP, no public API routes, no file uploads, no wizard
  form, no postal-registry validation). Pinning these in writing
  prevents future scope creep and makes review-finding triage faster.
- `README.md` — added "Error Handling" subsection (Errors atom →
  gettext message, with a one-liner example) and "Activity Logging"
  subsection. The Errors module landed in PR #3 but README didn't
  mention it; agents read the README first.

### Pinning tests (C11)

- `phoenix_kit_locations/web/locations_live_test.exs`,
  `location_form_live_test.exs`,
  `location_type_form_live_test.exs` — `handle_info` catch-all smoke
  per LV. Sends two unknown messages to `view.pid`, asserts
  `render(view)` returns a binary. If the catch-all clause regresses
  to a `FunctionClauseError`, the round-trip fails.

## Skipped / surfaced from Batch 2 (closed in Batch 3)

- ~~**Activity logging on `:error` branch.**~~ Closed in Batch 3a — see below.
- ~~**LV-level `actor_uuid:` pinning in delete tests.**~~ Closed in Batch 3b — see below.
- **Pre-existing log spam from core's `Settings.get_boolean_setting/2`.**
  Still open. See "Test infrastructure (C7)" above and AGENTS.md:1075-1076.
  Suppressing the upstream Logger.error lives in core, not this
  module.

## Batch 3 — fix-everything pass 2026-04-26

Max authorised closing every Batch-2 surfaced item. Two gaps remained
after Batch 2; both are closed here, plus a small edge-case-test
expansion that exercises new code paths.

### Batch 3a — `:error`-branch activity logging

- `locations.ex` `log_activity/5` pipe step gained an `{:error,
  %Ecto.Changeset{}}` clause that logs the same action with a
  PII-safe `%{db_pending: true, error_fields: [...]}` metadata map
  before passing the tuple through unchanged. The audit trail now
  captures the user-initiated action even when the primary write
  fails (unique-constraint violation, FK rollback, etc.).
- `sync_location_types/3` and `add_location_type/3` use the
  non-pipe `maybe_log_activity/5` directly — both got matching
  `:error`-branch calls so the pattern is uniform across all
  mutations.
- New helpers: `changeset_resource_uuid/1` (falls back to
  `changeset.data.uuid`, which is `nil` for inserts and the
  pre-existing UUID for updates), `changeset_error_metadata/1`
  (extracts the field names that errored — never the rejected
  values themselves).
- Two pre-existing "failed create does not log" tests in
  `activity_logging_test.exs` were inverted to "failed create logs
  with `db_pending: true`" — these now pin both the new behaviour
  AND the PII safety (assertions on `error_fields` membership, no
  raw value leakage).

### Batch 3b — Scope injection + LV `actor_uuid` pins

- New `test/support/hooks.ex` (`PhoenixKitLocations.Test.Hooks`)
  with an `:assign_scope` `on_mount` callback mirroring
  `phoenix_kit_hello_world/test/support/hooks.ex`. Reads
  `"phoenix_kit_test_scope"` from the test session and assigns
  `:phoenix_kit_current_scope` + `:phoenix_kit_current_user` onto
  socket assigns at LV mount.
- `test_router.ex` `live_session :locations_test` now passes
  `on_mount: {PhoenixKitLocations.Test.Hooks, :assign_scope}`.
- `LiveCase` gained `fake_scope/1` (returns a real
  `PhoenixKit.Users.Auth.Scope` struct — `cached_roles` is a list
  of role-name strings per AGENTS.md:1175 even though locations
  doesn't call `Scope.admin?/1`) and `put_test_scope/2` (plugs the
  scope into the conn session).
- Every delete test in `locations_live_test.exs` and every
  successful-save test in `location_form_live_test.exs` /
  `location_type_form_live_test.exs` now sets a fake scope and
  asserts `assert_activity_logged(action, resource_uuid: ...,
  actor_uuid: scope.user.uuid)`. Previously these tests would have
  passed silently if the LV dropped `actor_opts/1` from the call.

### Batch 3c — Edge-case tests in `locations_test.exs`

Five new tests in the `changeset validations` describe block:

- **Unicode round-trip** — name (`東京本部 — Tōkyō HQ 🗼`), city
  (`東京`), country (`日本`), public_notes (mixed Japanese + Cyrillic
  + Latin) round-trip byte-for-byte through create + reload.
- **SQL metacharacters** — five payloads (`'); DROP TABLE …`, `\"
  OR 1=1`, `<script>` tag, `\\u0000 NUL`, embedded newlines/tabs)
  insert and round-trip without crashing or escaping. Pins
  Ecto's parameterised-query behaviour at the integration level.
- **Name >255 chars** — explicit length-error structure assert
  (`{:length, kind: :max, type: :string, count: 255}`), not just
  `errors_on(cs).name`.
- **Phone >50 chars** — length validation rejects.
- **Postal code >20 chars** — length validation rejects.

## Files touched (Batch 3)

| File | Change |
|------|--------|
| `lib/phoenix_kit_locations/locations.ex` | `:error`-branch logging on log_activity + sync_location_types + add_location_type; new `changeset_error_metadata/1` + `changeset_resource_uuid/1` helpers |
| `test/support/hooks.ex` (new) | `:assign_scope` on_mount callback |
| `test/support/test_router.ex` | wire on_mount into live_session |
| `test/test_helper.exs` | load hooks.ex before test_router |
| `test/support/live_case.ex` | `fake_scope/1` + `put_test_scope/2` |
| `test/activity_logging_test.exs` | failed-create tests inverted to `db_pending: true` pins |
| `test/phoenix_kit_locations/web/locations_live_test.exs` | actor_uuid pins on both delete tests |
| `test/phoenix_kit_locations/web/location_form_live_test.exs` | actor_uuid pins on create + update |
| `test/phoenix_kit_locations/web/location_type_form_live_test.exs` | actor_uuid pin on create |
| `test/locations_test.exs` | +5 edge-case tests (Unicode, SQL metachars, length limits) |

### Batch 3d — Coverage push to 96.52%

After Batch 3a–c shipped at 90.07% line coverage (`mix test --cover`),
Max authorised pushing as close to 100% as possible without external
tooling. Net: **90.07% → 96.52%** with +20 tests.

**Code change to make dead branches reachable.**
`LocationTypeAssignment` previously had no changeset — `repo.insert(%struct{})`
of bad FKs raised `Ecto.ConstraintError` instead of returning a clean
`{:error, %Ecto.Changeset{}}`. Added `LocationTypeAssignment.changeset/2`
with `assoc_constraint(:location)` + `assoc_constraint(:location_type)`,
and routed `insert_type_assignment!/3` and `add_location_type/3`
through it. This converts FK violations from raises into the same
`{:error, changeset}` shape as every other CRUD op AND makes the
Batch 3a `:error`-branch logging code reachable.

**Tests added (+20):**
- `enable_system/0` / `disable_system/0` direct unit tests (covers
  the main module's body lines + `log_module_toggle/1` no-opts head)
- `log_module_toggle(:enabled)` no-opts test (covers default-arg head)
- `add_location_type` FK-violation logs with `db_pending: true`
- `sync_location_types` FK-violation logs with `db_pending: true`
- Schema empty-string skip branches (`maybe_validate_email` / `maybe_validate_website`)
  via struct-data-supplied empty strings (cast strips `""` → nil)
- `status_label/1` fallback via raw `insert_all/3` bypassing
  `validate_inclusion(:status)` to land a row with status `"pending"`
- `delete_location_type` event with no prior `show_delete_confirm`
  (covers the `_ -> ...` clause)
- `actor_opts/1` no-scope path (delete without `put_test_scope/2`)
- Render with assigned types — covers the `:for span` badge clause
  and `type_names/1` non-empty branch
- `switch_language` event in both form LVs
- `update_location` / `update_location_type` `:error` re-render branch
- `sync_types_and_redirect` `:error` branch — toggle a bogus type
  UUID, save, follow_redirect, assert warning flash
- 5 edge-case tests in `locations_test.exs` (Unicode round-trip, SQL
  metacharacters, length limits) — landed earlier in Batch 3c

**`test/destructive_rescue_test.exs` (new, async: false).** Three
tests that DROP TABLEs inside the sandbox transaction to exercise
rescue branches that are otherwise unreachable without Mox-style
mocking:
- `find_similar_addresses` rescue when locations table is missing
- `maybe_log_activity` swallow when activities table is missing
- `LocationsLive` `load_data(:index)` and `load_data(:types)` rescues
  when their respective tables are missing

These ran async first and deadlocked against parallel async tests
holding row locks on the same schemas — moved to a dedicated
`async: false` file.

### Coverage breakdown (post-Batch 3d)

| Module | Coverage |
|--------|----------|
| `PhoenixKitLocations.Errors` | 100.00% |
| `PhoenixKitLocations.Paths` | 100.00% |
| `PhoenixKitLocations.Schemas.Location` | 100.00% |
| `PhoenixKitLocations.Schemas.LocationType` | 100.00% |
| `PhoenixKitLocations.Schemas.LocationTypeAssignment` | 100.00% |
| `PhoenixKitLocations.Web.LocationTypeFormLive` | 100.00% |
| `PhoenixKitLocations.Web.LocationFormLive` | 96.86% |
| `PhoenixKitLocations.Web.LocationsLive` | 96.58% |
| `PhoenixKitLocations.Locations` | 94.57% |
| `PhoenixKitLocations` | 88.24% |
| **Total** | **96.52%** |

### What's still uncovered (the residual ~3.5%)

All remaining misses fall into two classes; neither is closable
without either Mox-style mocking or removing the defensive code:

1. **`PhoenixKitLocations.enabled?/0` rescue/catch fallbacks** —
   `rescue _ -> false` and `catch :exit, _ -> false`. Core's
   `Settings.get_boolean_setting/2` already swallows DB errors before
   they reach our rescue point, so these only fire if core itself
   re-raises (which it doesn't today).

2. **Defensive non-changeset error branches and unreachable
   pattern-match catchalls.** Examples: `add_location_type` final
   `error -> error` (only `:ok` and `{:error, %Ecto.Changeset{}}`
   reach it now that the changeset wires `assoc_constraint`),
   `log_activity({:error, _}, ...)` plain catchall (no caller passes
   non-changeset error tuples), `LocationsLive.delete_failed_atom/1`
   clauses (the `{:error, reason}` arm of `do_delete_item` is dead
   because `Locations.delete_*` either succeeds or raises),
   `feature_label(key)` unknown-key fallback (`@feature_keys` is a
   compile-time-static list of known keys).

   These could be removed entirely without changing observable
   behavior. Keeping them is a deliberate defense-in-depth choice;
   surfaced here for future cleanup.

## Files touched (Batch 3d)

| File | Change |
|------|--------|
| `lib/phoenix_kit_locations/schemas/location_type_assignment.ex` | new `changeset/2` with `assoc_constraint/2` for both FKs |
| `lib/phoenix_kit_locations/locations.ex` | `insert_type_assignment!/3` + `add_location_type/3` route through the changeset |
| `test/locations_test.exs` | +2 schema empty-string tests; updated FK-violation test to expect `{:error, :type_assignment_failed}` instead of raise; +alias `LocationSchema` |
| `test/activity_logging_test.exs` | +5 tests (no-opts toggle, enable/disable_system, FK-violation logging) |
| `test/phoenix_kit_locations/web/locations_live_test.exs` | +4 tests (with-types render, no-scope delete, type-not-found-fallback, status_label fallback); alias `TestRepo` |
| `test/phoenix_kit_locations/web/location_form_live_test.exs` | +3 tests (switch_language, update :error, sync :error follow_redirect) |
| `test/phoenix_kit_locations/web/location_type_form_live_test.exs` | +2 tests (switch_language, update :error) |
| `test/destructive_rescue_test.exs` | new, async: false; 4 DROP-TABLE rescue tests |

## Verification

- `mix precommit` clean (compile + format + credo --strict + dialyzer)
- **187 tests, 0 failures** (up from 162 in Batch 3a–c, 160 pre-sweep)
- 15/15 stable runs (the destructive-test deadlock was traced and
  fixed by moving them to `async: false`)
- **96.52% line coverage** via `mix test --cover` (up from 90.07%
  pre-Batch-3d)

## Files touched

| File | Batch | Change |
|------|-------|--------|
| `lib/phoenix_kit_locations.ex` | 2 (`<commit>`) | `enabled?/0` + `catch :exit, _ -> false` |
| `lib/phoenix_kit_locations/paths.ex` | 2 | `@spec` on all 6 public fns |
| `lib/phoenix_kit_locations/web/locations_live.ex` | 2 | catch-all `handle_info` Logger.debug |
| `lib/phoenix_kit_locations/web/location_form_live.ex` | 2 | catch-all `handle_info` Logger.debug |
| `lib/phoenix_kit_locations/web/location_type_form_live.ex` | 2 | catch-all `handle_info` Logger.debug |
| `test/support/postgres/migrations/20260403000000_setup_phoenix_kit.exs` | 2 | `phoenix_kit_settings` table per AGENTS.md:921 schema |
| `test/errors_test.exs` | 2 | drop `is_binary/1`-loop smell |
| `test/phoenix_kit_locations/web/locations_live_test.exs` | 2 | `handle_info` catch-all pin |
| `test/phoenix_kit_locations/web/location_form_live_test.exs` | 2 | `handle_info` catch-all pin |
| `test/phoenix_kit_locations/web/location_type_form_live_test.exs` | 2 | `handle_info` catch-all pin |
| `AGENTS.md` | 2 | "What This Module Does NOT Have" section |
| `README.md` | 2 | Error Handling + Activity Logging subsections |

## Verification

- `mix compile` — clean
- `mix format --check-formatted` — clean
- `mix credo --strict` — 0 issues, 190 mods/funs
- `mix dialyzer` — 0 errors, 0 skipped, 1 unnecessary skip
- `mix test` — **162 tests, 0 failures** (up from 160)
- 10/10 stable runs

## Open

None.
