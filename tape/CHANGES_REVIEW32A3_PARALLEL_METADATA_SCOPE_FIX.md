# Review 32A3 — parallel metadata worker scope fix

## Native failure

Review 32A and 32A2 reproducibly failed after the serialized metadata worker had already published its chunk:

```
stream chunk N READY (...)
bric-stream-parallel-produce.sh: ... status.metadata: No such file or directory
```

The 32A2 BASHPID cleanup guard did not change the signature.

## Root cause

The workspace was **not** being removed before the read. The actual bug was Bash dynamic scope / assignment expansion in `run_worker()`.

32A2 used one compound declaration:

```bash
local id="$1" ... ws="$RUNSTATE/workers/$id" ... status="$TMP/status.$id"
```

For a single `local` builtin Bash expands the RHS expressions before the newly assigned local `id` is available. At top level the preceding data-worker launch loop left a global `id=data-03`. Therefore the synchronous call:

```bash
run_worker metadata ...
```

created local `id=metadata`, but `ws`, `terr`, `result`, and `status` were expanded using the caller/global `id=data-03`.

Observed consequence in the diagnostic run:

- metadata chunks were published with manifests under `workers/data-03/`;
- `result.data-03` contained the metadata worker result;
- `status.data-03` was overwritten with `0|0|metadata`;
- `status.metadata` never existed;
- the subsequent `read < "$TMP/status.metadata"` failed;
- only then did the coordinator EXIT cleanup remove `$TMP`.

This explains why the cleanup hypothesis looked plausible from the final filesystem state but the BASHPID guard could never fix it.

## Fix

Split `run_worker()` initialization into two stages:

```bash
local id="$1" list="$2" label="$3" mode="..." chunk_start="..."
local ws="$RUNSTATE/workers/$id"
local terr="$TMP/tar.$id.err"
local result="$TMP/result.$id"
local status="$TMP/status.$id"
```

The top-level launch loop also uses `worker_id` rather than the generic global `id`, removing the accidental dynamic-scope value that made the defect deterministic.

No data-path, tape-format, crypto, allocator, capacity-gate, or terminal-fence semantics change in 32A3.

## Performance conclusion retained

The current estimated full tape-cycle ceiling with ~245 GB worker chunks and mandatory readback verification is about 68.6 MB/s logical. The serial producer measured ~44 MB/s, so it remains below the tape ceiling. Long-run throughput is approximately:

```
min(producer aggregate throughput, tape write+position+verify throughput)
```

Therefore the parallel producer remains necessary. Two efficient workers may already exceed the tape ceiling; benchmark 1/2/4 only after the native suite is green.

## Resume architecture retained as next phase

Do not de-terminalize `run.ABORTED`. Current abort handling marks all segments for the run `ABANDONED`, including VERIFIED ones. Durable campaign progress therefore needs CLOSED child-run slices belonging to one logical user operation. Candidate slice size remains ~2 TB, but this is not implemented in 32A3.
