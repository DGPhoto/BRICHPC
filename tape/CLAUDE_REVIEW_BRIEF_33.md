# Independent review brief — BRIC Archive 2.0 Review 33

Baseline: final Review 32B5R2  
Baseline SHA-256: `46874ddae77cd32fa1a9fee0ecae26b0e136b413c4f78bdd56bddbdfeda3748b`

Review 33 addresses restrictive-directory restore handling with a crash-recoverable metadata
transaction. Treat this as a new feature gate; do not rely only on the 32B5R2 78/78 result.

## Required gate

1. Verify candidate `MANIFEST.sha256` from a clean extraction.
2. Compare directly with the supplied 32B5R2 final baseline. Confirm no changes under `tape/**` and
   no changes to the protected producer files (`bric-stream-backup.sh`,
   `bric-stream-parallel-produce.sh`, `bric-chunk.sh`, `bric-tar-stream`, `bric-tar-stream.go`).
3. Confirm `BRIC-FORMAT-V1` and `database_migration=config-v32b5-logical-namespace` remain unchanged.
4. Run the complete native suite with real sqlite3 and real ACL tooling. Install `acl` and `attr` so
   the Review 33 ACL/xattr subtests are not skipped.
5. Exercise `test/run_33_restore_txn.sh` natively.
6. Re-run at minimum: `run_32b5_logical_restore`, `run_restore_progressive`, `run_dr_e2e`,
   `run_real_e2e`, `run_security`, `run_cli_help_man`, `run_32b5_dr_verify_semantics`, and
   `run_32b5_slurm_cli`.
7. Construct an actual restore whose archived directory final mode is `000` (or equivalently denies
   traversal), with a descendant written/verified in a later chunk. Prove:
   - descendant bytes restore correctly;
   - verification is `VERIFIED-DESTINATION` while the transaction is active;
   - final directory mode returns to the restrictive archived value only after verification.
8. Kill a restore in each meaningful window: APPLYING (tar changed directory, no refresh yet),
   RELAXED, and after verification before finalization. Confirm the next restore recovers the stale
   journal without leaving permissions relaxed.
9. Confirm journal location is per UID, outside DEST, mode-protected, and a live PID prevents a second
   restore to the same destination.
10. Confirm path handling is safe for embedded newline names; inspect the `path_hex` journal design.
11. With POSIX ACL support, prove temporary relaxation does not lose access/default ACL entries or
   special mode bits. With xattr support, prove a user xattr survives.
12. Exercise metadata-drift detection: modify a RELAXED directory externally and confirm finalization
   refuses to overwrite it and preserves the journal.
13. Test `--require-destination-verify` through local CLI, Slurm CLI and DR; a forced destination
   re-read failure must be non-zero with the flag and retain existing tri-state behavior without it.
14. Review failure traps: normal nonzero exits should attempt journal rollback; drift/finalization
   failures must preserve the journal instead of blindly overwriting metadata.
15. Confirm DR recovery bundles now require/carry `lib_restore_txn.sh`.

## Important scope statement

Review 33 protects destination directory metadata while temporarily relaxing permissions. It does not
change the producer to archive source ACLs/xattrs (`tar` still lacks `--acls`/`--xattrs`). Do not
credit this release with source ACL/xattr archival fidelity.

## Installation gate

Keep `build_state=candidate` and do not install until the complete native suite and the restrictive-
directory/crash tests are green.
