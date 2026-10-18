# Review 30AD — stream-gate global QNAP budget race

## Trigger

A real 30AC APPEND smoke run (`smoke_real1__20260903T102531Z__0006`) failed after sustained
backpressure with the same producer-side signature previously seen on run 0004:

```text
bric-tar-stream: command .../bric-stream-gate.sh [...] failed: exit status 1
ERROR: tar stream failed (tar rc=141, chunker rc=1)
```

The tape daemon had already completed chunk 79 and then handled the signed ABORT normally.  This
showed that 30AB/30AC terminal fencing was working, but that the 30AA stream-gate race fix was
incomplete.

## Root cause

30AA removed `find | wc | tr` from the **per-run staged-chunk count** in `bric-stream-gate.sh`, because
the tape daemon legitimately deletes `chunk_*.enc` after both tape copies are VERIFIED.  However, the
gate also enforces a system-wide QNAP byte budget through `qnap_inflight_bytes()` in
`cluster/scripts/lib_common.sh`, which still used:

```bash
find "$BRIC_QNAP" -name 'chunk_*.enc' -printf '%s\n' | awk ...
```

With `set -o pipefail`, GNU find can return non-zero if a blob disappears between `readdir(2)` and
`stat(2)`.  A healthy producer then sees the gate exit 1; `bric-tar-stream` exits 1; GNU tar receives
SIGPIPE and reports rc=141; the run is aborted.

The legacy `bric-chunk.sh` producer also retained a separate per-run `find | wc` staged-count path and
was vulnerable to the same class of race.

## Fix

1. `qnap_inflight_bytes()` now invokes GNU find with `-ignore_readdir_race`.
   - Expected ENOENT caused by a concurrently drained blob is ignored.
   - Genuine find traversal/I/O/permission failures still propagate through `pipefail`, so QNAP budget
     accounting remains fail-closed.  There is deliberately no blanket `|| true`.
2. `bric-chunk.sh` now counts its run-local `chunk_*.enc` files using a Bash `nullglob` array, matching
   the race-safe policy already used by `bric-stream-gate.sh`.
3. `test/run_stream_gate_race.sh` now covers four invariants:
   - per-run window counting does not depend on find;
   - the global byte-budget scan uses `-ignore_readdir_race`;
   - genuine find failures still fail the gate;
   - the legacy `bric-chunk` path no longer uses `find | wc` for staged counting.

## Compatibility

- database migration: none
- bus protocol change: none
- on-tape format change: none (`BRIC-FORMAT-V1`)
- tape daemon/catalog semantics: unchanged

Review 30AC remains the base; 30AD changes only producer flow-control accounting, release metadata,
documentation, and regression tests.
