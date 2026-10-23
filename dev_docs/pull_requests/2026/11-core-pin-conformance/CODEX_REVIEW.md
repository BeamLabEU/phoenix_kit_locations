# PR #11 — Published core dependency contract

- PR: [#11](https://github.com/BeamLabEU/phoenix_kit_locations/pull/11)
- Author: mdon; merged commit: `7df34bd`
- Reviewer: Codex; date: 2026-10-23
- Rechecked main at `abbfbe3`, including Claude's review and follow-up.
- Skills: `pr-review`, `elixir:ecto-thinking`, `elixir:phoenix-thinking`, `elixir:elixir-thinking`.

## Findings and resolution

Reviewed the original conformance test, its current fallback, the real dependency
options, the Geo API calls and published core 2.63.0 metadata/source. These are
current regressions that appeared after the original PR and escaped its check.

## BUG - HIGH — A valid requirement hid an unpublishable dependency

The test accepted the string requirement on a GitHub dependency. Current main
therefore passed all 588 tests while carrying a Git dependency Hex cannot
publish. The GitHub workaround's rationale was stale: published core 2.63.0
already requires beamlab_countries 2.x. Restored the Hex dependency and locked
core 2.63.0, with its required Fresco 0.14 and Etcher 0.22 versions.

The test now evaluates the actual project in an isolated VM with
`PHOENIX_KIT_PATH` unset, checks its source options and checks its requirement.
This also removes the regex fallback that could accept a commented-out pin.
Local development overrides remain supported.

## BUG - HIGH — The old floor no longer supplied the address form's APIs

The requirement still admitted core 2.41.1, whose countries dependency has no
Cities module. Geo now calls that module directly. Raised the Hex floor to
`>= 2.63.0 and < 3.0.0`, the first core release requiring countries 2.x, while
keeping later core minors admissible. Updated the boundary tests and AGENTS.md.

## BUG - MEDIUM — Locked crypto dependency had a published advisory

Dependency resolution reported [EEF-CVE-2026-105963](https://osv.dev/vulnerability/EEF-CVE-2026-105963)
for the pre-existing plug_crypto 2.2.0 lock (secret-key exposure in wrong-typed
argument stack traces). Updated it to compatible patched 2.2.1 while resolving
the published core dependency.

Before the fixes the new tests failed on both the GitHub source and the old
floor. The full final suite runs against the published minimum itself.

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
