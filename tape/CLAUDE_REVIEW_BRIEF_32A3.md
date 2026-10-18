# BRIC Archive 2.0 Review 32A3 — Claude native review brief

This is a deliberately narrow candidate based directly on 32A2.

## Root cause found

The `status.metadata` failure was not a premature `rm -rf`.

`run_worker()` had this pattern:

```bash
local id="$1" ... ws="$RUNSTATE/workers/$id" ... status="$TMP/status.$id"
```

Bash expands the RHS values of that `local` builtin before the new local `id` exists. The caller had a global `id=data-03` left by the worker-launch loop. So the metadata invocation used:

```
local id=metadata
ws=.../workers/data-03
result=.../result.data-03
status=.../status.data-03
```

The diagnostic evidence was exact:

```
status.data-03 => 0|0|metadata
result.data-03 => metadata worker counters
metadata chunk manifest => workers/data-03/chunk_....files.sql
status.metadata => absent
```

The EXIT cleanup ran only after the missing-file error, so the 32A2 BASHPID guard was addressing the consequence rather than the cause.

## 32A3 code change

1. `id/list/label/mode/chunk_start` are declared first.
2. `ws/terr/result/status` are declared in subsequent `local` statements, after local `id` is visible.
3. The top-level launch loop now uses `worker_id`, not global `id`.

No other 32A2 producer/tape architecture is intentionally changed.

## Gate requested

Please run first:

```bash
test/run_single_run_parallel.sh
```

With native sqlite3 3.45.1, verify specifically that:

- metadata publishes under `workers/metadata`, not `workers/data-03`;
- `status.metadata` is created and consumed;
- data-03 status/result are not overwritten;
- restore remains exact;
- no ALLOCATED rows remain.

Then run the full native suite and compare against the seven 32A2 failures.

## Performance correction

A serial producer at ~44 MB/s is still below the ~68.6 MB/s estimated tape-cycle ceiling, so the producer parallelism remains on the critical path. The likely steady-state requirement is only enough producer concurrency to stay above the tape ceiling; benchmark 1/2/4 after the suite is green.

## Network conclusion

`brictape:/mnt/data` already uses the dedicated 1 GbE QNAP path (`192.168.1.3:/Public`) and measured physical NFS throughput is ~113 MiB/s. The two tape writers share page cache, so their logical per-copy throughput must not be summed as physical QNAP traffic. No NFS tuning is expected to increase the 1 GbE ceiling.

## Resume

Still documentation-only in 32A3: preserve the terminal fence and use CLOSED child-run slices as durable checkpoints. Do not reuse chunks from an ABORTED run because abort handling marks its segments ABANDONED.
