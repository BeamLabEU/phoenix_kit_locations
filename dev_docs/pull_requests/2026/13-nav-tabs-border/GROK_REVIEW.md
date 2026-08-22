# GROK_REVIEW — PR #13: Render LocationTabs through core nav_tabs

**PR:** https://github.com/BeamLabEU/phoenix_kit_locations/pull/13
**Author:** mdon (Max Don)
**Merge:** `c857936` — *Merge pull request #13 from mdon/fix/nav-tabs-border*
**Reviewed:** 2026-08-22 · **Verdict:** approve with two fixes applied below.

Companion to BeamLabEU/phoenix_kit#746 (`variant={:border}` + verbatim
`:navigate`/`:patch`). Lockfile already sits on `phoenix_kit` 2.13.6 via the
follow-up `lib upgrades` commit (`596443a`).

## Scope of what we reviewed

+20 / −17 across 2 files (`location_tabs.ex`, `dev_docs/IMPLEMENTATION_PLAN.md`).
Read the new wrapper against core's `PhoenixKitWeb.Components.Core.NavTabs`
(2.13.6), every `LocationTabs` call site, `Paths.location_edit/1` /
`Paths.location_structure/1` (both already go through `Routes.path/1`), and
the Structure LiveView smoke test that asserts the tab strip.

Two things guided the read:

- **Prefix rules.** Core 2.13.6 passes `:navigate`/`:patch` through verbatim
  and still runs the legacy `:path` key through `Routes.path/1`. This wrapper
  uses `:navigate` with `Paths.*` URLs. That is the combination #746 exists
  for — the reverse (`:path` + already-prefixed Paths, or `:navigate` against
  2.13.5) double-prefixes. Confirmed against `nav_tabs.ex`'s `resolve_link/2`.
- **Variant vs class merge.** Phoenix-thinking: class lists cannot *remove*
  the boxed frame, which is why the underline copies existed. `variant={:border}`
  is the API that was added for this exact call site. `class="mb-4"` only adds
  spacing, which `tablist_class/2` concatenates correctly.

The markup swap itself is clean. The local API (`location` + `active` atom)
is unchanged. `gettext("Details")` / `gettext("Structure")` stay as literals,
so extract still finds them. The Structure test's `a.tab-active` selector
still matches (`tab_class/2` adds `gap-2` next to `tab-active`, it does not
replace it).

## Findings

### BUG - MEDIUM: Details page never renders the tab strip *(fixed)*

`LocationTabs` is documented as the shared header between `LocationFormLive`
(Details) and `LocationStructureLive` (Structure). Only Structure imports and
renders it. The edit form has no tab strip at all, so the only in-page way
to reach Structure is the index row menu; Structure → Details works, Details
→ Structure does not.

This is not a regression of #13 — the wrapper landed in `5665ab3` "not wired
into any render yet", Structure consumed it, Details never did. The
implementation plan is explicit that the strip shows only when the Location
already exists (`@action == :edit`; no Structure tab on `:new`).

**Fix:** import and render `<.location_tabs>` on the edit form, same placement
as Structure (inside the `max-w-5xl` column, above the body). `:new` stays
tabless. Locked in by two form LiveView tests (edit has Details/Structure
with the Structure href; new has no `role=tablist`).

### BUG - MEDIUM: `version/0` drifted to `"0.4.0"` while mix.exs is `0.4.1` *(fixed)*

`0.4.1` bumped `@version` in `mix.exs` and CHANGELOG but not
`PhoenixKitLocations.version/0`. The "version compliance" test hardcoded
`== "0.4.0"`, so it could not catch mix.exs drifting ahead — the same class
of bug 0.3.0 already claimed to close.

**Fix:** `version/0` now has to equal `Mix.Project.config()[:version]`. The
0.4.2 bump updates both sources; the test no longer hardcodes a third copy.

### IMPROVEMENT - MEDIUM: mix.exs still admits cores that double-prefix `:navigate` *(not changed)*

LocationTabs needs phoenix_kit 2.13.6 (`variant={:border}` + verbatim
`:navigate`). mix.exs stays `~> 2.0` — the floor PR #11's conformance test
exists to protect, and the same pin CRM/Warehouse kept after adopting
`variant={:border}`. A three-segment `~> 2.13.6` would expand to `< 2.14.0`
and break every host that moved on to a later 2.x minor.

Hosts still on 2.13.5 would compile this package and get double-prefixed
tab hrefs. The lockfile in *this* repo is 2.13.6, and Hex resolution will
pull 2.13.6 for anyone not pinning an older core. Raising the floor to
`~> 2.0 and >= 2.13.6` would be honest but is a consumer-contract change
the sibling modules did not make in the same wave — left for an explicit
pin PR rather than a drive-by on a two-file markup swap.

## What we did not change

- The wrapper's local API and the IMPLEMENTATION_PLAN note correction.
- mix.exs `~> 2.0` (see above).
- Gettext `.po` line references (stale by a few lines; extract will refresh
  them the next time someone runs it in this package).
