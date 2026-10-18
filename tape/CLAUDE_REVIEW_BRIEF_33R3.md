# Independent review brief — Review 33R3

Review 33R3 is based directly on the supplied Review 33R2 archive
`4741af07aae41b88b9b885c38618f9c498819ddc02a4a41f9de669cdb9e7d3ca`.

The transaction design is intentionally frozen. Please focus on G1–G5 and regression only.

## Required gate

1. Verify manifest, release metadata and exact change set against the supplied 33R2 baseline.
2. Reconfirm protected producer files and all `tape/**` are byte-identical to 33R2 / the established
   32B4A anchor. `BRIC-FORMAT-V1` and the 32B5 migration token must remain unchanged.
3. Run the complete native suite **twice, serially, with no parallel reviewer workload**. Required:
   **81/81 twice**.
4. Re-run `run_bus_signing.sh` and `run_verify_failure_attribution.sh` several times standalone. No
   teardown flake and no exit 143 after PASS.
5. G1: with one explicitly configured journal base, prove root and a non-root UID create distinct
   `<base>/<uid>` private journal roots and both can restore/DR. `run_dr_e2e.sh` must pass its
   `nobody` phase.
6. G3: reproduce the prior `DEST/linkdir -> outside-directory` case. `rtxn_prepare_ancestors` must
   refuse it and the outside target mode must remain byte-for-byte/metadata unchanged. Also verify a
   planted stale journal cannot use the same symlink escape during recovery.
7. G4: audit every background `bric-tape-daemon --loop` launch. Each must use `setsid`; teardown must
   stop the group via `lib_test_daemon.sh` (or an equivalently guarded group stop). Foreground
   `--once` calls are outside this race.
8. G5: after each full suite run, verify no new `/var/tmp/bric-restore-journal-*` residue was created
   by the suite. Check `run_config_file.sh` and `run_user_activation.sh` clean environments retain the
   injected journal base.
9. Re-run the three Review 33 tests with real ACL/xattr tools:
   `run_33_restore_txn.sh`, `run_33_restrictive_dir_e2e.sh`, `run_33_crash_recovery_e2e.sh`.
10. Reconfirm D1–D8/N1/N3 remain closed; no weakening of owner/mode/filesystem checks, drift
    fail-closed behavior, user-only xattrs, NO-DIGEST semantics, existed=0 retry state, sync fallback
    or PID identity logic.

Install condition if and only if the gate is green: no active tape/archive/restore run during update.
