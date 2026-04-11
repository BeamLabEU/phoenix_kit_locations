# PR #2 Review — Add routing anti-pattern pointer to AGENTS.md

**Reviewer:** Pincer 🦀 | **Date:** 2026-04-11 | **Verdict:** Approve (with pre-existing issue)

## PR Assessment

Docs-only change. Adds routing anti-pattern warning to AGENTS.md. No issues with the PR itself.

## Pre-existing Issue Blocking Release

`mix precommit` fails due to a **pre-existing** credo warning unrelated to this PR:

```
[F] → Function is too complex (cyclomatic complexity is 12, max is 9).
      lib/phoenix_kit_locations/web/location_form_live.ex:32:7
      #(PhoenixKitLocations.Web.LocationFormLive.mount)
```

The `mount/3` function in `LocationFormLive` has cyclomatic complexity 12 (max allowed 9). This blocks the release pipeline because `mix precommit` treats credo warnings as failures (exit code 8).

**Fix needed:** Refactor `mount/3` in `lib/phoenix_kit_locations/web/location_form_live.ex:32` to reduce complexity below 9 (extract helper functions for different mount branches).

## Post-Review Status

PR is clean. Release blocked by pre-existing credo issue. Awaiting developer fix or Dmitri decision to bypass.
