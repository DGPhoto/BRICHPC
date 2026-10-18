# Review 30V — terminal QNAP bus cleanup

The QNAP tree is a transient transport bus, not a third archive copy. Previous releases reclaimed the
large encrypted chunk blobs after both tape copies verified, but retained every run directory with its
signed markers, chunk metadata and `close/` handoff artifacts. Successful restore request directories
were removed but their now-empty `restore/<project>` parent remained.

## Changes

- `bric-close` removes a CLOSED run directory only after the cluster has verified `run.CLOSED` and
  committed `status=CLOSED` to the cluster catalog.
- Reservation denial removes its run directory only after the signed `run.DENIED` has been verified
  and `status=DENIED` committed.
- FAILED/CANCELLED cleanup is gated by the tape server's signed `run.ABORT_DONE`; if the daemon is
  down or the acknowledgement is absent/invalid, the directory is deliberately retained for recovery.
- Successful restore cleanup also prunes an empty `restore/<project>` parent.
- New root command `bric-bus-cleanup [--dry-run] [--project NAME] [--force]` safely removes terminal
  directories left by older releases or by a crash between catalog commit and final `rm -rf`.
- Active and catalog-unknown directories are never removed. `--force` still requires a terminal
  cluster-catalog state and exists only for operator recovery after external verification.
- `BRIC_KEEP_TERMINAL_BUS=1` retains terminal bus directories for debugging. The test suite uses this
  explicitly where it needs to inspect terminal receipts; production defaults to cleanup.

No database schema, key material, catalog content, configuration, logs or on-tape format changes.
