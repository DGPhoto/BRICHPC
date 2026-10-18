# BRIC Archive 2.0 — Review 31D

> **SUPERSEDED BY REVIEW 31D1.** This file records the rejected pre-release 31D candidate. Its rc 21
> media-health policy is historical and must not be deployed. See `CHANGES_REVIEW31D1_SHORT_STREAM_MEDIA_HEALTH.md`.

## Scope

Review 31D is a runtime hardening release derived from Review 31C1. It changes tape-side verification
and common structured logging. It does **not** change `BRIC-FORMAT-V1`, database schema, ciphertext,
chunk framing, bus markers, restore format, key handling or project/tape exclusivity semantics.

## Real-hardware trigger

Dense run `smoke_real1__20260907T082604Z__0011` produced a 54,904,509,472-byte encrypted chunk and
wrote it concurrently to `000001L9#388` and `000002L9#387`. Immediate positioning succeeded on both
copies (`eod` file-number verification followed by `bsfm 2`). Review 31C1 then read each tape file into
`mktemp` on `/tmp`, which resides on the 70 GB root XFS filesystem.

The NFS fallback event log recorded:

- BACKUP: `TAPE_STREAM_READ_FAIL`, ENOSPC after 33,101,971,456 bytes.
- PRIMARY: `TAPE_STREAM_READ_FAIL`, ENOSPC after 31,258,050,560 bytes.
- Combined temporary payload: 64,360,022,016 bytes, matching the measured available local space to
  within less than 1 MB.

The subsequent SHA mismatches were hashes of truncated local files, not evidence of bad tape media.
Review 31C1 nevertheless incremented `write_errors` and set both media to `SUSPECT`.

## Root cause

Two independent defects combined:

1. Post-write verification materialized the full tape file before hashing. With a 980 GB target and two
   drives this implied a worst-case scratch requirement near 1.96 TB, despite no such requirement in
   configuration or preflight.
2. The daemon loop called `one_pass || log ...`. Bash ignores `errexit` through the dynamic function
   call tree of commands used in `||` conditions. `die` correctly terminated the inner real-tape read
   subshell, but the outer `write_copy` received non-zero from `tape_read_file_immediate` and continued
   because that status was not checked explicitly.

## Runtime changes

### Streaming verification

New tape I/O APIs stream directly to stdout and preserve existing positioning semantics:

- `tape_stream_file_immediate` — immediate `eod -> bsfm 2`, verified landing, absolute fallback.
- `tape_stream_file` — absolute `rewind + fsf` for arbitrary/reverify reads.
- `tape_verify_file_immediate` / `tape_verify_file` — pipe the stream through `tee` to a FIFO-backed
  `wc -c` counter and `sha256sum`. Only control-size temporary files are used.

Verification return classes:

- `0`: exact byte count and SHA-256.
- `20`: transport/local verification failure.
- `21`: completed stream but byte count differs from expected size.
- `22`: exact expected byte count but SHA-256 differs.

Historical/rejected 31D policy: `20/21` accounted the physical append without changing media health,
while `22` penalized media. Review 31D1 corrects this: rc 21 and rc 22 both penalize media; rc 20 alone
preserves media telemetry. All capacity/state changes remain transactional and conditional on the
segment still being `WRITTEN`, preventing double accounting.

Close artifacts and TOCs use the same streaming immediate verifier. Periodic reverify is also
streaming. The original 31D candidate preserved media health for rc 21; Review 31D1 supersedes that
policy and treats a clean size mismatch as media/read-path evidence.

### Errexit containment

Loop-mode `one_pass` is no longer invoked as the left operand of `||`. Each pass runs as an
asynchronous child outside an errexit-suppressing conditional; the parent waits for it, imports only a
tiny progress flag, records `DAEMON_PASS_FAILED` on non-zero status, and continues. The pass child
closes inherited singleton descriptors but retains generation/work fences.

Verification correctness nevertheless does not depend on `set -e`: all verification return codes are
handled explicitly.

### Logging

- Structured event paths recompute their UTC day for every event while keeping a stable per-process
  event-log stem. Long-running daemons therefore rotate naturally across `events/YYYY-MM-DD`.
- Structured primary-log failure emits `LOG_FAILOVER` directly on the fallback plus a stderr warning
  (visible to journald under systemd). The triggering event is already persisted on fallback before
  the breadcrumb is emitted.
- Raw stdout/stderr logs remain process-lifetime files and retain their existing runtime failover.

## Regression coverage

New/extended tests cover:

- exact streaming verify with control-only scratch;
- transport/local failure -> rc 20;
- short stream -> rc 21;
- exact-size corruption -> rc 22;
- absence of segment-sized immediate-readback tempfile patterns;
- no `one_pass ||` errexit-suppression call site;
- real-backend mock streaming verification while retaining `bsfm 2` / absolute fallback behavior;
- end-to-end daemon attribution: local/transport verify failure accounts physical bytes without media
  penalty, while exact-size hash corruption still marks media `SUSPECT`;
- event-date rotation across a simulated midnight/day change;
- structured-only primary -> fallback transition with durable `LOG_FAILOVER`.

## Deployment note

Do not retry the dense real-tape workload on Review 31C1: each attempt appends another orphan physical
copy before failing. Deploy 31D, run the native full suite, then repeat the existing-project APPEND on
scratch media. Correct the 31C1 incident's media telemetry only after reviewing older independent error
history (`000001L9` had no pre-0011 write error; `000002L9` had one pre-existing write error whose cause
must be preserved unless independently explained).
