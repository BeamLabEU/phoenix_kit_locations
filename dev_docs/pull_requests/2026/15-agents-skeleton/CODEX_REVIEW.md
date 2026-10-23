# PR #15 — Test startup and repository guidance

- PR: [#15](https://github.com/BeamLabEU/phoenix_kit_locations/pull/15)
- Author: mdon; merged commit: `d9408fe`
- Reviewer: Codex; date: 2026-10-23
- Rechecked main at `abbfbe3`, including Claude's review and follow-up.
- Skills: `pr-review`, `elixir:ecto-thinking`, `elixir:phoenix-thinking`, `elixir:elixir-thinking`.

## Findings and resolution

Reviewed the docs rewrite, CLAUDE.md symlink, compile-time version callback,
preflight integration and the complete current helper. Version sourcing and the
symlink remain correct.

## BUG - HIGH — Migration failures produced successful test runs

The helper rescued everything from repo startup through core/module migration
and sandbox setup. A working database with a broken migration was therefore
reported unavailable, integration tests were excluded, and Mix returned success.
This was pre-existing behavior retained by the PR and missed in the follow-up.

Narrowed the rescue to starting/probing the database. After a successful
connection, migration and sandbox errors propagate and fail the run. An isolated
VM regression test injects a migration exception; before the fix the child
returned zero and excluded integration tests, and afterwards it fails. A second
subprocess test verifies a missing database still permits unit tests.

The command summary also now shows `MIX_ENV=test` for setup/reset, matching the
existing detailed instructions. Database overrides and conformance guidance
were refreshed for the other fixes in this pass.

## Validation

- `mix test`: 596 tests, 0 failures, including database and LiveView tests,
  against published core 2.63.0 and patched plug_crypto 2.2.1.
- `mix precommit`: passed compilation with warnings as errors, unused-dependency
  checking, security/retirement audit, formatting, strict Credo and Dialyzer.
- `mix hex.build --output /tmp/phoenix_kit_locations-codex-review.tar`: passed;
  package metadata contains the Hex core requirement and LiveView dependency.
- Local-override conformance smoke run: 2 tests, 0 failures with
  `PHOENIX_KIT_PATH` set; the committed dependency is still checked without it.
- `git diff --check`: passed.

No version bump, changelog entry, tag or publication in this review pass.
