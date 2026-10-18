# Review 30AH — sparse batching for LTO throughput

## Problem

Real LTO-9 smoke runs showed a fixed tens-of-seconds lifecycle cost for each tape file (pair prepare,
write/implicit filemark, read-back verification, signed DONE and polling). Review 30AA correctly stopped
materializing large sparse holes, but every materially sparse member was still emitted as its own raw
GNU sparse `TAR_PART`. In software environments containing many sparse-marked shared libraries this
created tiny ciphertext chunks ranging from KiB to a few MiB and reduced effective tape throughput by
orders of magnitude.

## Fix

`cluster/libexec/bric-tar-stream` now decouples sparse preservation from tape-chunk boundaries.

- The authoritative outer GNU tar walk still discovers each file and supplies the plaintext hash.
- Materially sparse members are consumed and hashed from that stream, but only their path/hash/metadata
  are queued in memory.
- A batch is flushed when its estimated sparse payload reaches the configured target, before an
  oversized raw file, or at EOF.
- One GNU tar process receives the queued paths through a NUL-delimited `--verbatim-files-from` list and
  emits one valid multi-member PAX/GNU-sparse tar stream directly into the existing encryption writer.
- No plaintext tar is staged on local disk or QNAP.
- Every sparse source is re-hashed after GNU tar has read the batch and compared with the authoritative
  outer-stream hash; source drift remains fail-closed.
- All members are recorded in the existing `files` catalog with the same `chunk_no` and distinct
  `member_index` values.

A `TAR_PART` was already defined by BRIC-FORMAT-V1 as an independent tar archive and normal TAR_PARTs
already contain many members. Therefore existing `decrypt | tar` full restore, `tar -- FILE` single-file
restore and disaster recovery read the new sparse batches without any reader change.

## Batch target

Default estimated sparse payload target: `68719476736` bytes (64 GiB). The estimate is allocated bytes
reported by `stat(2)` plus 64 KiB per member for PAX/sparse metadata. The estimate controls only when a
batch is flushed; actual ciphertext size remains authoritative for tape accounting. Override with
`BRIC_SPARSE_BATCH_TARGET_BYTES`; fresh catalogs also contain `sparse_batch_target_bytes`. Existing
catalogs require no migration because the producer has the same 64 GiB fallback.

The ordinary non-sparse `segment_target_bytes` remains 980,000,000,000 bytes.

## Tests

`test/run_tar_stream.sh` now proves:

1. two materially sparse files share one V1 TAR_PART;
2. full extraction preserves content, logical sizes and sparse allocation for both;
3. existing single-file extraction restores exactly one member from that same batched TAR_PART;
4. 100 sparse files collapse to 7 independent TAR_PART chunks with a 1 MiB test batch target rather
   than producing 100 tape chunks;
5. lightly sparse files still follow the 30AA normalization policy.

## Compatibility

- database migration: none
- bus protocol: unchanged
- restore/DR code: unchanged
- on-tape format: `BRIC-FORMAT-V1` unchanged
- encryption/HMAC: unchanged
