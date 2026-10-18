# BRIC Archive 2.0 — Review 32B5: logical namespace and restore verification reporting

**Build date:** 2026-09-24  
**Base:** Review 32B4A (`095878febc2f71f7f695aaf8976220470a0a445b63532685e6cc5378a4606ca4`)  
**On-tape format:** unchanged, `BRIC-FORMAT-V1`  
**Build state:** candidate; do not install before native-suite validation and external review.

## Scope implemented

Review 32B5 adds catalog-only source namespacing without changing TAR members, chunk payloads, tape protocol, cryptography, HMAC, sparse handling, or the tape daemon.

### Run metadata and migration

`runs` appends, in this order, two nullable columns after the 32B4A fields:

```sql
source_canonical_path TEXT,
logical_root          TEXT
```

`bric_ensure_v32b5_cluster_schema` performs an additive, re-entrant migration. Legacy `logical_root` values are backfilled from `basename(source_path)`. A legacy canonical path is filled only when `source_path` is absolute, exists on the planner host, and `readlink -f` succeeds; relative or unavailable historical paths remain unknown rather than being guessed.

Fresh and migrated databases therefore have the same `runs` column order. `bric-close.sh` migrates the live catalog before building a project catalog, compares the source and destination `runs` schemas, fails closed on mismatch, and copies the `runs` table using an explicit column list.

### Stable logical root and `backup --as`

Both accepted backup forms support `--as LOGICAL_ROOT`:

```text
bric backup PROJECT SOURCE --as LOGICAL_ROOT
bric backup --project PROJECT --source SOURCE --as LOGICAL_ROOT
```

If `--as` is omitted, the default root is the basename of the declared source path after trailing slash removal. The root must be one UTF-8 NFC path component, at most 255 bytes, not `.`/`..`, with no slash, NUL/C0/DEL control bytes, or Unicode control/format/surrogate/private-use categories.

The CLI preserves the path text declared by the user in `runs.source_path`; the planner records `source_canonical_path` from `readlink -f` on the host actually executing the plan. Metadata is passed to local and Slurm planners without modifying the byte-producing scripts.

The planner's `BEGIN IMMEDIATE` transaction inserts a run only when both existing conditions hold:

* there is no other active run for the project; and
* the requested `logical_root` is not already bound by a CLOSED or active run to a different or unknown canonical source.

A matching root + canonical path is a new version of the same source. A historical root with unknown canonical path fails safe. `FAILED`, `DENIED`, and `CANCELLED` terminal runs do not establish the project namespace; CLOSED and active lifecycle states do. Collision rejection occurs before `run.RESERVE_REQUEST` is created.

### Multi-run `contents` / `find`

The default project view now unions all CLOSED runs. Its logical key is:

```text
logical_root/rel_path
```

For duplicate logical keys, the newest CLOSED run containing that key wins using the stable ordering `closed_at`, `requested_at`, then `run_id`. A file that exists only in an older run stays visible: 32B5 has no tombstones and does not claim the union is a point-in-time filesystem snapshot.

`--history` exposes every version with its run id. `--run RUN_ID` remains an exact CLOSED-run view. Type filtering, case-insensitive search, escaping, `--long`, `--limit`, and `--offset` are applied after the logical view is constructed, so pagination is global rather than per run/root. No tape is read.

### Logical single-file restore

Automatic single-file restore accepts:

```text
bric restore PROJECT DEST --file LOGICAL_ROOT/RELATIVE_PATH
```

BRIC resolves the newest CLOSED run containing that logical key, strips the logical root before requesting the physical catalog/TAR member, and writes the result to `DEST/LOGICAL_ROOT/RELATIVE_PATH`. `LARGE_FILE_CHUNK` uses the same destination mapping without a double prefix.

With explicit `--run`, the historical bare run-relative `--file RELATIVE_PATH` remains supported; the namespaced form is also accepted. A namespaced root that conflicts with the selected run is rejected. An automatic bare path is retained only when it is unambiguous across logical roots; ambiguity fails closed. Absolute paths, empty components, `.` and `..` are rejected.

Full restore is deliberately unchanged: `bric restore PROJECT DEST` restores only the latest CLOSED run directly under `DEST`. Review 32B5 does not add `--all-runs`.

### Restore verification classification

Regular-file verification now distinguishes the result of destination hashing from byte mismatch:

* `VERIFIED-DESTINATION`: destination SHA-256 was calculated and equals the catalog digest.
* `VERIFIED-STREAM`: authenticated/decrypted extraction completed without reported error, but the final file could not be independently re-read, or no destination digest is available.
* `CHECKSUM-MISMATCH`: the destination digest was successfully calculated and differs from the catalog digest; restore fails.
* `MISSING/WRONG-TYPE`: the expected destination object is absent or has the wrong type; restore fails.
* directories and symlinks receive type/existence verification rather than a file digest.

The completion summary and notification report separate destination-verified and stream-only counts. `VERIFIED-STREAM` explicitly does **not** claim that bytes were re-read from the destination or physically persisted by remote storage.

## Explicitly unchanged / out of scope

The following are byte-identical to Review 32B4A in this candidate:

* `cluster/scripts/bric-stream-backup.sh`
* `cluster/scripts/bric-stream-parallel-produce.sh`
* `cluster/scripts/bric-chunk.sh`
* `cluster/libexec/bric-tar-stream`
* `cluster/libexec/bric-tar-stream.go`
* all files under `tape/**`

`BRIC-FORMAT-V1`, TAR member names, `LARGE_FILE_CHUNK` representation, AES/PBKDF2 parameters, HMAC, bus marker protocol, tape placement, and tape robotics are unchanged.

Review 32B5 also does **not** implement the planned 32B5A restore journal, temporary directory permission relaxation, ACL/xattr rollback, exact cross-chunk restrictive-directory repair, or `--require-destination-verify`.

## Tests added/changed

* `test/run_catalog_browse.sh`: multi-root union, latest-wins, older-only visibility, FAILED exclusion, history, exact run view, logical-path search, newline escaping, type filtering and global pagination.
* `test/run_32b5_schema_namespace.sh`: fresh-vs-migrated column order, idempotent migration/backfill, explicit close-copy column contract, logical-root validation, synchronous `bric-run --as` rejection, and legacy unknown-canonical collision before reservation.
* `test/run_32b5_logical_restore.sh`: simulated-tape backup with `--as`, declared/canonical source metadata, TAR and `LARGE_FILE_CHUNK` logical restore, legacy `--run`, full restore baseline semantics, ambiguous bare-path/root mismatch/traversal rejection, `VERIFIED-STREAM`, and real `CHECKSUM-MISMATCH` classification.

The standard runner already prints `[N/TOTAL]` progress. This development container did not provide the native `sqlite3` CLI, so the full native shell suite is a release blocker. Targeted functional tests were run with a test-only compatibility shim linked to the system SQLite library; those results are useful development evidence but are not reported as native-suite PASS.
