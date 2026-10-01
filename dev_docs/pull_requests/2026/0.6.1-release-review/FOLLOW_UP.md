# Follow-up for release 0.6.1 review

Resolution of `CODEX_REVIEW.md`, 2026-10-01.

| Finding | Resolution |
|---|---|
| HIGH: stale picker confirmation bypasses current filters | Fixed in `PlacePicker.send_selection/2`; regression tests cover ownership, types, availability and deletion. |
| MEDIUM: deleted type crashes or falsely succeeds on save | Fixed with a locked context transaction and the form's translated error redirect; changed and unchanged saves are covered. |
| MEDIUM: malformed type edit UUID crashes | Fixed by casting before lookup; context and route tests cover the missing-record result. |

`mix test`: 549 tests, 0 failures against published core 2.42.1.
`mix precommit` and `git diff --check` passed. No findings remain open from
this review. Publication is outside the requested task.
