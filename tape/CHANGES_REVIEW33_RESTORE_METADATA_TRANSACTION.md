# Review 33 — Restore metadata transaction

Date: 2026-10-08  
Baseline: final Review 32B5R2  
Baseline tarball SHA-256: `46874ddae77cd32fa1a9fee0ecae26b0e136b413c4f78bdd56bddbdfeda3748b`

## Purpose

Review 33 fixes the remaining restrictive-directory restore class in normal restore and disaster
recovery. It does not change backup producer bytes or the on-tape format.

The failure class was: a directory restored with a restrictive final mode (for example `000`) could
be finalized by one TAR/chunk before BRIC had finished writing or verifying descendants. Subsequent
writes/stat/sha256 operations could then fail with EACCES and surface as `MISSING/WRONG-TYPE` or
`VERIFIED-STREAM` despite correct recovered bytes.

## Restore metadata transaction

New helper: `cluster/scripts/lib_restore_txn.sh`.

Each restore destination gets a per-UID SQLite journal under
`/var/tmp/bric-restore-journal-UID` by default, configurable with
`BRIC_RESTORE_JOURNAL_ROOT`. The journal path is refused if it resolves inside `DEST`.

Directory state transitions are:

- `RECORDED` — metadata snapshot exists;
- `APPLYING` — tar is allowed to change this directory; the stored snapshot is the rollback state
  if the process dies before post-extraction refresh;
- `RELAXED` — archive-final metadata has been captured and owner `rwx` has been temporarily added
  so later chunks and verification can traverse the tree.

Directory paths are journalled as hexadecimal keys, not line-oriented text, so embedded newlines do
not corrupt journal iteration.

Before writing payload BRIC snapshots/relaxes existing ancestors. Before a TAR_PART, directory
members in that chunk are marked APPLYING. After successful extraction, those directory metadata
snapshots are refreshed from the extracted destination and the directories are relaxed again.
This makes restrictive directory metadata safe even when directory metadata and descendants occur in
different chunks.

After all payload is present, BRIC runs `sync -f DEST`, verifies the destination while directories
remain traversable, and then replays final directory metadata deepest-first.

A stale journal from a dead process is recovered automatically before a new restore begins. A journal
whose recorded PID is still alive blocks a second restore to the same destination. Metadata drift
while a directory is in BRIC's RELAXED state fails closed and preserves the journal instead of
silently overwriting the intervening change.

## ACL/xattr scope

The transaction snapshots and replays access/default ACL representation when `getfacl/setfacl` are
available and xattrs when `getfattr/setfattr` are available. This prevents BRIC's temporary chmod
from permanently changing destination ACL/xattr state.

This is **not** a new source-ACL/xattr archival claim. The existing producer still does not invoke GNU
tar with `--acls`/`--xattrs`, so Review 33 does not alter `BRIC-FORMAT-V1` or retroactively add ACL/
xattr fidelity to tapes.

## Strict destination verification

New restore option:

`--require-destination-verify`

When enabled, any regular file that ends as `VERIFIED-STREAM` rather than
`VERIFIED-DESTINATION` makes the restore fail. The option is supported by the user CLI, local mode,
Slurm restore and DR.

## DR

`bric-dr-from-tapes.sh` now uses the same metadata transaction as normal restore. Root and non-root
recovery use separate per-UID journal roots. Bare DR recovery bundles must include
`cluster/scripts/lib_restore_txn.sh` alongside `bric-dr-from-tapes.sh`.

## Tests

Added `test/run_33_restore_txn.sh`, covering:

- mode-000 cross-chunk model;
- stale APPLYING crash journal recovery;
- newline-containing directory path;
- journal-outside-DEST enforcement;
- metadata drift fail-closed;
- ACL round-trip when ACL tools/filesystem support are present;
- xattr round-trip when attr tools/filesystem support are present.

`run_dr_e2e.sh` was updated so its unprivileged copied DR bundle also includes the new helper.

Development-container results:

- `run_33_restore_txn.sh`: PASS with SQLite compatibility shim; ACL/xattr subtests skipped because
  `acl`/`attr` tools are absent in the build container;
- `run_cli_help_man.sh`: PASS;
- `run_32b5_dr_verify_semantics.sh`: PASS;
- `run_32b5_slurm_cli.sh`: PASS;
- changed Bash scripts: `bash -n` PASS.

The 32B5 logical-restore E2E was started but the build container's compatibility SQLite wrapper is too
slow for the test's timing envelope; this is not counted as PASS or FAIL. A complete native gate with
real `sqlite3`, `setfacl/getfacl`, and `getfattr/setfattr` is required before installation.

## Invariants

Unchanged from 32B5R2:

- `BRIC-FORMAT-V1`;
- `database_migration=config-v32b5-logical-namespace`;
- backup producer/chunking pipeline;
- tape daemon, robotics, placement, crypto and HMAC format.

Review 33 is a **candidate** and must not be installed until the native review gate is green.
