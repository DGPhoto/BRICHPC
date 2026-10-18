# Review 33R3 — deterministic gate closure

Date: 2026-10-09  
Baseline: Review 33R2 candidate `4741af07aae41b88b9b885c38618f9c498819ddc02a4a41f9de669cdb9e7d3ca`

Review 33R3 is a narrow follow-up to the independent 33R2 gate. The restore transaction design is
frozen; only G1–G5 are addressed.

## Product fixes

### G1 — configured journal root is a base, not a shared per-user directory

If `BRIC_RESTORE_JOURNAL_ROOT` is explicitly configured, BRIC now uses
`$BRIC_RESTORE_JOURNAL_ROOT/<effective-uid>`. The final per-UID directory is still required to be
caller-owned, mode-safe and on a local filesystem. The default remains
`/var/tmp/bric-restore-journal-<uid>`.

This preserves D1 while allowing one site-wide base for multi-user Slurm/DR use. It also allows the
root and `nobody` phases of the DR test to use the same configured base safely.

### G3 — live relax path cannot follow symlinks outside DEST

Before a directory is recorded, marked APPLYING, refreshed or chmod-relaxed, BRIC now requires:

- lexical containment below the canonical destination;
- no symlink component in the path from DEST to the target;
- resolved containment (`readlink -m`) below DEST.

The same live-path validation is applied to journal rows before stale recovery mutates anything.
This keeps the lexical `..` fence and adds the resolved/symlink fence missing in 33R2.

## Test-harness fixes

### G2 — no `kill 0`

`run_verify_failure_attribution.sh` uses an explicit guarded `if` for daemon cleanup. A zero/unset PID
is a no-op and can never signal the test's own process group.

### G4 — deterministic process-group teardown for all background daemon loops

A test-only helper (`test/lib_test_daemon.sh`) stops a private `setsid` process group only after a
safe liveness probe. Every background `bric-tape-daemon --loop` launch in the suite now uses
`setsid`; the previously missed close-fault, daemon-crash, singleton-migration, legacy-daemon and
written-recovery paths are included. Foreground `--once` invocations need no process-group teardown.

### G5 — journal hermeticity survives clean environments

The suite creates a dedicated world-traversable/sticky-style per-suite journal base under `/tmp`, a
separate base per test, and `lib_restore_txn.sh` appends the effective UID. `run_config_file.sh` and
`run_user_activation.sh` explicitly carry the base through their `env -i` environments. The suite
removes the per-suite base on exit.

## Invariants

Unchanged:

- `BRIC-FORMAT-V1`;
- `database_migration=config-v32b5-logical-namespace`;
- protected producer/chunking files;
- all `tape/**` runtime bytes.

Review 33R3 remains `build_state=candidate` until an independent native gate produces two consecutive
serial 81/81 runs with real sqlite3, ACL and attr tooling.
