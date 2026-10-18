# Review 32B5R1 — independent-gate fixes

Date: 2026-09-24
Base feature release: Review 32B5 logical namespace
Baseline 32B4A SHA-256:
`095878febc2f71f7f695aaf8976220470a0a445b63532685e6cc5378a4606ca4`

32B5R1 is the corrective candidate produced from the independent 32B5 gate. It is
not Review 32B5A; that name remains reserved for restore journal and
restrictive-directory work.

## B1 — stale test contracts

Five tests were reconciled with the already-correct 32B5 runtime behavior:

- `run_cli_help_man.sh`: backup usage includes `[--as LOGICAL_ROOT]`.
- `run_local_background.sh`: isolated stub provides logical-root helpers.
- `run_one_command_ux.sh`: same helper stubs.
- `run_local_e2e.sh`: automatic single-file restore is checked at
  `DEST/LOGICAL_ROOT/RELATIVE_PATH`.
- `run_security.sh`: same single-file destination contract.

Full restore remains unchanged: latest CLOSED run directly under `DEST`.

## F1 — DR verification

`bric-dr-from-tapes.sh` now preserves the result of destination hashing:
readable+matching => `VERIFIED-DESTINATION`; readable+different =>
`CHECKSUM-MISMATCH`; successful authenticated/decrypted recovery with a destination
that cannot be re-read => `VERIFIED-STREAM`. The latter no longer aborts an
otherwise successful DR merely because final re-read is impossible.

Regression: `test/run_32b5_dr_verify_semantics.sh`.

## F2 — Slurm `--as`

User-controlled BRIC values are no longer embedded in Slurm's comma-separated
`--export=NAME=value,...` grammar. Exact `BRIC_*` values are placed in the launch
environment and `sbatch --export=ALL` is used, preserving roots such as
`data,2024=raw`.

## F3 — Slurm `backup --wait`

The submitted-run query now orders by `requested_at DESC, run_id DESC`, not the
nonexistent `created_at`.

Regression for F2/F3: `test/run_32b5_slurm_cli.sh`.

## Invariants and scope

Byte-identical to 32B4A: `bric-stream-backup.sh`,
`bric-stream-parallel-produce.sh`, `bric-chunk.sh`, `bric-tar-stream`,
`bric-tar-stream.go`, and all `tape/**`.

`BRIC-FORMAT-V1`, TAR members, `LARGE_FILE_CHUNK`, crypto, HMAC, tape placement and
robotics are unchanged.

Not implemented here: restore journal, temporary restrictive-directory permission
relaxation/rollback, ACL/xattr rollback, cross-chunk restrictive-directory repair,
or `--require-destination-verify`.

Status remains `build_state=candidate`; the complete native suite must be rerun
before installation.
