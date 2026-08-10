# PR #10 — Add the Sites project extension for the projects hub

**Reviewed:** 2026-08-10 · **Author:** mdon · **Verdict:** merged, no changes
required. Released in **0.4.0**.

+128 / −0 across 2 files. Reviewed as part of the phoenix_kit 2.0 sweep.

## What it does

Contributes a **Sites** tab to the `phoenix_kit_projects` hub via
`phoenix_kit_project_extensions/0` — the duck-typed, one-way discovery contract
(same shape as the dashboards widget contract). The projects package's
`Extensions.Registry` finds the function; **this package gains no dependency on
projects**, which is the right direction for the umbrella's dependency graph and
the main thing I checked. `mix.exs` grows no new dep.

Linkage is config-based: comma-separated location UUIDs set per project in the
Modules & features panel. No foreign key, so uninstalling either side leaves no
dangling constraint.

## Points checked

**Contributed tabs cannot crash the host page.** `safe_get/1` wraps
`Locations.get_location/1` in both `rescue` and `catch :exit, _`, so a DB hiccup
or a stale UUID degrades to a missing card rather than taking down the whole
project page it is embedded in. That matters more than usual here, because the
tab renders inside someone else's LiveView via `live_render`.

**Input is validated before it reaches the repo.** `parse_uuids/1` filters on
`Ecto.UUID.cast/1`, so a malformed config value is dropped rather than passed
into a query. The `parse_uuids(_)` fallback covers a nil/absent config.

**Off-router-mountable.** No `handle_params/3`, which the moduledoc names as the
hub's hard requirement — correct, since the tab is mounted without a route.

**Empty state distinguishes "not configured" from "configured but gone."** The
`configured?` assign separates the two, so an admin whose locations were deleted
sees "The configured locations no longer exist" rather than a message implying
they never set it up. Small, but it is the difference between a dead end and an
actionable one.

## Verification

| Check | Result |
|---|---|
| `mix precommit` | **passes** against core 2.0.0 |
