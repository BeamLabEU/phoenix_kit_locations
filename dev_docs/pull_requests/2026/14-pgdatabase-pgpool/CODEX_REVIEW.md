# PR #14 — Database and pool overrides

- PR: [#14](https://github.com/BeamLabEU/phoenix_kit_locations/pull/14)
- Author: timujinne; merged commit: `4984592`
- Reviewer: Codex; date: 2026-10-23
- Rechecked main at `abbfbe3`, including Claude's review and follow-up.
- Skills: `pr-review`, `elixir:ecto-thinking`, `elixir:phoenix-thinking`, `elixir:elixir-thinking`.

## Findings and resolution

Reviewed both environment overrides and their actual startup/reset consumers,
including the documented libpq and partition behavior.

## BUG - MEDIUM — Whitespace-only settings bypassed the defaults

The config checked for empty strings before trimming. `PGDATABASE="   "` became
an empty database name instead of the partitioned default; Postgrex can then
fall back to the username's database or reject the connection. A whitespace-only
`PGPOOL` raised instead of behaving like an empty setting. Both settings now
trim before selecting their defaults.

New config tests reproduced both failures and cover unset/empty/whitespace
values, explicit trimmed names, partition behavior, valid pool sizes and
rejection of zero, negative, partial and decimal values.

Explicit PGDATABASE continues to replace the entire partitioned name, and the
existing warning about targeting an application database remains applicable.
Changing that established override contract is outside this fix.

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
