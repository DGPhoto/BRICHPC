# BRIC Archive 2.0 — Review 31D1

## Scope

Review 31D1 supersedes the un-deployed Review 31D candidate. It keeps 31D streaming tape verification,
explicit verify return handling, daemon-pass errexit containment, event-day rotation and structured
log failover. It corrects one media-health regression found by the native `run_audit_health.sh` gate.
No on-tape format, database schema, crypto, bus, restore, key or exclusivity semantics change.

## Regression found in 31D

`run_audit_health.sh` truncates a previously VERIFIED simulated tape file to 1 MiB and runs periodic
`--verify`. The streaming pipeline completes successfully but produces fewer bytes than the catalogued
`size_bytes`, so `_tape_verify_stream` correctly returns rc 21. The first 31D candidate mapped rc 21 to
`operational_bad`, preserving `health=OK` and `read_errors=0`. That is a false negative for real media
degradation.

The key distinction is origin, not merely shape:

- rc 20: stream/transport/local machinery failed (non-zero pipeline component, control scratch/hash/count
  failure). This is not sufficient evidence against media.
- rc 21: the stream pipeline returned success, but a clean EOF/stream length differs from the expected
  byte count. With full-payload local scratch removed, this is tape/drive read-path evidence and must
  penalize media.
- rc 22: expected byte count was read but SHA-256 differs. This is media/data corruption evidence.

## Runtime policy

- Immediate segment verify rc 20: physical append is accounted and ABANDONED; no `write_errors`/health
  penalty.
- Immediate segment verify rc 21 or 22: physical append is accounted and ABANDONED; `write_errors` is
  incremented and non-BAD media becomes `SUSPECT`.
- Periodic `--verify` rc 21 or 22: `read_errors` is incremented and tape becomes `BAD`.
- Periodic transport/local rc 20: verification command fails, timestamp is recorded, existing media health
  is preserved.

## Regression coverage

`run_verify_failure_attribution.sh` now exercises three end-to-end cases: `io` -> health remains OK,
`short` -> both copies become SUSPECT with write errors, and `corrupt` -> both copies become SUSPECT
with write errors. Existing `run_audit_health.sh` remains the independent periodic reverify regression:
a clean truncated tape file must fail reverify, increment `read_errors`, and mark the tape BAD.

## Deployment

Do not install the original 31D tarball. Review 31D1 must pass the native full gate before deployment.
No additional real-tape write is required to validate this policy correction.
