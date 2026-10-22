# PR #15 Review — Standardize AGENTS.md onto the shared module skeleton

- **PR:** [#15](https://github.com/BeamLabEU/phoenix_kit_locations/pull/15)
- **Author:** mdon
- **State:** MERGED (`d9408fe`)
- **Reviewer:** Claude (Sonnet 5.5)
- **Date:** 2026-10-22
- **Skills applied first:** `elixir:phoenix-thinking`, `elixir:ecto-thinking`

## Scope

AGENTS.md rewritten onto the shared skeleton; `CLAUDE.md` becomes a symlink to it; `dev_docs/guides/spaces.md` added; `version/0` reads `mix.exs`; `test_helper.exs` swaps the `psql -lqt` check for core's `PostgresPreflight`.

## Verified

- `@version Mix.Project.config()[:version]` is read at compile time inside the dep's own compile, so a host sees the dep's version; the behaviour test asserts it against `mix.exs`.
- The preflight classifies a real connection attempt with the repo's own credentials; a failure prints the reason and excludes `:integration`, which the earlier unix-socket listing could not tell apart from success.
- `Code.ensure_loaded?/1` guards the call, so a core without the module falls back to starting the repo.

## Findings

### NITPICK

AGENTS.md's Testing section still said `test_helper.exs` "checks `psql -lqt` for the DB", which this PR removed, and the helper's comment still named a `~> 2.0` core floor. Both fixed to match the code.
