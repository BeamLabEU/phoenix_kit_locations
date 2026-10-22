# PR #12 Review — Wire gettext_backend on admin_tabs so sidebar labels translate

- **PR:** [#12](https://github.com/BeamLabEU/phoenix_kit_locations/pull/12)
- **Author:** timujinne
- **State:** MERGED (`a629c60`)
- **Reviewer:** Claude (Sonnet 5.5)
- **Date:** 2026-10-22
- **Skills applied first:** `elixir:phoenix-thinking`, `elixir:ecto-thinking`

## Scope

Every `Tab` in `admin_tabs/0` gets `gettext_backend: PhoenixKitLocations.Gettext` and `gettext_domain: "default"`; the pot and the et/ru catalogues gain the seven tab-label msgids.

## Verified

- All seven tabs carry both keys (parent, Locations, Types, both `new` tabs, both `edit` tabs, Structure).
- Core's `Tab.localized_label/1` calls `Gettext.dgettext(backend, domain, label)` at render time, so the msgids have no call site the extractor can see; the catalogues carry them without `elixir-autogen`, as AGENTS.md requires.
- et and ru both translate all seven (checked in the po files; `gettext_catalog_test` also fails on an empty or fuzzy entry).

## Findings

### IMPROVEMENT - MEDIUM

Nothing tested the wiring. The catalogue test only checks that the pot's msgids are translated, so dropping `gettext_backend` from one tab (or from all of them) leaves the whole suite green while that sidebar entry shows English in every locale, with no warning. Fixed: `gettext_catalog_test.exs` now asserts every admin tab names the module's backend and `"default"` and that its label differs from the msgid under et and ru.
