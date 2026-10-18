# BRIC Archive 2.0 — Review 32B3: irreversible CLOSED barrier + local allocator lock

Date: 2026-09-14
Base: Review 32B2
Scope: two correctness fixes discovered by the physical two-pair smoke on real LTO-9 hardware.

## 1. CLOSED is now irreversible

The physical smoke `smoke_real1__20260914T102835Z__0017` reached a complete tape-side close:
all 6 chunks were VERIFIED across pairs 1+2, all 24 close artifacts were VERIFIED, media were
returned to slots, and the daemon committed/logged CLOSED. A cluster-side Ctrl-C had already
published a valid `run.ABORTED`; on the following daemon pass Review 32B2 processed that stale marker
and changed all VERIFIED segment rows to ABANDONED.

Root cause: the main loop explicitly gave `run.ABORTED` precedence over `run.CLOSED`, even though the
close transaction had already committed an authoritative local `audit_log(CLOSED,OK)` row.

32B3 makes that local CLOSED audit row the irreversible durability barrier. A late ABORT is logged and
audited as `ABORT_IGNORED_CLOSED`, but it cannot mutate segments, reservation state, artifacts, or
publish `run.ABORT_DONE`. The bus directory is intentionally retained for cluster/tape reconciliation.
Unsigned/forged CLOSED bus-marker existence is NOT destructive authority; the decision is based on
the daemon's local SQLite catalog, so the earlier terminal-marker authenticity guarantees remain intact.

New regression test: `test/run_closed_abort_barrier.sh`.

## 2. Parallel allocator correctness lock is host-local

During the same physical smoke, two of four producer workers failed with:

    flock: 9: No locks available

The allocator mutex was `$BRIC_RUNSTATE/<run>/chunk-allocate.lock`. User runstate is intentionally in
the shared home for cross-node member-list visibility; on supekgate04fl that home is NFSv3. A retry
with runstate on local XFS completed 6/6 chunks, proving the failure was the NFS flock location.

32B3 keeps member lists in `BRIC_RUNSTATE` but moves only the allocator mutex to:

    $BRIC_LOCAL_LOCK_DIR/chunk-allocate.<run_id>.lock

`bric-setup-user` provisions `BRIC_LOCAL_LOCK_DIR=$BRIC_LOG_DIR/.locks` on the local central log
filesystem. If the variable is absent (existing users), the allocator falls back to
`${BRIC_LOCAL_TMPDIR:-/tmp}/bric-locks-<uid>`. The allocator validates ownership and explicitly refuses
an NFS/NFS4 lock root.

New regression test: `test/run_allocator_local_lock.sh`.

## On-tape / DB compatibility

- No on-tape format change (`BRIC-FORMAT-V1`).
- No database schema migration.
- Existing 32B1 128 GB/progressive-restore configuration remains unchanged.
- Existing users do not require immediate re-onboarding because the allocator has a safe local fallback;
  rerunning user setup is recommended so `BRIC_LOCAL_LOCK_DIR` is explicit and persistent.

## Required validation

1. New targeted tests pass.
2. Existing terminal/authenticity, local-abort, parallel-target, multi-pair and restore-progressive tests pass.
3. Full native suite passes on supekgate04fl.
4. Repeat the small real two-pair smoke without `--wait`; confirm CLOSED remains terminal.
5. Restore the successful multi-pair run across both tape pairs and compare hashes.
