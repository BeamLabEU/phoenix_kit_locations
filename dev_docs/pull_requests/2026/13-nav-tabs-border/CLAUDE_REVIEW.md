# PR #13 Review — Render LocationTabs through core nav_tabs

- **PR:** [#13](https://github.com/BeamLabEU/phoenix_kit_locations/pull/13)
- **Author:** mdon
- **State:** MERGED (`c857936`)
- **Reviewer:** Claude (Sonnet 5.5)
- **Date:** 2026-10-22
- **Skills applied first:** `elixir:phoenix-thinking`, `elixir:ecto-thinking`

## Scope

`LocationTabs` renders core's `<.nav_tabs variant={:border}>` instead of hand-written `tablist` markup. A GROK review already exists in this folder; this file is Claude's own pass and does not repeat it.

## Verified

- `nav_tabs` takes `active_tab` as a string, and the wrapper passes `to_string(@active)` against string tab ids.
- `:navigate` values pass through verbatim in core, and `Paths.*` already return prefixed, localised URLs, so there is no double prefix.
- The Details and Structure live tests assert `a.tab-active` with the right label, which pins the markup contract this PR depends on.

## Findings

### NITPICK

The moduledoc still said the tabs mirror `PhoenixKitWarehouse.Web.Components.WarehouseHeader`, a module in a repo this one has no dependency on and whose markup the wrapper no longer copies. Fixed: reference removed.
