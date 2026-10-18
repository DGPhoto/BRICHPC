# BRIC Archive 2.0 — Review 32B2: progressive restore test contract

Date: 2026-09-10
Base: Review 32B1
Scope: test-only correction; no production runtime change.

## Why 32B2 exists

Review 32B1 introduced the progressive restore path and its dedicated test `test/run_restore_progressive.sh`.
Claude's independent run showed 11/12 assertions passing, including the substantive runtime guarantees:

- whole-run restore exactness;
- `restore-progressive-v1` request protocol;
- terminal signed progress state `DONE`;
- per-chunk `READY -> CONSUMED` acknowledgement for every chunk;
- no staged ciphertext remaining after consumption;
- per-chunk progress visible on the cluster side;
- legacy second-pass QNAP `sha256sum` removed.

The only failure was the assertion for `inline_sha256=yes`. The runtime emits that token through `bric_event`, i.e. the structured event log, while the test searched `daemon.log`, which contains only the human-readable message `sha256 verified inline`.

This was therefore a test-contract bug, not a restore-runtime defect.

## Change

`test/run_restore_progressive.sh` now:

1. uses private temporary structured-log roots under the test `$ROOT`, making the assertion hermetic;
2. searches the structured event tree for `inline_sha256=yes` instead of searching daemon stdout/stderr.

No files under `cluster/` or `tape/` are changed from Review 32B1.

## Expected native gate

On `supekgate04fl`:

```bash
sudo KEEP=1 ./test/run_restore_progressive.sh
sudo ./test/run_all_tests.sh
```

Expected:

```text
✓ PROGRESSIVE RESTORE CHECKS PASSED
== 70 OK, 0 FAIL ==
✓ SUITE PASSED — software environment validated.
```

The physical multi-pair LTO smoke remains a separate mandatory gate after the native suite is green.
