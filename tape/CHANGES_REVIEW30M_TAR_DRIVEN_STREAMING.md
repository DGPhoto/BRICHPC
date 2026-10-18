# Review 30M — tar-driven one-pass streaming

## Motive

The Review 30L local path still performed a complete per-file planning walk before GNU tar read the
same tree again. On NFS trees with roughly one million small files, the first pass remained dominated
by metadata round trips and Bash per-entry work even after SQLite batching. The catalog also described
a pre-scan rather than exactly what tar eventually archived.

Review 30M removes the separate per-file planning pass from `BRIC_RUN_MODE=local`. GNU tar is the
authoritative inventory and the source tree is traversed once for the actual backup stream.

## New local pipeline

```text
source tree
  -> GNU tar (PAX stream)
  -> cluster/libexec/bric-tar-stream
       -> independent TAR_PART chunks at tar-member boundaries
       -> raw LARGE_FILE_CHUNK pieces for one file larger than the target
       -> plaintext SHA-256 and exact file catalog while bytes are read
       -> OpenSSL-compatible AES-256-CBC/PBKDF2 encryption
  -> signed QNAP READY markers
  -> tape daemon writes PRIMARY and BACKUP copies
```

The user command is unchanged:

```bash
bric backup PROJECT /source/path
```

Background execution, PID capture, `bric jobs`, `bric log`, `bric cancel`, and `--wait` remain as in
Review 30L.

## Static stream helper

Added:

- `cluster/libexec/bric-tar-stream`
- `cluster/libexec/bric-tar-stream.go`

The shipped binary is static Linux x86-64. The matching Go source is included for review and
reproducible rebuilding. Setup verifies that the helper is executable and can answer `--version`.

The helper:

- parses the incoming tar stream rather than rescanning the filesystem;
- normalizes paths and rejects absolute or parent-traversal members;
- closes every `TAR_PART` as a valid independent tar archive;
- stores files larger than `segment_target_bytes` as ordered `LARGE_FILE_CHUNK` records;
- calculates plaintext SHA-256 during the only data read;
- writes chunk/file catalog rows in transactional batches through the publish helper;
- computes ciphertext SHA-256 and HMAC-SHA256;
- writes ciphertext in the historical `Salted__` OpenSSL format using AES-256-CBC,
  PBKDF2-HMAC-SHA256, 10,000 iterations, and PKCS#7 padding;
- defers directory headers until final metadata chunks, deepest directories first, so restrictive
  modes never prevent unprivileged reconstruction of later large-file pieces;
- skips unsupported special tar members with explicit warnings;
- fails closed on GNU sparse PAX records rather than silently expanding sparse files.

## Streaming reservation protocol

A one-pass stream does not know the final byte count before reading the source. Added:

- `cluster/scripts/bric-stream-plan.sh`
- `cluster/scripts/bric-stream-gate.sh`
- `cluster/scripts/bric-stream-publish.sh`
- `cluster/scripts/bric-reserve-extend.sh`
- `cluster/scripts/bric-stream-backup.sh`

The cluster requests an initial signed logical capacity. Before a chunk may be published beyond that
capacity, it sends a signed `run.RESERVE_EXTEND_REQUEST` containing the absolute required byte count.
The tape daemon either:

- adds the minimum number of complete onsite EMPTY pairs and returns signed `run.RESERVE_EXTENDED`
  with the new logical capacity; or
- returns signed `run.RESERVE_EXTEND_DENIED` and no unreserved chunk is published.

The tape server calculates current-run logical bytes once per chunk, not once per PRIMARY/BACKUP copy.
Project-scoped media rules from Review 30E remain in force.

## Catalog and recovery correctness

- The catalog now describes entries actually consumed from the tar stream.
- `bric status` reports progress during `RESERVED`, `PRODUCING`, `DRAINING`, and `CLOSING` as well as
  `PLANNING`.
- Filename-safe SHA-256 parsing was added for GNU `sha256sum` output whose leading backslash marker is
  used when names contain newlines.
- Whole-project, single-file, and disaster recovery understand both `TAR_PART` and
  `LARGE_FILE_CHUNK`.
- Directory metadata is restored after file content, preserving read-only directory modes without
  blocking unprivileged DR.
- Legacy tapes containing `catalog_system.enc` remain readable.
- The on-tape format identifier remains `BRIC-FORMAT-V1`; crypto parameters remain pinned and
  compatible with previous OpenSSL-generated blobs.

## Notifications and lifecycle

The streaming path emits the same user-visible lifecycle events as the legacy planner:

- `BACKUP_START` after initial reservation is granted;
- `BACKUP_DENIED` with the tape-server reason;
- `BACKUP_FAILED` and signed `run.ABORTED` on an interrupted stream;
- `BACKUP_DONE` only after both tape copies, close artifacts, TOCs, and media-release barriers finish.

The global producer slot still limits simultaneous plaintext producers. A run transitions from
`RESERVED` to `PRODUCING`, then releases the producer slot when it enters `DRAINING`.

## Compatibility and deployment

- The new tar-driven path is used in `BRIC_RUN_MODE=local` on supekgate.
- The existing Slurm path remains available temporarily and still uses the legacy planner until a
  shared QNAP/catalog-controller design is deployed on compute nodes.
- Both cluster and tape-server software must be upgraded together because the reservation response
  now carries `capacity_bytes` and the tape daemon handles signed extension requests.
- The tape catalog must not be reset during this software upgrade. It contains physical media,
  placement, and append history.
- `bric-reset-catalog.sh --yes` resets only cluster operational state and preserves configuration,
  users, and authenticated key escrow; it also refuses while either the legacy or tar-stream pipeline
  is active.

## Test changes

Added:

- `test/run_tar_stream.sh`
- `test/run_stream_reservation.sh`

Updated tests cover:

- OpenSSL decryption compatibility of stream-generated ciphertext;
- independent tar chunks and large-file reassembly;
- initial and extended project-scoped capacity;
- interruption/abort cleanup;
- background lifecycle;
- crash-safe close and recovery;
- names containing spaces and newlines;
- symlinks, empty directories, restrictive modes, and skipped special files;
- unprivileged DR and single-file DR;
- notification parity and producer-slot exclusion.
