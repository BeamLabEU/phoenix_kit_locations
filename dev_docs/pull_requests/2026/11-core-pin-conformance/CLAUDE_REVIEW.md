# PR #11 Review — Add a conformance test for the :phoenix_kit requirement

- **PR:** [#11](https://github.com/BeamLabEU/phoenix_kit_locations/pull/11)
- **Author:** mdon
- **State:** MERGED (`7df34bd`)
- **Reviewer:** Claude (Sonnet 5.5)
- **Date:** 2026-10-22
- **Skills applied first:** `elixir:phoenix-thinking`, `elixir:ecto-thinking`

## Scope

`test/core_pin_conformance_test.exs` (new): asserts the `:phoenix_kit` requirement admits every core minor above the floor and rejects the ones below, reading the resolved dep first and the committed literal in `mix.exs` second. No merge commit (squashed in as `7df34bd`).

## Verified

- The resolved-dep clause matches both the 2-tuple (`{:phoenix_kit, req}`) and 3-tuple (`{:phoenix_kit, req, opts}`) forms, so the current `pk_dep(..., github: ...)` shape resolves.
- Under `PHOENIX_KIT_PATH`, `pk_dep/3` yields `{app, [path: ...]}`, which neither clause matches, so the test falls back to the committed literal as documented.
- The fallback regex `:phoenix_kit,\s*"` needs the comma straight after the atom, so the `:phoenix_kit_js_sources` mention in the `mix.exs` comment cannot match first.
- `@must_admit` / `@must_reject` bracket the current floor (2.41.0 rejected, 2.41.1 admitted) and the 3.0.0 ceiling.

## Findings

### NITPICK

`@must_reject` hard-codes the floor (`2.41.0`), so raising the floor means editing the test. That is intended friction, and the moduledoc says so. No change.
