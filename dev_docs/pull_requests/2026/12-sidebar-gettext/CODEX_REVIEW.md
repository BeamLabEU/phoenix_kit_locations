# PR #12 — Sidebar translations and extraction

- PR: [#12](https://github.com/BeamLabEU/phoenix_kit_locations/pull/12)
- Author: timujinne; merged commit: `a629c60`
- Reviewer: Codex; date: 2026-10-23
- Rechecked main at `abbfbe3`, including Claude's review and follow-up.
- Skills: `pr-review`, `elixir:ecto-thinking`, `elixir:phoenix-thinking`, `elixir:elixir-thinking`.

## Findings and resolution

Reviewed every admin tab, core's `Tab.localized_label/1`, Claude's new runtime
translation test and all four catalogues. Backend/domain wiring and Estonian /
Russian translations are correct. There are eight tabs and seven distinct labels.

## IMPROVEMENT - MEDIUM — Preservation flags contradicted the catalogue contract

`Locations`, `Types`, `New Location`, `New Type` and `Structure` still carried
`elixir-autogen` in the POT and all three PO files, despite the documented rule
and the earlier review's claim. Their current source call sites keep extraction
working today, but removing a call site would prune the runtime-only sidebar
label. Removed that flag for these hand-maintained entries and added a test
requiring every tab label in every catalogue to survive without source call
sites. Claude's backend and runtime translation test remains in place.

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
