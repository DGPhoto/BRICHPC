# Review 30AA — stream-gate race and sparse-file batching

## Fixed: healthy streaming runs could abort in the QNAP window gate

`bric-stream-gate.sh` counted staged blobs with a GNU `find | wc | tr` pipeline while the tape daemon
concurrently removed verified `chunk_*.enc` files. With `set -o pipefail`, a directory entry disappearing
between `readdir(2)` and `stat(2)` could make `find` return 1. The gate then exited silently, the Go
chunker stopped reading stdin, and upstream GNU tar terminated with rc=141/SIGPIPE. The run was
correctly aborted by the existing failure path, but a healthy tape drain was misclassified as failure.

The gate now counts a Bash `nullglob` array and explicitly checks that the run directory still exists.
Concurrent receipt cleanup is normal and no longer an error.

## Fixed: mildly sparse ELF/library files destroyed tape throughput

GNU tar can mark files with small alignment holes as sparse. Review 30P preserved every sparse-marked
member as an independent GNU sparse TAR_PART. On real LTO hardware, each tiny member therefore became
a separate tape file with filemark, rewind/positioning and read-back verification overhead.

Review 30AA isolates a sparse file only when either:

- total holes are at least 64 MiB; or
- allocated bytes are at most 75% of logical size.

Otherwise the small holes are materialized and the member is aggregated into the normal TAR_PART
stream. Content, logical size, hashes and restore semantics remain exact; materially sparse files still
restore sparsely. Defaults can be overridden with `BRIC_SPARSE_MIN_HOLE_BYTES` and
`BRIC_SPARSE_MAX_ALLOCATED_PERCENT`.

## Compatibility

- No database migration.
- No on-tape format change.
- Existing verified backups remain readable.
- Aborted segments remain `ABANDONED` and their physical space remains honestly included in `used_tb`.
