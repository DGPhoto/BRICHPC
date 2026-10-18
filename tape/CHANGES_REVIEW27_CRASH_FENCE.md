# CHANGES — Review 27: crash fence + immediate CLAIMED recovery

## What review 26 fixed, and what it did not

Review 26 correctly proved that the singleton `flock` on fd 9 could be inherited by nested
command substitutions.  Closing fd 9 in `write_copy` makes the singleton available after the
main daemon is killed.

That does **not** make the interrupted backup recoverable by itself.  `handle_chunk` has already
renamed `chunk_N.READY` to `chunk_N.CLAIMED`.  The restart path abandons `WRITING` rows, but the
normal drain loop only scans `READY`; a `CLAIMED` marker is reclaimed only after
`claim_ttl_hours` (default: six hours).  The 120-second crash test therefore waits until its drain
timeout.

There is also a safety race: after fd 9 is closed, the old `write_copy` command-substitution can
survive the daemon and continue updating the tape/catalog while the new daemon starts.  Requeueing
`CLAIMED` immediately without fencing that old worker could produce concurrent writes, duplicate
sim file numbers, or recovery/accounting races.

## Fix

1. Add a second lock, `BRIC_TAPE_WORK_LOCK` (default `${BRIC_TAPE_LOCK}.work`).
   - fd 9 remains the nonblocking daemon singleton and is deliberately dropped by IO workers.
   - fd 7 is a blocking generation/work fence and is deliberately inherited by workers.
   - after a SIGKILL, the new daemon can acquire fd 9, but it waits on fd 7 until every old orphan
     has really stopped touching tape/catalog state.

2. After acquiring both locks, run `recover()` and immediately requeue every non-terminal
   `chunk_*.CLAIMED` to `READY`.  `DONE`, `ERROR`, aborted and closed claims are stale bookkeeping
   and are removed.

3. Remove `CLAIMED` and its surviving `READY.sig` after publishing a successful `DONE`.  Previous
   versions left one `CLAIMED` marker behind for every successful chunk.

4. Make `--recover` and `--verify` use the same locks.  Previously `--recover` bypassed the daemon
   singleton entirely and could alter the catalog concurrently with a live daemon.

5. Remove accidental debug leftovers from `test/` (`_dc_keep.sh`, `_dck.sh`, `_k.sh`, `_kc.sh`,
   and `rm`). They were not selected by `run_all_tests.sh`, but did not belong in a release archive.

6. Make `run_daemon_crash.sh` deterministic:
   - force a sim append delay only in daemon A;
   - wait for a real `CLAIMED + WRITING` state before SIGKILL;
   - always persist the backup exit status despite `set -e`;
   - clean up the background backup process;
   - assert the startup reclaim directly.

## Validation performed here

- Deterministic one-chunk reproduction: review 26 leaves `chunk_0001.CLAIMED` indefinitely while
  the segment changes from `WRITING` to `ABANDONED` and can later be changed to `VERIFIED` by the
  surviving orphan.
- Patched deterministic reproduction: daemon B waits for the old worker, requeues the claim,
  reuses the verified PRIMARY, writes only the missing BACKUP, publishes DONE, and removes CLAIMED.
- Patched `run_daemon_crash.sh`: PASS with 16 chunks and 32 VERIFIED copies.

The full suite still needs to be run on both target hosts with their native sqlite3/OpenSSL/Bash.
