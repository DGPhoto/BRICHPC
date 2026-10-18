# Review 32A — performance-first, single-run parallel producer

Review 32A is intentionally ordered around throughput. The immediate production requirement is about
70 TB in one project/run before 2026-09-21. Review 31E7's local producer is one GNU-tar stream and the
real `PPCG_ONT__20260908T115257Z__0015` run produced ~980 GB in ~6 h 08 min (~44 MiB/s class).
Independent parallel reads showed that the Isilon path can deliver far more aggregate bandwidth, while
`brictape` already saturates its current 1 GbE QNAP path at ~113 MiB/s. The release objective is therefore
to make ONE normal BRIC run exploit source/QNAP concurrency without changing BRIC-FORMAT-V1 or removing
full PRIMARY+BACKUP verification.

## 1. Four data workers inside one project/run

New cluster settings:

- `stream_parallel_workers=4`
- `stream_worker_chunk_bytes=245000000000` (~245 GB per worker)
- `max_concurrent_producers=1` (run-level admission, deliberately separate from internal workers)
- `tar_blocking_factor=8192` (4 MiB outer GNU-tar record)

`bric backup PROJECT SOURCE` remains one run and one user-visible operation. In local mode the producer:

1. performs the existing source integrity preflight before reservation;
2. creates a cluster-local, NUL-safe manifest of the exact included source scope;
3. assigns each regular file to exactly one worker with online greedy balancing by logical bytes;
4. launches up to four GNU-tar -> `bric-tar-stream` pipelines concurrently under the same `run_id`;
5. emits directories/symlinks once, after all data workers, so directory metadata remains globally last.

No content hash pre-pass was added. Each file's plaintext SHA-256 is still calculated by the tar-aware Go
helper while that worker consumes the actual tar stream. Parallelism therefore does not intentionally
double source data reads. Existing sparse-map handling and `LARGE_FILE_CHUNK` logic remain in the helper.

Why ~245 GB per worker: leaving 980 GB as the per-worker target would make four workers each wait for
~980 GB before publishing their first READY. 245 GB × 4 keeps roughly the previous aggregate chunk scale
while reducing per-worker first-READY latency and keeping tape/filemark counts moderate.

## 2. Global atomic chunk namespace for concurrent workers

`cluster/scripts/bric-stream-allocate.sh` is new. Before a parallel worker opens a new chunk it obtains a
per-run `flock`, computes required reservation from:

- ciphertext bytes already published for the run;
- one full target budget for every currently `ALLOCATED` worker chunk;
- one target for the new chunk;
- 5% framing margin;

then calls the existing stream gate (which can extend tape reservation) and finally reserves
`MAX(chunk_no)+1` in SQLite under `BEGIN IMMEDIATE`, state `ALLOCATED`.

The Go helper accepts `--allocate`. `bric-stream-publish.sh` converts the placeholder atomically to
`PRODUCED` and then READY. `runs.n_chunks` and `runs.total_bytes` are derived from authoritative catalog
rows instead of worker-local cumulative counters.

This is the key invariant: all workers publish into one project/run and one contiguous global chunk
namespace; there are no synthetic sub-runs.

Directory/symlink metadata is serialized after data workers and uses `--chunk-start MAX(chunk_no)+1`
rather than the concurrent allocator. That guarantees metadata chunk numbers are globally last.

## 3. Source consistency with parallel tar streams

Each worker gets its own tar stderr/result/runstate. After all data workers finish, Review 32A combines
GNU-tar diagnostics and classifies them once with the existing `bric-source-consistency.sh` policy:

- strict: any safely-classified `file changed as we read it` -> run abort;
- record: diagnostics are catalogued as before;
- tar rc>=2 or unclassified warnings remain fatal.

The source must still be operationally quiescent/snapshotted for true whole-run consistency, exactly as
with the previous long one-pass stream. Review 32A does not claim filesystem snapshot semantics.

## 4. Parallel progress

Workers write independent private progress files under `RUNSTATE/workers/*`. A low-frequency coordinator
aggregates them into the ordinary run progress file. The watcher is independent of worker PID polling so
an exited zombie cannot keep the coordinator alive.

## 5. Adaptive immediate tape verify positioning

The Review 31E7 immediate verify path always used `eod -> bsfm 2`. Physical measurements showed reverse
movement around 210 MB/s, rewind about 46 s and forward filemark spacing about 0.4 s/filemark. Review 32A
selects the cheaper of:

- relative `eod + bsfm 2`;
- absolute `rewind + fsf`.

Tunables:

- `BRIC_TAPE_VERIFY_POSITION_MODE=adaptive|relative|absolute`
- `BRIC_TAPE_BSFM_BYTES_PER_SEC=210000000`
- `BRIC_TAPE_REWIND_MILLISECONDS=46000`
- `BRIC_TAPE_FSF_MILLISECONDS_PER_FILE=400`

The chosen method and estimates are logged. Restore/reverify arbitrary positioning remains absolute.

## 6. QNAP staging reads decoupled from the fixed tape record

The physical tape record remains `BRIC_TAPE_BLOCK=262144` and is not changed. The write path now uses:

    dd if=<chunk> of=<nst> iflag=fullblock ibs=4194304 obs=262144

so QNAP reads may use 4 MiB application buffers while tape writes remain 256 KiB records. On current
`brictape` hardware the QNAP path is physically 1 GbE and already measured at ~113 MiB/s, so this is a
clean implementation improvement rather than a claim of >1 GbE throughput.

## 7. Outer tar record = 4 MiB, with EOF-padding fix

The outer GNU-tar streams feeding `bric-tar-stream` use blocking-factor 8192 (4 MiB). During development,
large tar record padding exposed a real SIGPIPE regression: the Go tar reader saw the logical two-zero-
block EOF and exited while GNU tar was still flushing zero-filled record padding. The helper now drains
all trailing outer-record bytes to pipe EOF and rejects any non-zero trailing data. Existing tar/sparse
regressions pass with this behavior.

Large record tuning is NOT propagated to directly-stored legacy planned/slurm tar streams.

## Explicit non-changes

- one active run per project remains;
- PRIMARY and BACKUP still require full write + readback SHA-256 verification;
- `BRIC_TAPE_BLOCK=262144` unchanged;
- BRIC-FORMAT-V1 unchanged;
- no NFS `nconnect`, readahead or SUNRPC tuning baked in;
- no second QNAP physical link assumed;
- no security/signer refactor in this performance subrelease.

## Validation status

Completed in the build environment:

- Go helper compiles and reports `BRIC tar-stream 32A-parallel`;
- `bash -n` passes for all modified operational shell scripts;
- `test/run_tar_stream.sh` passes, including ordinary TAR_PART, oversized files, sparse batching,
  single-file extraction and sparse allocation restoration;
- standalone metadata tar -> helper path completes correctly with `--chunk-start`;
- existing targeted tape performance tests from the preceding 32A work cover 4 MiB staging reads and
  adaptive positioning.

A new `test/run_single_run_parallel.sh` exercises four same-run workers, global allocation and restore.
In this ChatGPT container the real `sqlite3` CLI is unavailable; a Python compatibility shim is used.
The data workers successfully allocate/publish concurrent chunks, but the shim can stall on the later
metadata catalog transaction. This is an environment limitation and the release remains
`build_state=candidate`: Claude/native RHEL validation MUST run the complete suite with real sqlite3
before production deployment.

## Production gate

Do NOT install while Review 31E7 run `PPCG_ONT__20260908T115257Z__0015` or any tape write is active.
After it is terminal:

1. install/update 32A on a quiescent cluster+tape system;
2. run the full native test suite with real sqlite3;
3. run a controlled local benchmark with one project/run and `stream_parallel_workers=1,2,4`;
4. measure aggregate Isilon->QNAP producer MiB/s and CPU;
5. keep the smallest worker count that saturates the useful path without destabilizing OneFS/QNAP;
6. confirm tape write, adaptive verify, catalog close, single-file restore and tape-only DR.

## 8. Review-follow-up: QNAP space is now a pre-reservation invariant

Parallel production creates a second class of staged object that Review 31 did not have to account for:
`chunk_*.enc.part`. With four workers, up to four large partial ciphertext files may be growing while the
ordinary sliding window still contains published `chunk_*.enc` files. Review 32A therefore changes the
physical occupancy probe to count BOTH `.enc` and `.enc.part` files.

Before `bric-stream-plan` requests any tape reservation, parallel local mode now computes a conservative
free-space requirement:

    slots = max_inflight_chunks + stream_parallel_workers
    window = slots * stream_worker_chunk_bytes
    required = min(source_logical_bytes, window) * 1.05

and compares it with `df -B1` free bytes on `BRIC_QNAP_MNT`. Failure is fatal before reservation. With the
current candidate defaults (8 published + 4 in-progress, 245 GB worker target), a large operation requires
about 3.09 TB currently free, not 7.8 TB. The latter figure would apply only if every parallel worker used
the legacy 980 GB target.

`test/run_qnap_parallel_capacity.sh` verifies that `.enc.part` is counted, checksum sidecars are not, the
small-capacity case passes, and an over-capacity case fails closed.

## 9. Important unresolved item: crash resume/checkpoint semantics

This candidate is deliberately NOT claiming Review-32 production readiness for a 70 TB archive yet.
Parallel workers make already-published chunks independent, but the local coordinator still treats a
worker/coordinator failure as failure of the run and follows the existing `run.ABORTED` path. The worker
assignment manifests are temporary and are not yet a durable restart contract.

Claude's review correctly points out that an 8-12 day operation must not lose all useful work because the
producer process or host dies late in the run. There are two defensible next designs:

A. **single-run durable manifest/resume** (preferred if it can be made simple): persist the NUL-safe source
   manifest and slice assignments in runstate/catalog, make each slice idempotent, and on restart subtract
   paths/slices already represented by successfully published/verified chunks;

B. **internal run-group orchestration**: split the logical operation into hidden child runs with retry,
   expose one user operation/project in `status/contents/find/restore`, and explicitly accept that the
   children are separate source snapshots.

Review 32A currently implements neither. This is a P0 review question, not a cosmetic future feature.

## 10. Existing BRIC architecture relevant to the design choice

BRIC 31E7 already has a different same-run parallel architecture in Slurm planner mode: `bric-plan.sh`
creates explicit per-chunk member lists and `archive_array.sbatch` runs `bric-chunk.sh` concurrently inside
one `run_id`, with Slurm requeue/idempotent chunk states. That path is a useful precedent for checkpointing,
but it does not yet carry all of the Review-31 local tar-stream semantics: the current implementation
pre-hashes files in a separate source read and lacks the same sparse/exclusion behavior. The 32A candidate
therefore parallelizes the proven tar-stream path instead of switching production to the older planner
path. Claude should explicitly review whether converging these two paths is safer than extending the new
local coordinator with durable resume.

## 11. Throughput target and worker count are benchmark outcomes

The candidate default remains four workers because the immediate objective is to find the saturation
point, not to encode 62 MB/s as a design target. However, the physical 1 GbE QNAP->brictape path already
measures ~113 MiB/s and mandatory full readback verification lowers the effective write+verify cycle.
Two source workers may therefore be sufficient in production. Native acceptance MUST benchmark 1, 2 and
4 workers and keep the smallest count that saturates the useful end-to-end path.

## Review 32A2 native-suite correction (2026-09-09)

Claude's native sqlite3 run exposed an inherited EXIT-trap race in the parallel coordinator: a background data worker could remove the shared temp directory before the serialized metadata worker wrote `status.metadata`. Review 32A2 guards cleanup with coordinator `BASHPID` and removes only orphan `ALLOCATED` placeholders on coordinator failure.

Resume design was also tightened: same-run resume remains forbidden, and aborted-run DONE chunks cannot be retained because tape-side abort marks all run segments ABANDONED. Durable recovery must therefore checkpoint at CLOSED child-run boundaries under a user-visible logical operation. See `CHANGES_REVIEW32A2_CLEANUP_RESUME_DECISION.md`.
