# Review 30AE — resilient QNAP budget probe and test progress

## Problem

Review 30AD fixed the expected `readdir(2)`/`stat(2)` ENOENT race in the global QNAP budget scan with
GNU `find -ignore_readdir_race`, but any other non-zero probe result was still promoted immediately to
a producer failure under `set -euo pipefail`. A transient NFS error (ESTALE/EIO/ETIMEDOUT) could
therefore abort a healthy append-only tape run after substantial data had already been written.
Additionally, `qnap_inflight_bytes()` discarded `find` stderr, making genuine probe failures opaque.

A separate operational issue was found while validating 30AD: the full cross-role test suite had been
run from a role-filtered `/opt/bric2` installation on the SLURM host. That installed tree intentionally
does not contain the complete tape role, so tests produced misleading cross-role failures. The runner
also provided no `[n/N]` progress indicator.

## Changes

- `qnap_inflight_bytes()` keeps `-ignore_readdir_race` for the expected concurrent deletion race, but
  no longer redirects stderr to `/dev/null`; real GNU find/NFS diagnostics reach the job log.
- `bric-stream-gate.sh` treats the global budget probe as tri-state:
  1. known below budget -> proceed;
  2. known at/above budget -> wait;
  3. unknown because the probe failed -> wait, warn, retry.
- Unknown occupancy remains fail-closed: the producer stages no additional ciphertext while the probe
  is failing.
- Persistent probe failure aborts only after a consecutive-failure threshold. Default: 12 attempts
  (about 60 s with the default 5 s poll). The threshold may be set by
  `BRIC_QNAP_PROBE_MAX_FAILURES` or config key `qnap_probe_max_failures`; environment wins.
- A successful probe resets the consecutive-failure counter.
- The legacy `bric-chunk.sh` sliding-window path uses the same bounded-retry behavior.
- `run_stream_gate_race.sh` now verifies:
  - per-run Bash-glob counting survives concurrent deletion;
  - global scan uses `-ignore_readdir_race`;
  - transient genuine probe failures pause/retry and preserve stderr;
  - persistent failures abort only at the configured threshold;
  - the legacy producer keeps the same policy.
- `run_all_tests.sh` now precomputes the selected test set and prints `[n/N] RUN` plus `[n/N] PASS/FAIL`.
- The full suite now refuses to run from an incomplete/role-filtered tree when `MANIFEST.sha256` does
  not verify, with an explicit instruction to run from a complete extracted release tarball.

## Compatibility

- Database migration: none.
- Bus protocol: unchanged.
- On-tape format: `BRIC-FORMAT-V1` unchanged.
- Existing 30AC/30AD catalogs, keys, tape assignments, and media remain compatible.
