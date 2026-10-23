# PR #8 — Runtime schema prefixes

- PR: [#8](https://github.com/BeamLabEU/phoenix_kit_locations/pull/8)
- Author: mdon; merged commit: `fd43603`
- Reviewer: Codex; date: 2026-10-23
- Rechecked main at `abbfbe3`, including Claude's review and follow-up.
- Skills: `pr-review`, `elixir:ecto-thinking`, `elixir:phoenix-thinking`, `elixir:elixir-thinking`.

## Findings and resolution

Reviewed the four schema changes, current queries (including core's tree-query
CTEs), migration prefix handling, and Claude's review/follow-up. All four schemas
still use `PhoenixKit.SchemaPrefix`; no query regression was found.

## IMPROVEMENT - MEDIUM — Conformance accepted comments as implementation

The test looked for substrings, so a comment mentioning the macro passed, and
only tables beginning with `phoenix_kit` were checked. It now parses Elixir
syntax and requires a real `use` declaration for every literal `schema` call.
Embedded schemas remain excluded. This strengthens the existing static check;
it does not claim to run the entire suite against a separately compiled prefix.

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
