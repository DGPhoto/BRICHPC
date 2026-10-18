# Review 31B — PAX sparse semantics and source consistency

Build date: 2026-09-04  
Release: `2.0-review31B`  
On-tape format: **BRIC-FORMAT-V1 unchanged**

## Why this review exists

Real smoke `smoke_real1__20260903T230837Z__0008` proved that Review 31A's sparse batching works
(729 members collapsed into one V1 TAR_PART), but exposed two independent source-side issues:

1. sparse classification used `st_blocks`, which is storage accounting rather than an extent map on
   Dell PowerScale/OneFS over NFSv3; and
2. GNU tar completed the stream with rc=1 because the live Python environment changed while it was read.

A controlled 1 GiB sparse-file experiment on the same NFSv3 export also proved that client
`SEEK_HOLE(0)` returns EOF even for a file known by construction to contain almost 1 GiB of holes.
Neither `st_blocks` nor client `SEEK_HOLE` can therefore be treated as authoritative source topology.

## Sparse classification: GNU PAX map, not filesystem accounting

The outer producer already runs GNU tar with:

```
--format=pax --sparse --sparse-version=0.1
```

For a member GNU tar represents sparsely, the PAX header contains `GNU.sparse.map`. Review 31B parses
that map and computes:

- mapped data bytes = sum of sparse-map data extents;
- represented holes = logical size - mapped data bytes.

The existing materiality policy is then applied to those values. `st_blocks` is no longer referenced by
`bric-tar-stream` for sparse classification or batch estimation. `run_source_scan.allocated_bytes` remains
an advisory preflight storage-accounting metric only.

This also fixes the 31A batch-size distortion in which a batch estimated at ~2.89 GB from `st_blocks`
produced ~4.41 GB of ciphertext. Review 31B estimates sparse batch payload from the PAX mapped data bytes
plus conservative per-member tar metadata overhead. The default target remains 4 GiB.

## Sparse drift verification without a third source read

31A read a preserved sparse member three times:

1. authoritative outer tar walk;
2. GNU tar sparse-batch emission;
3. `hashSourceFile()` drift verification.

31B removes read #3. GNU tar batch stdout is passed through an `io.TeeReader`: raw tar bytes go directly
to the existing encryption writer while Go's tar reader hashes the logical content of those exact same
members. Each generated member must match the outer-walk name, logical size and SHA-256. A mismatch aborts
before the chunk is published. No plaintext batch file is staged.

## Source-change policy

The new config key is:

```
source_change_policy = strict
```

`strict` remains the default. `bric backup ... --source-change-policy record` is an explicit local/tar-stream
opt-in for live trees.

The outer tar runs with `LC_ALL=C` and `--quoting-style=escape`. After a successful chunker pass:

- tar rc=0: normal clean run;
- tar rc=1 + every non-empty diagnostic exactly matches `file changed as we read it`:
  - `strict`: diagnostics are recorded locally and the run aborts;
  - `record`: the captured bytes may close and every diagnostic is cataloged;
- tar rc=1 with any other warning: fatal;
- tar rc>=2: fatal;
- chunker rc!=0: fatal regardless of tar rc.

There is deliberately no `--ignore-failed-read` and no generic `|| true`.

## New additive catalog tables

`run_source_semantics` records per run:

- `sparse_map_method = gnu-pax-0.1-map`;
- `allocation_topology = not-guaranteed`;
- `source_change_policy`;
- `source_consistency`;
- `source_changed_count`;
- GNU tar exit code.

`run_source_changes` records each accepted/detected `FILE_CHANGED_DURING_READ` diagnostic. Paths are stored
using GNU tar's escape-quoted diagnostic representation (`path_encoding=gnu-tar-escape`) so diagnostics
remain line-safe without unsafe shell re-evaluation.

Both tables are copied into `catalog_project.enc` and therefore survive normal restore/DR. New command:

```
bric source-changes PROJECT [--run RUN_ID]
```

`bric status` also shows `source_consistency` when the new schema is present.

## Compatibility

Unchanged:

- `BRIC-FORMAT-V1`;
- encryption / HMAC parameters;
- tape marker protocol;
- tape daemon and physical positioning logic;
- chunk placement model;
- restore and DR data path;
- 4 GiB sparse batch default;
- source readability preflight and explicit exclusions.

Database migration is additive/lazy only.

## Deferred work

This review intentionally does **not** optimize immediate LTO readback positioning. The real smoke showed
large rewind/FSF positioning latency at file numbers ~378/379; that touches physical tape semantics and
will be handled separately after a dedicated hardware test.


### Allocation-effect clarification (31B1 follow-up)

The possible topology mismatch has an explicit direction: when source extent topology is unavailable, GNU tar may represent physically allocated zero byte ranges sparsely. A restored file can therefore contain holes where the source had preallocated zero blocks. Bytes are unchanged; allocation intent is not guaranteed. Review 31B1 records this as `restore_allocation_effect=zero-ranges-may-restore-as-holes`.
