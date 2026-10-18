# BRIC Archive 2.0 — Review 32A4
## Parallel worker target cap / LARGE_FILE_CHUNK regression fix

Date: 2026-09-09
State: candidate
On-tape format: BRIC-FORMAT-V1 unchanged

## Trigger

Native Review 32A3 validation reported `run_local_e2e.sh`:

    FAIL: raw/huge.bam mismatch

The first hypothesis was that globally interleaved chunk numbers caused LARGE_FILE_CHUNK pieces to be restored in `chunk_no` order rather than `chunk_index` order.

That hypothesis does not explain this particular failure: the failing manual reconstruction in `run_local_e2e.sh` already queries:

    SELECT chunk_no ... WHERE big_rel_path='raw/huge.bam' ORDER BY chunk_index;

## Root cause

Review 32A introduced a production default:

    stream_worker_chunk_bytes=245000000000

but `bric-stream-backup.sh` allowed that new setting to exceed the pre-existing `segment_target_bytes` setting.

`run_local_e2e.sh` deliberately lowers `segment_target_bytes` to 5 MiB to force a 12 MiB `huge.bam` through the LARGE_FILE_CHUNK path. Under 32A3 the runtime log instead showed:

    aggregate_target=5242880
    worker_target=245000000000

so `huge.bam` was smaller than the effective 245 GB worker target and was packed into a normal TAR_PART. The direct LARGE_FILE_CHUNK check then selected zero rows from `chunks.big_rel_path`, concatenated nothing, and compared an empty reconstruction with the source. The later normal whole-run restore remained correct because the file was present in TAR_PART.

This was a false corruption signal, but it exposed a real configuration regression: the new parallel-specific setting could silently defeat an explicit lower legacy chunk target.

## Fix

`segment_target_bytes` is restored as a hard upper bound for every worker chunk.

Resolution rule:

    effective_worker_target = min(stream_worker_chunk_bytes, segment_target_bytes)

For an absent/0/`auto` worker target, the fallback remains:

    segment_target_bytes / stream_parallel_workers

Production defaults therefore remain unchanged:

    segment_target_bytes       = 980000000000
    stream_parallel_workers    = 4
    stream_worker_chunk_bytes  = 245000000000
    effective worker target    = 245000000000

Reduced-target tests and explicit site tuning now work again:

    segment_target_bytes       = 5242880
    stream_worker_chunk_bytes  = 245000000000
    effective worker target    = 5242880

No database migration is required beyond the existing Review-32A performance config rows.

## Additional regression coverage

### test/run_parallel_target_policy.sh

New focused test validates:

- 980 GB / production 245 GB target remains 245 GB;
- 2 workers do not silently change an explicit 245 GB target;
- a reduced 5 MiB segment target clamps the 245 GB worker target to 5 MiB;
- `0`/`auto` derives target/workers;
- smaller explicit worker overrides remain valid;
- malformed overrides fail closed.

### test/run_single_run_parallel.sh

The parallel coordinator test now includes a 25 MB oversized regular file with a 10 MB worker target. It therefore creates three LARGE_FILE_CHUNK pieces while other workers publish into the same global chunk allocator. The test reconstructs the file strictly by `chunk_index` and requires byte-for-byte equality.

Observed locally:

    stream chunk 5 READY (10000032 bytes)
    stream chunk 6 READY (10000032 bytes)
    stream chunk 7 READY (5000032 bytes)
    ...
    PASS single-run parallel producer: workers=4 chunks=9 global namespace contiguous restore=exact

This demonstrates that LARGE_FILE_CHUNK data and chunk_index metadata remain correct under global interleaving in the tested path.

## Validation performed in ChatGPT container

PASS:

- `test/run_parallel_target_policy.sh`
- strengthened `test/run_single_run_parallel.sh` (with LARGE_FILE_CHUNK interleaving)
- `test/run_performance_policy.sh`
- `test/run_tar_stream.sh`
- `test/run_stream_verify.sh`
- `test/run_filemark_semantics.sh`
- `bash -n` on modified shell scripts

The local container does not have the authoritative native sqlite3 environment used by Claude, so full-suite status is intentionally not claimed here.

## Required native gate

Before production or Review-32B work:

1. `test/run_local_e2e.sh` must PASS with native sqlite3 and specifically show a real LARGE_FILE_CHUNK split for `raw/huge.bam`.
2. `test/run_single_run_parallel.sh` must PASS with native sqlite3.
3. `test/run_parallel_target_policy.sh` must PASS.
4. Full `test/run_all_tests.sh` must be rerun.
5. Existing environment-only failures, if any, must be classified separately and not silently waived.

## Not changed

- BRIC-FORMAT-V1.
- encryption/HMAC parameters.
- dual PRIMARY/BACKUP write and full readback verification.
- terminal run fence.
- chunk allocator.
- restore implementation.
- Review-32A3 metadata-worker scope fix.
- resume/slice orchestration (still future Review 32B work).
