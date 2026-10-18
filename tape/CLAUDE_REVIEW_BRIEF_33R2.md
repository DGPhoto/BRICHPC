# Independent review brief — BRIC Archive 2.0 Review 33R2

Feature baseline: Review 33 `d1537c131ee64b09c0ddcfec862d24c9b7a924ba1cb173fe4452dcde6424d377`  
Production baseline supplied separately: final Review 32B5R2 `46874ddae77cd32fa1a9fee0ecae26b0e136b413c4f78bdd56bddbdfeda3748b`

33R2 includes D1–D8 hardening from 33R1 and addresses every follow-up from the 33R1 gate: S1 plus N1–N3.

## Required gate

1. Verify `MANIFEST.sha256` after clean extraction.
2. Hash the supplied final 32B5R2 tarball and confirm it is exactly `46874ddae77cd32fa1a9fee0ecae26b0e136b413c4f78bdd56bddbdfeda3748b`. Compare the five protected producer files and all `tape/**` directly; require byte identity and `BRIC-FORMAT-V1` unchanged.
3. Use native sqlite3 plus real `acl` and `attr` tooling. Run the complete suite twice, serially, with no other workload. Require both runs green. In particular repeat `run_bus_signing.sh` several times; it must not fail in its EXIT cleanup.
4. S1: inspect the 26 formerly racy daemon tests. Confirm daemon launches use `setsid` and cleanup signals the whole process group before workroot deletion. Try to reproduce the former `tape_catalog.db` ENOTEMPTY race.
5. N1: start with caller umask 022. Prove `rtxn_begin` leaves it 022. On a real archive force a file through `LARGE_FILE_CHUNK`; a source 0644 file must not regress to 0600 merely because the restore transaction was initialized.
6. N2: verify every suite child receives a private `BRIC_RESTORE_JOURNAL_ROOT`, and that the suite leaves no new `/var/tmp/bric-restore-journal-*` residue.
7. N3: live PID + empty/missing `proc_start` must block another transaction. Live PID + matching start token must block. Only live PID + different non-empty start token may be treated as PID reuse/stale.
8. Re-run D1–D8 independent probes from the 33R1 review. They must remain closed.
9. Run `run_33_restore_txn.sh`, `run_33_restrictive_dir_e2e.sh`, and `run_33_crash_recovery_e2e.sh` independently.
10. Reconfirm `NO-DIGEST` vs `VERIFIED-STREAM`, including `--require-destination-verify`, DR helper behavior and Slurm flag transport.
11. Reconfirm full restore, single-file restore, DR, progressive restore, security, logical namespace, Slurm CLI and real-backend tests.

Do not install while `build_state=candidate`. Standing production install condition after approval: no active tape/archive/restore run.
