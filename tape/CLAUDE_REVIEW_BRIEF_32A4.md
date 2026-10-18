# Claude review brief — BRIC Review 32A4

Please review 32A4 as a minimal correction on top of the confirmed 32A3 metadata-scope fix.

## What your 32A3 `run_local_e2e` failure actually exposed

You reported:

    FAIL: raw/huge.bam mismatch

The failing block in `run_local_e2e.sh` already orders LARGE_FILE_CHUNK rows by `chunk_index`, so I traced whether the file was actually represented as LARGE_FILE_CHUNK.

It was not.

32A3 logs show:

    aggregate_target=5242880
    worker_target=245000000000

The e2e test intentionally changes legacy `segment_target_bytes` to 5 MiB, but the new Review-32A `stream_worker_chunk_bytes=245 GB` silently overrode it. A 12 MiB `huge.bam` therefore went into TAR_PART. The manual LARGE reconstruction selected zero `big_rel_path` rows and compared an empty output with the source. That explains why later normal whole-run restore assertions could still pass.

So this was not evidence of chunk_index corruption, although it did reveal a real configuration regression.

## 32A4 change

The legacy segment target is now always a hard upper bound:

    effective_worker_target = min(configured_worker_target, segment_target_bytes)

Fresh production defaults remain exactly the same:

    segment_target_bytes=980000000000
    stream_parallel_workers=4
    stream_worker_chunk_bytes=245000000000
    => effective 245 GB

But a test/site that sets `segment_target_bytes=5242880` gets an effective 5 MiB worker target even if the 245 GB default remains in the config table.

0/auto continues to mean `segment_target_bytes / workers` if explicitly selected.

## New evidence against an interleaving corruption bug

`run_single_run_parallel.sh` now contains a 25 MB oversized file and a 10 MB worker target. It creates three LARGE_FILE_CHUNK pieces while other workers allocate/publish global chunk numbers concurrently, then reconstructs by `chunk_index`.

Local result:

    chunk 5 LARGE 10,000,032 ciphertext bytes
    chunk 6 LARGE 10,000,032 ciphertext bytes
    chunk 7 LARGE 5,000,032 ciphertext bytes
    PASS ... global namespace contiguous restore=exact

Please still inspect the catalog rows in your native run, but this makes a producer/restore ordering defect much less likely.

## Requested native gate, in order

1. `test/run_parallel_target_policy.sh`
2. `test/run_single_run_parallel.sh`
3. `test/run_local_e2e.sh`
   - confirm `raw/huge.bam` has >1 `LARGE_FILE_CHUNK` row;
   - confirm `chunk_index` is 1..N and offsets are monotonic;
   - confirm the manual split restore passes;
   - confirm scripted single-file and whole-run restore pass.
4. Continue/full rerun of `test/run_all_tests.sh`.

If `run_local_e2e` still fails, please preserve these rows before cleanup:

    SELECT chunk_no,type,big_rel_path,chunk_index,total_chunks,offset_bytes,size_bytes,state
    FROM chunks
    WHERE run_id='<RUN>'
    ORDER BY chunk_no;

and for huge.bam:

    SELECT chunk_no,chunk_index,total_chunks,offset_bytes,size_bytes
    FROM chunks
    WHERE run_id='<RUN>' AND big_rel_path='raw/huge.bam'
    ORDER BY chunk_index;

## Performance reasoning unchanged

The producer remains P0 because steady-state throughput is `min(producer, tape-cycle)`. A serial producer around 44 MB/s cannot feed a tape-cycle around 68.6 MB/s. Benchmark 1/2/4 workers only after the native suite is green; use the minimum worker count that stays safely above the measured tape-cycle.

## Resume architecture unchanged

Do not reopen ABORTED runs. Durable checkpoints should be CLOSED child runs/slices under one logical operation. ~2 TB remains the current candidate failure domain. This is not implemented in 32A4.
