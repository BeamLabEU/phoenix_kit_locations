# Follow-up Items for PR #4 — Migration cleanup

PR #4 landed `PhoenixKit.Migration.ensure_current/2` as the test schema
setup, deleting 130 lines of hand-rolled DDL in
`test/support/postgres/migrations/`. Reviewed by Pincer on 2026-05-05;
verdict was Approve with two should-fix and a few nice-to-haves around
docs / version-pinning hygiene.

Triaged 2026-05-28.

## Fixed (Batch 1 — 2026-05-28, commit `da97424`)

- ~~`mix.exs:56` `{:phoenix_kit, "~> 1.7"}` floor too loose~~ — bumped
  to `~> 1.7.105`, the first version that exposes `ensure_current/2`
  (introduced in phoenix_kit commit `af09c0d4`, bumped in commit
  `c7a6f188`). Resolution now fails fast on too-old hosts instead of
  crashing at boot with `UndefinedFunctionError`.
- ~~`test_helper.exs:65` references nonexistent
  `dev_docs/migration_cleanup.md`~~ — the doc never landed; AGENTS.md
  already covers the relevant content. Dropped the dangling "See …"
  sentence as part of the comment-block trim.
- ~~12-line rationale block in `test_helper.exs:54-66`~~ — trimmed to
  4 lines per reviewer suggestion. The V40/V03/V90 origin story and
  re-runnable semantics belong in core's `PhoenixKit.Migration`
  docstring; we just need a pointer + the `schema_migrations` row
  accumulation note + the `mix test.reset` clear hint, all folded in.
- ~~`mix.exs` `test.setup` no longer mentions migrate~~ — added a
  2-line comment above the alias explaining the migrate step lives in
  `test_helper.exs`, so a reader looking at the alias in isolation
  doesn't wonder where the schema comes from.
- ~~`schema_migrations` row accumulation deserves a comment~~ — folded
  into the trimmed test_helper.exs comment block above (one-liner with
  `mix test.reset` as the clear).

## Skipped (with rationale)

None — all reviewer findings actionable.

## Files touched

| File | Change | Batch |
|------|--------|-------|
| `mix.exs` | Bump phoenix_kit floor to `~> 1.7.105`; add 2-line `test.setup` comment | Batch 1 |
| `test/test_helper.exs` | Trim 12-line block to 4 lines; drop missing-doc reference; add `schema_migrations` note | Batch 1 |

## Verification

- `mix compile` clean (from `<host-app>`) — `Generated phoenix_kit_locations app`
- `mix format --check-formatted` clean (note: this surfaced unrelated
  pre-existing format drift in `location_form_live.ex` +
  `attachments.ex` resolved in commit `05471c4` before this batch)

Tests not re-run end-to-end this batch — none of the changes touch
runtime behaviour (mix.exs constraint tightening, comment edits).
Compile-clean is the load-bearing verification.

## Open

None.
