# Review 31A — conservative sparse-batch default

Review 31A is a narrow follow-up to Review 31. It does not change `BRIC-FORMAT-V1`, the catalog schema,
restore/DR semantics, tape-daemon behavior, crypto, read-back verification, or exclusion/source-integrity
logic.

## Why the default changes

A materially sparse source member is observed through three source reads in the current V1-safe batching
path:

1. the authoritative outer GNU tar stream reads it;
2. GNU tar reads it again when `flushSparseBatch` emits the multi-member sparse `TAR_PART`;
3. `hashSourceFile` reads it again and compares the final SHA-256/size with the authoritative outer-walk
   value before the chunk is committed.

The third read is intentional fail-closed drift detection, but the batching target determines how long a
queued member can remain exposed to source mutation before reads 2/3 occur. A 64 GiB default is too
aggressive for a live shared HPC tree: it maximizes amortization of tape filemarks but also increases the
mutation window and the amount of work lost if a queued source file changes.

## New default

`sparse_batch_target_bytes` and all built-in fallbacks are now **4294967296 bytes (4 GiB)**. The value
remains configurable through `BRIC_SPARSE_BATCH_TARGET_BYTES` or the catalog setting. Tests may continue
to use smaller explicit targets.

4 GiB is deliberately conservative: it removes the pathological one-sparse-member/one-tape-file behavior
while keeping the source-drift window and restart cost far below a 64 GiB batch. Larger values can be
raised later from measured production drift/throughput data without another format change.

## Compatibility

- database migration: none beyond Review 31 additive lazy tables
- on-tape format: `BRIC-FORMAT-V1` unchanged
- restore/DR: unchanged
- tape daemon: unchanged
- bus protocol/crypto/read-back: unchanged
