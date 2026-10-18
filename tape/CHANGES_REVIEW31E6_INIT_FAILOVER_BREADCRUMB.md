# Review 31E6 — initialization failover structured breadcrumb

Review 31E6 fixes the final logging telemetry gap found by the privileged onboarding gate.

## Change

When `bric_log_init()` cannot use the configured primary log root but can use the fallback, it already selected the fallback and emitted a stderr warning. 31E6 now also writes a durable structured `LOG_FAILOVER` event into the fallback with `trigger=initialization`.

The change is applied consistently to cluster `lib_common.sh`, cluster `lib_logging.sh`, and tape `lib_common.sh`.

No ACL policy, tape I/O, positioning, streaming verification, media-health logic, database schema, or on-tape format changes are made.
