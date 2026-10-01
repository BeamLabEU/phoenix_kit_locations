# PR #19 Review — Locations pages on core components, translated module, sweep fixes

- **PR:** [#19](https://github.com/BeamLabEU/phoenix_kit_locations/pull/19)
- **Author:** mdon
- **State:** MERGED (`d268188`)
- **Reviewer:** Claude (Sonnet 5.5)
- **Date:** 2026-10-01
- **Skills applied first:** `elixir:phoenix-thinking`, `elixir:ecto-thinking`

## Scope

36 files (+3,954 / −802). Every page moves onto core's components (`form_section`,
`section_header`, `button`, `empty_state`, `status_badge`, `checkbox`, `form_actions`,
`search_picker`, `table_default` toolbar slots). Every module file now uses
`PhoenixKitLocations.Gettext`, and the catalogue is filled for en/et/ru. Sweep fixes:
feature checkboxes become real form fields; PlacePicker re-applies its active, type
and owner filters to a client-sent uuid and refuses inactive spaces; the type form
re-reads the live scope on save; the Structure page's new-space form gets its own id
namespace and a catch-all `handle_info/2`; `ProjectSitesLive` applies the hub's locale.
The core floor goes to `>= 2.41.1`.

## Verified

- Read every changed `lib/` file with its surrounding code.
- `put_features/2` takes only `@feature_keys` and keeps stored keys the form doesn't
  offer; `"true"` strings count as on and are saved back as booleans.
- Owner events (`search_owner`, `pick_owner`, `clear_owner`) are still gated on the live
  scope; `pick_owner` still accepts only a uuid from the last pushed rows.
- `selectable_location/2` loads through `Locations.get_location/1`, which preloads
  `:location_types`, so `type_allowed?/2` sees a list, never `NotLoaded`.
- The `multilang_fields_wrapper` in the type form lost its custom `:skeleton`; core's
  default skeleton exists, so nothing renders blank.
- No remaining `to_form(..., as: :space)` without an id except the detail panel's own
  form (default id `space`), so the Kind-select collision stays fixed.

## Findings

### BUG - CRITICAL — Locations and Types lists crash on every published core

`locations_live.ex` passed `<:toolbar_primary>` to `table_default`. That slot exists
only in the unreleased tip of core's `main`; Hex's `phoenix_kit` 2.42.1 (the newest
release, and what `mix.lock` pins) declares only `:toolbar_title` and
`:toolbar_actions`. An undeclared slot is folded into the component's `:global` rest
and `table_default_with_cards` fails in `Phoenix.HTML.attributes_escape/1`:

    ** (ArgumentError) lists in Phoenix.HTML and templates may only contain integers
       representing bytes, binaries or other lists, got invalid entry:
       %{__slot__: :toolbar_primary, ...}

Result: `/admin/locations` and `/admin/locations/types` return a 500 for every host on
Hex. Compile stays clean (slots are not checked against an unknown caller), so only a
test run against the locked core shows it: **38 of 541 tests failed** on a clean
checkout. The PR was evidently run against a local core checkout (`PHOENIX_KIT_PATH`),
where the slot exists, and the floor `>= 2.41.1` does not protect against it.

**Fixed.** Both tables use `<:toolbar_actions>`, which every release since the toolbar
landed supports. The button now sits before the view toggle instead of in the
far-right corner. The "last control, after the view toggle" test asserted the
unreleased layout; it now asserts the button is in the toolbar row above the table.
AGENTS.md records the rule and the way back (once core releases `:toolbar_primary`,
raise the floor to that release and move the button).

### NITPICK — Gate does not catch an unreleased-core dependency

`mix precommit` and `mix test` pass against a local `PHOENIX_KIT_PATH` checkout, so a
change that needs unreleased core is invisible until someone runs against Hex. Not
fixed here: it needs CI that runs the suite once without `PHOENIX_KIT_PATH`. Run
`mix test` without it before every release.

## Not changed, on purpose

- The hand-rolled Save buttons on the location and space forms stay: core's
  `form_actions` cannot disable its submit button while uploads are in flight.
- `owner_picker` and PlacePicker send `has_more: false` and never paginate: both lists
  are small by design.

## Validation

`mix test`: 541 tests, 0 failures against `phoenix_kit` 2.42.1 from Hex (38 failures
before the fix). `mix precommit` result in FOLLOW_UP.md.
