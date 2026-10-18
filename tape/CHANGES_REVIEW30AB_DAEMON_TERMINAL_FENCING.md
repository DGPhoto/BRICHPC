# Review 30AB — daemon failure propagation and terminal-run fencing

Review 30AB hardens the tape daemon after forensic analysis of the failed real APPEND run
`smoke_real1__20260731T214413Z__0004`.

The APPEND failure itself was caused by the pre-30AA stream-gate race (`chunker rc=1`, upstream GNU tar
receiving SIGPIPE and exiting 141). Review 30AA already fixed that race. Review 30AB deliberately does
**not** weaken the tar/chunker failure policy and does not treat tar rc=141 as success.

## Tape helper failure propagation

`tape_prepare_pair()` and `tape_release_all()` previously relied on `set -e` inside functions that are
invoked from `if`/`||` contexts. Bash suppresses errexit for that dynamic context, allowing a failing
worker subshell to be followed by a successful `bric_event`, which changed the function return code to 0.

Review 30AB captures worker return codes explicitly before emitting success events:

- `PAIR_PREPARE_END` is emitted only after successful pair preparation;
- failures emit `PAIR_PREPARE_FAILED` and propagate non-zero;
- `MEDIA_RELEASE_DONE` is emitted only after confirmed release;
- failures emit `MEDIA_RELEASE_FAILED` and propagate non-zero.

All three daemon call sites also execute `tape_prepare_pair` in a child process. An unexpected direct
`die`/`exit` in the helper therefore cannot terminate the main daemon process.

## Terminal-run data-path fence

A run containing any of these markers is fenced from new tape I/O:

- `run.ABORTED`
- `run.ABORT_DONE`
- `run.CLOSED`
- `run.DENIED`

The fence exists both in `one_pass()` and inside `handle_chunk()` before and after the atomic READY claim.
This closes the race where a terminal marker appears between directory enumeration and `READY -> CLAIMED`.

Marker **existence** is sufficient to stop append-only tape I/O, but is explicitly **not delete authority**.
An unsigned, torn or forged terminal marker can cause a visible denial of service, but cannot delete the
only staged ciphertext. Destructive staging cleanup happens only in `handle_abort()` after `run.ABORTED`
has passed signature verification and run/project path binding checks.

The same rule applies to an existing `chunk_*.ERROR`: it fences further processing but does not delete
ciphertext merely because the marker exists.

## Claim/reclaim correctness

`marker_claim` is a same-filesystem rename and therefore preserves mtime. Review 30AB explicitly touches
`chunk_*.CLAIMED` after a successful claim so `claim_ttl_hours` measures time since the daemon acquired the
claim rather than time since the cluster published READY.

Startup and periodic reclaim now use the complete terminal-run fence. Claims associated with DONE, ERROR
or terminal runs are not requeued. They are also not destructively removed merely because an unverified
marker exists; verified abort handling or normal bus cleanup owns deletion.

## Verified ABORT cleanup

After signature and path-binding verification, `handle_abort()`:

1. marks all run segments `ABANDONED`;
2. releases the reservation;
3. removes pending READY/CLAIMED/ERROR markers, signatures and staged ciphertext/sidecars;
4. publishes signed `run.ABORT_DONE`.

If ABORT and PROJECT_CLOSING coexist, ABORT wins and close is not attempted in that pass.

## Tests

Added:

- `test/run_tape_failure_propagation.sh`
  - pair-prepare failure cannot masquerade as success;
  - media-release failure cannot masquerade as confirmed-empty;
  - all three daemon pair-prepare call sites remain process-isolated.
- `test/run_terminal_drain_safety.sh`
  - signed/path-bound ABORT may clean staging;
  - unsigned terminal markers fence but do not delete ciphertext;
  - unsigned ERROR fences but does not delete ciphertext;
  - READY -> CLAIMED refreshes mtime;
  - ERROR/terminal claims cannot enter the old reclaim loop;
  - startup reclaim recognizes ABORT_DONE and the complete terminal fence.

`test/run_drive_state_timing.sh` and shell syntax validation were also rerun after these changes.
`test/run_stream_gate_race.sh` was rerun with a local SQLite compatibility CLI and still passes; that
compatibility result is not counted as native-SQLite integration validation.

## Compatibility

- database migration: none
- on-tape format: unchanged (`BRIC-FORMAT-V1`)
- cryptography: unchanged
- restore format: unchanged

## Package hygiene

The supplied 30AA archive was missing/stale for four files named by its manifest. Review 30AB rebuilds
the base from Review 30Z only where the older bytes exactly match the expected 30AA SHA-256, preserving
provenance rather than guessing. The accidental zero-byte managed file `.timeout 60000` is removed from
the release; the inventory importer, preflight tool and systemd unit are retained at their manifest-pinned
bytes.
