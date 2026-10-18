# Review 33R2 — Gate determinism and permission regression fixes

Date: 2026-10-08  
Baseline feature candidate: Review 33 `d1537c131ee64b09c0ddcfec862d24c9b7a924ba1cb173fe4452dcde6424d377`  
Production baseline: final Review 32B5R2 `46874ddae77cd32fa1a9fee0ecae26b0e136b413c4f78bdd56bddbdfeda3748b`

Review 33R2 contains the Review 33R1 hardening (D1–D8) plus the follow-up fixes S1 and N1–N3 from the independent 33R1 gate.

## D1–D8 retained/fixed

- Journal root and journal file are private, caller-owned, non-symlink and host-local.
- Every stale journal is bound to the exact canonical DEST and every journal path must remain lexically below DEST before any replay occurs.
- Destination xattr snapshots are `user.*` only; ACLs are handled separately by getfacl/setfacl.
- Recovery checks metadata drift before mutation and preserves the journal on disagreement.
- Readable files lacking catalog plaintext digests are `NO-DIGEST`, not `VERIFIED-STREAM`; strict destination verification fails only when re-read really fails or integrity/type verification fails.
- `existed=0` APPLYING rows survive recovery and are resumed until extraction captures final metadata.
- Scripted DR documentation names `lib_restore_txn.sh` as a required companion.
- `sync` is required; writeback uses `sync -f DEST` with safe global-`sync` fallback.
- Process identity uses `/proc/PID/stat` starttime to distinguish an active restore from PID reuse.

## S1 — deterministic test-daemon teardown

The 26 tests identified by the independent gate now start their tape daemon in a dedicated session/process group using `setsid`. Cleanup terminates the whole daemon process group before removing the workroot, with a direct-PID fallback and cleanup retry. This closes the parent-killed/child-survives race that made `run_bus_signing.sh` randomly fail after all assertions had passed.

No tape-daemon production code was changed.

## N1 — no restore-process umask leak

Journal directory and SQLite-file creation use `umask 077` only inside subshells. `rtxn_begin` never changes the caller's process umask. This removes the Review 33R1 regression where `LARGE_FILE_CHUNK` outputs created after transaction startup could silently change from mode 0644 to 0600.

The pre-existing broader question of restoring an explicitly archived LARGE_FILE_CHUNK mode is separate; Review 33R2 only restores pre-33 behavior and does not claim a new on-tape file-mode contract.

## N2 — hermetic restore journals in the suite

`test/run_all_tests.sh` injects a per-test `BRIC_RESTORE_JOURNAL_ROOT` below that test's private runtime-log directory. Restore-performing tests no longer share `/var/tmp/bric-restore-journal-UID`, so one failed test cannot poison a later test through a stale journal.

## N3 — unknown process identity fails safe

If a journal PID is still alive but `proc_start` is missing or `/proc/PID/stat` cannot be read, BRIC now treats the restore as potentially active and refuses a concurrent transaction. Only a proven non-empty start-token mismatch is considered PID reuse/stale state.

## Regression coverage

- `run_33_restore_txn.sh` covers journal-root/path trust, recovery drift, existed=0 retry, newline paths, PID reuse, unknown live identity, user-only xattrs, ACL preservation when available, and explicitly asserts that `rtxn_begin` does not alter the caller umask.
- `run_33_restrictive_dir_e2e.sh` is a real sim-backend cross-chunk mode-000 restore and now also verifies the LARGE_FILE_CHUNK umask regression plus `NO-DIGEST` strict-verification behavior.
- `run_33_crash_recovery_e2e.sh` performs a real SIGKILL during RELAXED state and verifies stale-journal recovery/retry.
- `run_32b5_dr_verify_semantics.sh` covers `VERIFIED-DESTINATION`, `VERIFIED-STREAM`, `NO-DIGEST`, and mismatch as distinct DR outcomes.
- `run_32b5_slurm_cli.sh` asserts `BRIC_RESTORE_REQUIRE_DEST_VERIFY` survives the names-only Slurm export path.

## Invariants

Unchanged:
- `BRIC-FORMAT-V1`;
- `database_migration=config-v32b5-logical-namespace`;
- all five protected producer/chunking files;
- all `tape/**` bytes.

Review 33R2 remains `build_state=candidate` until a clean native gate (native sqlite3 + acl + attr) runs the complete suite twice serially and both runs are green.
