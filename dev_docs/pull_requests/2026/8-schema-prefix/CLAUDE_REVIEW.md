# PR #8 Review — Add PhoenixKit.SchemaPrefix for runtime named-schema (--prefix) support

- **PR:** [#8](https://github.com/BeamLabEU/phoenix_kit_locations/pull/8)
- **Author:** mdon
- **State:** MERGED (`fd43603`)
- **Reviewer:** Claude (Sonnet 5.5)
- **Date:** 2026-10-22
- **Skills applied first:** `elixir:phoenix-thinking`, `elixir:ecto-thinking`

## Scope

Four schemas gain `use PhoenixKit.SchemaPrefix`; `test/schema_prefix_conformance_test.exs` is new; the core floor goes to `~> 1.7.189` (since raised to `>= 2.41.1 and < 3.0.0`).

## Verified

- All four table-backed schemas (`Location`, `LocationType`, `LocationTypeAssignment`, `Space`) carry the macro, directly after `use Ecto.Schema`; the conformance test passes.
- The macro is the only change in the schemas, so no field or changeset behaviour moved.

## Findings

### NITPICK

The conformance test matches the substring `use PhoenixKit.SchemaPrefix` anywhere in the file, so a comment or moduledoc mentioning it would satisfy it for a schema that lacks the macro. It also keys on `schema "phoenix_kit`, so a schema whose table name lacks the prefix escapes the check. Both are theoretical for a four-schema module; not changed.
