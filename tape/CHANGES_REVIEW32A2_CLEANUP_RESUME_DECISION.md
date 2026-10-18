# BRIC Archive 2.0 — Review 32A2 cleanup fix and resume architecture decision

Date: 2026-09-09
State: candidate / review only
Base: Review 32A performance-parallel candidate, itself based on Review 31E7
On-tape format: BRIC-FORMAT-V1 unchanged

## 1. Native-suite bug reported by Claude: fixed

Claude reproduced a deterministic failure after all parallel data chunks and the serialized metadata chunk had been published:

```
parallel producer: starting serialized metadata worker at chunk 4
stream chunk 4 READY (...)
bric-stream-parallel-produce.sh: line 197: .../status.metadata: No such file or directory
```

Root cause: `bric-stream-parallel-produce.sh` installed a global `trap cleanup EXIT` whose cleanup removed the shared `$TMP` directory. Backgrounded shell functions inherit/execute the EXIT trap in their subshell. A data worker that exited before the coordinator reached the metadata phase could therefore remove the coordinator's shared status directory.

Fix:

- record the coordinator `BASHPID` before any worker is forked;
- only the coordinator is allowed to remove shared `$TMP` state;
- worker/subshell EXIT traps return without touching shared state;
- on a non-zero coordinator exit, stale `chunks.state='ALLOCATED'` placeholders for that run are deleted before outer run-abort handling proceeds.

This specifically addresses the native failure signature reported by Claude. In the compatibility test environment the parallel test now reaches and publishes the serialized metadata chunk without the `status.metadata` ENOENT failure; native sqlite3 rerun is still required for certification.

## 2. QNAP throughput apparent contradiction: resolved

There is no contradiction between:

- brictape's QNAP link being 1 GbE and `nfsiostat` measuring ~113 MiB/s physical NFS reads; and
- two tape `dd` processes each advancing around 80–110 MiB/s.

Both `dd` processes read the same `chunk_*.enc`. Linux page cache coalesces this workload: the ciphertext is fetched from QNAP once and the same cached pages are supplied to both readers.

Direct evidence from real run PPCG_ONT__20260908T115257Z__0015:

- each tape writer had logically consumed ~822 GB (`rchar`/`wchar`);
- their `read_bytes` values were approximately 330 GB and 492 GB, summing to ~822 GB rather than ~1.64 TB;
- simultaneously `nfsiostat` on brictape showed ~115,953 KiB/s (~113 MiB/s) total NFS READ, ~4.09 ms RTT, ~0 queue, zero retransmissions.

Therefore the 1 GbE link is genuinely saturated, but it can still feed both tape copies at roughly the same per-copy rate because the two copies consume identical cached data. Do not double the two `dd` rates to infer physical QNAP bandwidth.

## 3. Resume decision: never de-terminalize an ABORTED run

Review 31C+ terminal fencing remains mandatory. A run that publishes `run.ABORTED` must never re-enter the data path.

There is a second reason same-run resume is invalid in the current implementation: tape-side `handle_abort()` deliberately marks **all segments of the aborted run, including VERIFIED segments, as ABANDONED** and releases the reservation. Therefore `files + chunks.DONE` from an aborted run cannot be treated as retained archive progress.

Review 32 must not implement "resume the same run" and must not merely subtract DONE paths from an ABORTED run.

## 4. Preferred checkpoint architecture: logical operation + CLOSED slice runs

The user accepts internal multi-run orchestration provided the UX remains one command / one project / one logical backup.

Preferred architecture:

```
logical operation (user-visible)
  manifest: exact deterministic source scope, persisted once
  |
  +-- slice 001 -> child run A -> CLOSED
  +-- slice 002 -> child run B -> CLOSED
  +-- slice 003 -> child run C -> FAILED/ABORTED -> retry as new run_id
  |                                      |
  |                                      +-> old failed run remains terminal and its tape segments abandoned
  +-- slice 003 retry -> child run D -> CLOSED
  +-- ...
  +-- final operation state -> CLOSED only when every slice has a CLOSED child
```

Each child run is a genuine independently sealed BRIC run and therefore a durable checkpoint. If a child fails, only that slice is re-read/re-written. Previously CLOSED slices remain referenced and valid on tape.

This design intentionally preserves the existing one-active-run-per-project rule if slices are executed sequentially. Throughput within each child is supplied by the new internal parallel producer (benchmark 1/2/4 workers); no concurrent child runs or tape-daemon rewrite is required for the first implementation.

## 5. Required operation state

Additive cluster-side state should include at least:

- `operations`: operation_id, project, owner, source, status, source policy, manifest hash, total files/bytes, slice target, timestamps;
- `operation_slices`: operation_id, slice number, byte/file counts, status, current/closed child run_id, attempt count;
- `runs.operation_id` + `runs.operation_slice` (or an equivalent mapping table).

The exact NUL-safe source manifest must be persisted before the first reservation. Child runs consume immutable slice manifests derived from it; they must not rescan/repartition the whole 70 TB scope on every retry.

## 6. User-visible catalog semantics

Raw child runs are implementation detail by default.

- `bric status PROJECT`: show logical operation progress and optionally child detail in `--long`.
- `bric contents PROJECT`: union the CLOSED child runs of the latest CLOSED operation, with one logical path namespace.
- `bric find`: resolve paths across CLOSED operations/children without requiring run_id knowledge.
- `bric restore --file X`: resolve X to the child run that owns it.
- whole-operation restore: stage the required chunks across all CLOSED child runs and restore a single logical tree.

An explicit `--run` remains an operator/debug escape hatch for a physical child run.

## 7. Slice sizing

Do not hard-code a final slice size until measuring close overhead and real verify throughput. Candidate range for the urgent 70 TB campaign: 2–4 TB per durable slice.

Tradeoff:

- smaller slices = less rework after failure, more close/catalog/filemark overhead;
- larger slices = better amortization, larger failure domain.

Internal tar-stream worker chunk size remains a separate performance parameter.

## 8. Deadline / tape ceiling

62 MB/s is only the mathematical minimum, not a design target. Current hardware measurements imply the tape cycle is likely the limiting stage once producer throughput exceeds roughly 70 MB/s logical. The exact ceiling must use the real 0015 write + positioning + full readback timings, not assumed drive specifications.

The 1 GbE QNAP link is a hard physical limit for unique ciphertext fetch (~113 MiB/s), but shared page cache means PRIMARY and BACKUP writes of the same chunk can both run near that rate in parallel.

## 9. Gates before the 70 TB campaign

1. Full native 65-test suite after this cleanup fix.
2. Real 1/2/4-worker source benchmark; choose the smallest worker count that saturates downstream capacity.
3. Measure complete 0015 tape cycle including adaptive positioning and full readback.
4. Preflight QNAP free-space gate (already implemented in 32A candidate).
5. Preflight tape capacity for the entire logical operation.
6. Physical smoke forcing at least one tape-pair transition before the 70 TB campaign.
7. Implement and test CLOSED-slice operation resume before declaring the urgent campaign safe.
