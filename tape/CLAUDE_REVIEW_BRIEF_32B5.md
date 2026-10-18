# BRIC Archive 2.0 Review 32B5 — external review brief

Please review the **actual Review 32B4A -> 32B5 source diff and full 32B5 tree**, not the design notes alone.

## Baseline and invariants

Baseline tarball SHA-256:

```text
095878febc2f71f7f695aaf8976220470a0a445b63532685e6cc5378a4606ca4
```

The release must remain `BRIC-FORMAT-V1`. Verify independently that these files are byte-identical to 32B4A:

```text
cluster/scripts/bric-stream-backup.sh
cluster/scripts/bric-stream-parallel-produce.sh
cluster/scripts/bric-chunk.sh
cluster/libexec/bric-tar-stream
cluster/libexec/bric-tar-stream.go
tape/**
```

No change to crypto, HMAC, tape markers, tape placement, tape robotics, chunk payload representation or TAR member names is intended.

## Review focus

### 1. Additive schema and mid-run upgrade

`runs` appends exactly:

```sql
source_canonical_path TEXT,
logical_root          TEXT
```

Review `bric_ensure_v32b5_cluster_schema` for re-entrancy/concurrency and conservative legacy backfill. In particular, relative legacy `source_path` values are deliberately not canonicalized because their original working directory is unknown.

Verify that fresh and migrated `PRAGMA table_info(runs)` column order is identical. Review `bric-close.sh`: it migrates the live DB, compares source/destination column lists, and uses an explicit `runs` column list rather than `INSERT ... SELECT *`. Please test a run created under an actual 32B4A DB and closed after upgrading the software to 32B5.

### 2. Collision transaction

Both planners perform root/source collision checking in the same `BEGIN IMMEDIATE` transaction that inserts the new run. A CLOSED or active binding with another/unknown canonical source rejects before reservation. Same root + same canonical source is a version. Terminal FAILED/DENIED/CANCELLED runs are intentionally not namespace bindings.

Please stress two concurrent planners and verify:

* one-active-run policy is preserved;
* incompatible root races cannot both insert;
* rejected requests publish no `run.RESERVE_REQUEST` and create no active ghost run;
* a legacy root with `source_canonical_path IS NULL` fails safe;
* same source/same root succeeds as a later version;
* a genuinely different `--as` name succeeds.

### 3. `--as` propagation and validation

Trace both CLI forms through `bric-run`, `cluster/bin/bric`, local stream planner, and Slurm orchestrator/planner. The producer scripts are intentionally unchanged and receive the canonical source exactly as before.

Please exercise invalid UTF-8/NFC, decomposed Unicode, controls/newlines, slash, dot components, >255-byte names, trailing slash default basename, symlink source, and both local detached and Slurm execution.

### 4. Multi-run catalog view

Review `browse_query` CTE/window semantics. Default view should be union of CLOSED runs keyed by `logical_root/rel_path`, newest-containing-run wins; older-only paths remain visible. FAILED runs must not appear. `--history` must preserve all versions, `--run` must remain exact, and filtering/search/pagination must be global after view construction.

Please test path newline/tab/backslash escaping and same `rel_path` under distinct roots.

### 5. Logical restore

For `--file ROOT/REL`, only `REL` may be passed to TAR/catalog physical lookup, while the destination is `DEST/ROOT/REL`. Check both TAR_PART and LARGE_FILE_CHUNK. Explicit `--run` must keep legacy bare-path compatibility and reject a different logical root. Automatic ambiguous bare paths must fail, and traversal validation must remain effective.

Full restore must remain exactly one latest CLOSED run, unprefixed, as in 32B4A.

### 6. Verification reporting

Review `verify_one()`. A failed `sha256sum` invocation after successful authenticated/decrypted extraction must produce `VERIFIED-STREAM`, not `CHECKSUM-MISMATCH`; a successfully computed unequal digest must fail as `CHECKSUM-MISMATCH`. HMAC, decrypt and tar failures must remain fatal and must never be converted into stream verification. Directory/symlink missing/type errors remain failures.

Do not interpret `VERIFIED-STREAM` as destination reread or storage durability proof.

## Test instructions

Run with a **native sqlite3 CLI**. This development container did not have one, so the complete native suite has intentionally not been claimed as PASS.

```bash
# HOST: review/test host with the complete extracted 32B5 release
# USER: non-root test user where supported by the suite
cd <review32b5-tree>
sha256sum -c MANIFEST.sha256
bash -n cluster/bin/bric cluster/bin/bric-run cluster/scripts/lib_common.sh \
  cluster/scripts/bric-stream-plan.sh cluster/scripts/bric-plan.sh \
  cluster/scripts/bric-close.sh cluster/scripts/bric-restore.sh \
  test/run_catalog_browse.sh test/run_32b5_schema_namespace.sh \
  test/run_32b5_logical_restore.sh

test/run_all_tests.sh
```

At minimum, inspect the explicit 32B5 tests and existing progressive restore/DR/update tests. Preserve `[N/TOTAL]` runner output in the review evidence.

## Development-container evidence (non-native SQLite CLI)

The following were executed with a test-only `sqlite3` compatibility program linked against the system SQLite library, therefore they are **not substitutes for native CLI validation**:

* `test/run_32b5_schema_namespace.sh` — PASS
* `test/run_catalog_browse.sh` — PASS
* `test/run_32b5_logical_restore.sh` on simulated tape backend — PASS after correcting one test assertion that initially matched the summary text `CHECKSUM-MISMATCH=0`
* existing `test/run_restore_progressive.sh` on simulated tape backend — PASS
* shell syntax checks on modified shell scripts — PASS

During development the new logical-root test found and caused correction of an actual validator bug: newline could evade the first ASCII-control check when implemented with `grep`. The final implementation uses byte-count filtering for C0/DEL controls before Unicode normalization.

## Release gate

Please return explicit findings by severity and state whether any issue blocks installation. The candidate should not be installed merely because the targeted compatibility-harness tests pass. Native `sqlite3` full-suite PASS plus review acceptance are still required.
