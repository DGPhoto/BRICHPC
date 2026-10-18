# BRIC Archive 2.0 Review 32A — Claude review brief

## Why this candidate exists

An urgent user operation must archive about 70 TB before 2026-09-21. The real Review-31E7 run
`PPCG_ONT__20260908T115257Z__0015` produced roughly 980 GB in 6 h 08 min (~44 MiB/s class), which is not
fast enough. Independent source reads demonstrated substantially higher aggregate Isilon throughput.
The current QNAP->brictape link is physically 1 GbE and measures ~113 MiB/s, essentially link saturation.

The requested product behavior is still: one `bric backup`, one project, no user-visible chunk/run
management. The user is willing to accept internally orchestrated child runs if that proves materially
safer, but would prefer one logical operation and transparent `status/contents/find/restore` semantics.

## Candidate implementation

This tarball takes the direct single-run route:

- one project and one `run_id`;
- 4 configurable local tar-stream data workers (`stream_parallel_workers`);
- regular files assigned NUL-safely to exactly one worker using greedy logical-byte balancing;
- worker chunk target ~245 GB by default (980 GB aggregate / 4);
- existing sparse GNU-PAX logic and one-pass plaintext SHA computation retained;
- no pre-hash source reread;
- global per-run chunk allocator protected by flock + SQLite `BEGIN IMMEDIATE`;
- `ALLOCATED -> PRODUCED -> READY` transition is serialized and chunk numbers remain globally unique;
- directories/symlinks are emitted once after all regular-data workers, so metadata chunks remain last;
- 4 MiB outer GNU-tar records with explicit EOF-record-padding drain in the Go helper;
- tape input read 4 MiB / tape output record 256 KiB;
- adaptive immediate verify positioning (`eod+bsfm2` vs `rewind+fsf`);
- QNAP occupancy now counts both `.enc` and `.enc.part`;
- QNAP staging free space is checked before reservation.

BRIC-FORMAT-V1, dual PRIMARY/BACKUP write, full readback SHA-256 verification and terminal CLOSED catalog
barrier are unchanged.

## Findings from the real 31E7 run that motivate the patch

- producer: ~44 MiB/s class;
- `/projects` parallel-read experiments exceeded 100 MiB/s aggregate and peaked much higher;
- QNAP->brictape NFS read: ~113 MiB/s, ~4 ms RTT, no retransmits, physically limited by 1 GbE;
- current tape write workers both progressed through the ~974 GB chunk; state D snapshots represented
  ordinary NFS/SCSI waits rather than a dead daemon;
- 31E7 verify `eod+bsfm2` is pathological for very large recent files given measured reverse movement
  around 210 MB/s, whereas rewind is ~46 s and fsf about 0.4 s/filemark.

## What is intentionally NOT solved yet

### P0: durable resume after coordinator/host failure

This candidate parallelizes production, but the local worker assignment is generated in temporary state.
If the coordinator dies, the existing run-abort semantics still win. Already-published chunks are
independent, but there is no supported command that reconstructs the remaining source scope and resumes
the same run without wasting prior tape work.

Please review which of these should be implemented next:

1. **Single-run durable manifest/resume.** Persist deterministic NUL-safe source/slice manifests and a
   durable slice state. Restart only unfinished slices, with exact handling of files whose chunks already
   reached READY/DONE. This preserves one physical run.
2. **Hidden run-group orchestration.** Child runs are retry units; add a logical operation/group identifier
   and make status/contents/find/restore merge them. This is operationally simpler but is multiple source
   snapshots and needs project-catalog semantics for the group.
3. **Converge on existing Slurm planner/array mode.** 31E7 already has same-run parallel chunks and Slurm
   requeue, but `bric-chunk.sh` currently performs a separate `sha256_file` read and does not preserve all
   local tar-stream sparse/exclusion semantics. Determine whether upgrading that path is less risky than
   extending the new local coordinator.

Do not approve the 70 TB run without resolving or explicitly accepting this failure-domain issue.

## P0/P1 review questions

1. Is `bric-stream-allocate.sh` capacity accounting race-free with multiple workers and reservation
   extension? In particular, inspect ALLOCATED placeholders and failure cleanup.
2. Is `bric-stream-publish.sh` safe for concurrent LARGE_FILE_CHUNK publication and a large file whose
   pieces interleave globally with other worker chunks?
3. Does `runs.n_chunks = COUNT(chunks)` remain compatible with every finalizer/tape loop once all
   ALLOCATED rows are gone? Check for any code that assumes chunk numbers are chronological source order.
4. Does serial metadata after all data workers fully preserve directory/symlink semantics and hostile
   filenames?
5. Is combined GNU-tar stderr classification sufficient for strict source consistency with N concurrent
   tar processes?
6. Is the QNAP preflight bound correct? Current formula counts max_inflight published chunks plus one
   in-progress `.enc.part` per worker, capped by total source logical bytes, then adds 5%.
7. Tape multi-pair transition is still not physically exercised. A 70 TB run will require many tape pairs.
   Define a safe smoke that forces at least one pair transition before the production archive.
8. Benchmark 1/2/4 workers and determine whether 4 adds useful throughput once the full tape
   write+position+readback cycle is included.

## Validation already completed in this environment

PASS:
- Go helper builds (`BRIC tar-stream 32A-parallel`).
- shell syntax for modified operational scripts.
- `run_performance_policy.sh`.
- `run_tar_stream.sh` ordinary/large/sparse regressions.
- `run_stream_verify.sh`.
- `run_filemark_semantics.sh`.
- `run_qnap_parallel_capacity.sh`.

Environment limitation:
- the container has no native sqlite3 CLI. A Python compatibility shim allows most functional checks but
  stalls in the later metadata transaction of `run_single_run_parallel.sh`. Four data workers do allocate
  unique chunks and reach READY before that shim-specific stall. Native RHEL/sqlite3 validation is
  mandatory.

## Required native/physical gates before deployment

1. Full `test/run_all_tests.sh` with native sqlite3.
2. `test/run_single_run_parallel.sh` PASS with native sqlite3.
3. Same-run producer benchmark on `supekgate04fl`: workers=1,2,4.
4. Strict source-change failure test under parallel production.
5. Oversized single file split across interleaved global chunk numbers + exact restore.
6. QNAP free-space failure test and live `.enc.part` accounting.
7. Real tape pair-transition smoke.
8. Dual physical write + readback + adaptive positioning + CLOSED barrier + single-file restore.

The tarball is a review candidate, not an instruction to install while the current Review-31E7 tape run
is active.
