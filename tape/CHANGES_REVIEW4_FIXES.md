# CHANGES — Review-4 fixes (concurrency, real flow control, robustness)

External review pass on `bric_archive_2.0_review3_complete`. The reviewer could not run the full
suite (no `sqlite3` in their sandbox); every fix below was implemented AND verified by running the
suite here (19 tests pass; `run_real_tape_smoke` needs `--vt` and is skipped). Two new harnesses were
added: `test/run_concurrency_guards.sh` and `test/run_local_abort.sh`.

## Fixed (demo-blockers)

1. **Real sliding window on the QNAP (#1, #5).** `--array=…%N` only throttles how many SLURM tasks
   *run*; a task could publish `READY` and exit while the tape server was still draining, so the bus
   could hold far more than `max_inflight_chunks` blobs. `bric-chunk.sh` now BLOCKS before staging a
   blob until (a) this run has `< max_inflight_chunks` blobs on the bus and (b) total bytes on the bus
   are `< qnap_budget_bytes`. The measure is the **real `chunk_*.enc` files present** on the QNAP — the
   tape daemon removes each blob the instant both copies are VERIFIED — not the cluster catalog state
   (which only reaches `DONE` later, in `bric-finalize`). A stuck tape now correctly stalls production
   instead of overflowing the QNAP. Concerns are cleanly separated, as the reviewer suggested:
   `max_concurrent_producers` → `producer_slot_acquire` (run count); `max_inflight_chunks` +
   `qnap_budget_bytes` → the per-chunk gate in `bric-chunk.sh`.

2. **Atomic `run_id` (#2).** `new_run_id()` wrapped the counter `UPDATE`+`SELECT` in
   `BEGIN IMMEDIATE … COMMIT`, so two backups starting in the same second can no longer read the same
   counter and collide.

3. **One active run per project (#3).** `bric-plan.sh` inserts the run row only if no other run for the
   project is in an active state (`PLANNING/RESERVED/PRODUCING/DRAINING/CLOSING`); the check and the
   insert are one `BEGIN IMMEDIATE` transaction (TOCTOU-free). Prevents ambiguous ARCHIVE/APPEND
   ordering, two runs writing `catalog_project.enc` at once, and contention on the project's dedicated
   tapes. Sequential runs (append) are still allowed.

4. **Local-mode abort trap (#4).** A chunk that died mid-run under `set -e` could leave the run stuck in
   `PRODUCING` (and now also wedge the global producer slot). `cmd_backup` (local) wraps the chunk loop
   in an `ERR/INT/TERM` trap that routes through the SAME `bric-finalize` abort path SLURM uses via
   `afterany`: the run is marked `FAILED`, a signed `run.ABORTED` is published (tape reservation
   released) and the producer slot is freed. Covered by `test/run_local_abort.sh` (fault injection).

## Fixed (robustness / hardening)

7. **Tape reservation only counts usable capacity (#7).** `bytes_free_pair()` now clamps to `>= 0`
   (a full tape no longer yields a negative term) and counts a pair only if it is complete (2 tapes)
   and both are non-`RETIRED`/non-`BAD`. New-pair selection requires `health IN ('OK','SUSPECT')`, and
   write placement skips any tape (or partner) that is `BAD`/`RETIRED`.

10. **No `eval` in setup (#10).** `bric-setup.sh`'s `run()` executes an argv array (`"$@"`) instead of
    `eval "$*"`; every call site passes separate arguments (and `env VAR=val …` for the one
    env-prefixed call), removing the shell-injection surface from site/config values.

- **Restore verifies non-regular entries (minor).** `verify_one()` now checks that directories exist as
  directories and symlinks exist as symlinks (previously `sha256_plain=''` made it return OK without
  checking). Full symlink-target equality would need the planner to record the target (a `link_target`
  column) — noted as a follow-up.
- **Explicit path-traversal guard (minor).** Before any extraction, `bric-restore.sh` refuses the run if
  the catalog lists any `rel_path` that is absolute or contains a `..` component — defense in depth on
  top of the HMAC check and GNU tar's default `..` refusal.

## Clarified (config no longer misleading)

6. **Project-exclusive tapes only (#6).** `tape_exclusivity` is `project`-only in the code; `owner`/
   `shared` were never honored. The daemon now refuses to start on those values, and the config
   comments say so. `parallel_drives` is documented as DOCUMENTATION-ONLY: the write path always
   serializes PRIMARY then BACKUP (one drive); `2` does not yet drive two drives in parallel.

## Fixed (asynchronous restore + project-level DR)

8. **Web restore is no longer killed after 120 s (#8).** A restore (stage from tape + decrypt +
   verify) can outlast an HTTP request, so the web no longer runs it synchronously under
   `subprocess.run(timeout=120)`. It is launched **detached** — submitted as a SLURM job when `sbatch`
   is available (so it survives the web session and runs on a node), otherwise a background process —
   and streamed to a per-job log. The browser is redirected to a live status page that polls
   `GET /api/restore-status?job=…` and shows running → done/failed plus the log tail. Job ids are
   validated (no path traversal). Covered by `test/run_web_restore_async.sh`.

9. **Project-level disaster recovery — single-file option (#9).** This capability already existed as
   `cluster/scripts/bric-dr-from-tapes.sh` (recover a whole project from the **tapes + user key alone** —
   no cluster/tape catalog/daemon/QNAP — with automatic PRIMARY→BACKUP healing on HMAC failure, HMAC +
   plaintext-SHA verification, and an admin escrow break-glass via `--master-key-file`). The only thing
   the reviewer asked for that it lacked was single-file recovery, so a `--file REL` option was added:
   it finds the latest run holding that path and extracts just that member (TAR_PART) or reassembles just
   that file (LARGE_FILE_CHUNK), then verifies its plaintext SHA-256. (Correction: an earlier draft of
   this batch mistakenly added a parallel `restore_project_from_tapes.sh`; that duplicate was removed and
   the missing feature folded into the existing, better-integrated script instead.)

## Still open (next batch — bigger, not yet done)

- **Tape-rebuild explicit pair map (minor).** Document that DR rebuild derives pairing from barcode
  parity, and allow an explicit pair map when barcodes break that convention. NOT yet implemented.
