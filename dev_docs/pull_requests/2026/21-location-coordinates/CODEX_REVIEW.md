# PR #21 review

Reviewed the coordinate migrations, schema manifest, LiveView fields and translations, distance calculations, and geocoding lifecycle against main at `f7d8e9b`. [PR #21](https://github.com/BeamLabEU/phoenix_kit_locations/pull/21)

| Severity | Finding | Resolution |
| --- | --- | --- |
| BUG - HIGH | An editor could load a pinned location, change its latitude after another editor cleared the pair, and save a latitude with a null longitude. The original changeset checked the longitude from the editor's stale copy. | Validate the coordinates Ecto will actually persist, taking untouched values from the locked database row. An integration test checks the changeset error and reads the row back. |
| BUG - MEDIUM | The radius query accepted origins beyond the valid latitude and longitude ranges. Non-finite Decimal inputs could also raise during float conversion. | Share origin validation with the distance helper and test out-of-range and non-finite origins. |
| BUG - MEDIUM | Running the missing-coordinate backfill twice reported existing unique jobs as newly inserted on the second pass. | Count only inserts for which Oban reports no conflict. The regression test runs the backfill twice and checks both totals. |

## Verification

The PostgreSQL-backed suite passed with 704 tests and zero failures. The final tree passed `mix precommit` and `git diff --cached --check`.
