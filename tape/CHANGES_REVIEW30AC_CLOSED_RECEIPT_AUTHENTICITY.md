# Review 30AC — CLOSED receipt compatibility and terminal-marker authenticity

Review 30AB was rejected before deployment after the pre-existing `test/run_job_lifecycle.sh` exposed a
contract regression: a re-published `chunk_N.READY` for an already-VERIFIED chunk of a CLOSED run was
fenced before `handle_chunk`, so the daemon no longer re-published the idempotent DONE receipt.

## Fixes

- Preserve the existing CLOSED requeue contract without permitting new tape I/O.
  - `run.CLOSED` may enter `handle_chunk` only far enough to authenticate/bind the producer markers and
    query the tape catalog.
  - If PRIMARY and BACKUP are already `VERIFIED`, DONE is reconstructed from their recorded placements;
    no segment is allocated or rewritten.
  - Immediately after that idempotent branch, the full terminal fence blocks every path that could
    allocate, prepare, or write tape.
- `run.ABORTED`, `run.ABORT_DONE`, and `run.DENIED` remain hard chunk-processing fences.
- Keep fence and cleanup authority separate: marker existence may stop I/O, but only a successfully
  verified/path-bound terminal handler may destroy staging.
- Add `test/run_terminal_marker_authenticity.sh` with bus signing required. It asserts that an unsigned
  `run.ABORTED` fences I/O while preserving READY/ciphertext and cannot publish ABORT_DONE.
- Extend `test/run_terminal_drain_safety.sh` with CLOSED receipt reconstruction from two pre-existing
  VERIFIED rows, while retaining the no-new-tape-I/O assertion.
- Update `test/run_update.sh` version assertions to Review 30AC.

## Compatibility

- Database migration: none.
- Bus protocol: unchanged; this review restores the pre-existing idempotent DONE receipt behavior.
- On-tape format: unchanged (`BRIC-FORMAT-V1`).
- Review 30AA stream-gate race fix is unchanged.
