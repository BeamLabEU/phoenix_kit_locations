# PR #21 follow-up

The integration commit includes all three fixes in the [Codex review](CODEX_REVIEW.md). The stale-edit regression checks the persisted coordinate pair after a rejected update. The proximity tests exercise invalid search origins, and the backfill test verifies the count across consecutive runs with an existing Oban job.

The maintainer approved including the opt-in worker. Hosts can continue entering coordinates manually with the default configuration.
