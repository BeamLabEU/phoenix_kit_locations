# PR #14 Review — test: make the test database name overridable via PGDATABASE (+ PGPOOL)

- **PR:** [#14](https://github.com/BeamLabEU/phoenix_kit_locations/pull/14)
- **Author:** timujinne
- **State:** MERGED (`4984592`)
- **Reviewer:** Claude (Sonnet 5.5)
- **Date:** 2026-10-22
- **Skills applied first:** `elixir:phoenix-thinking`, `elixir:ecto-thinking`

## Scope

`config/test.exs` reads `PGDATABASE` for the database name and `PGPOOL` for the pool size.

## Verified

- `PGPOOL` accepts only a positive integer and raises on anything else, including `"8x"` and `"0"`; blank falls back to `schedulers_online * 2`.
- Unset, the name is still `phoenix_kit_locations_test<MIX_TEST_PARTITION>`, so CI and a plain `mix test` are unchanged.

## Findings

### IMPROVEMENT - MEDIUM

`PGDATABASE` is libpq's own variable, and developers commonly export it so `psql` lands in their app database. With it set, `mix test` runs core's migration chain and this module's migrations against that database, and `mix test.reset` (`ecto.drop`) drops it. The same mechanism exists in core's `config/test.exs`, so renaming the variable here would diverge from the ecosystem, and the repo's own `PGDATABASE` is unset. Not changed in code; AGENTS.md's Testing section now states the hazard.

### NITPICK

A set `PGDATABASE` also replaces the `MIX_TEST_PARTITION` suffix, so partitioned runs share one database. The sandbox isolates tests, but `test.reset` is no longer per partition. Documented in the same AGENTS.md line.
