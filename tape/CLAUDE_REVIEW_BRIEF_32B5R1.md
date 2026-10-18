# Independent review brief — BRIC Archive 2.0 Review 32B5R1

Baseline 32B4A SHA-256:
`095878febc2f71f7f695aaf8976220470a0a445b63532685e6cc5378a4606ca4`

Please treat this as the corrective follow-up to the first 32B5 gate.

Required checks:

1. Run the complete native suite with native `sqlite3` and real ACL tools.
2. Recheck the five formerly stale tests: `run_cli_help_man`,
   `run_local_background`, `run_local_e2e`, `run_one_command_ux`, `run_security`.
3. Run `run_32b5_dr_verify_semantics.sh` and `run_32b5_slurm_cli.sh`.
4. Re-run `run_32b5_logical_restore.sh`, `run_32b5_schema_namespace.sh`,
   `run_catalog_browse.sh`, and `run_restore_progressive.sh`.
5. Independently compare against the supplied 32B4A baseline and confirm byte
   identity for `bric-stream-backup.sh`, `bric-stream-parallel-produce.sh`,
   `bric-chunk.sh`, `bric-tar-stream`, `bric-tar-stream.go`, and `tape/**`.
6. Confirm `BRIC-FORMAT-V1` is unchanged.
7. Confirm full restore is still latest CLOSED directly under `DEST`; only automatic
   single-file logical restore uses `DEST/LOGICAL_ROOT/REL`.
8. Confirm Slurm preserves `--as 'data,2024=raw'` exactly and `backup --wait` does
   not query `created_at`.
9. Confirm DR reports an unreadable final destination as `VERIFIED-STREAM`, while a
   successfully calculated unequal digest is `CHECKSUM-MISMATCH`.

Out of scope and still planned for 32B5A: restore journal, temporary restrictive-dir
permission relaxation/rollback, ACL/xattr rollback, exact cross-chunk directory
repair, and `--require-destination-verify`.

Keep this package non-installable if any native-suite or independent-review blocker
remains.
