# BRIC Archive 2.0 — Review 32A7 REAL-backend E2E timeout fix

Date: 2026-09-09
Base: Review 32A6
Scope: test harness only; no production behavior, schema, crypto, tape format or data path change.

## Failure observed

The first full native 32A6 suite completed 67/68 tests. `run_real_e2e.sh` was the sole failure.
The REAL-backend mock successfully wrote and read back all seven chunks to both PRIMARY and BACKUP,
then the run was aborted at the drain/close boundary. A diagnostic rerun and three consecutive original
reruns all passed archive + close + DR.

## Root cause

`run_real_e2e.sh` set `BRIC_DRAIN_TIMEOUT=120` seconds. The fixture deliberately uses one mocked drive
for both copies and serializes write, immediate readback, eject/load and role switching for every chunk.
With seven chunks its normal drain phase is already approximately 120 seconds. Under full-suite host load,
the final DONE receipt can race the 120-second finalize timeout: the daemon can finish chunk 7 just as the
cluster-side finalizer decides the drain timed out and publishes ABORTED.

The first failure signature and the later 4/4 successful REAL-backend runs are consistent with this boundary race.

## Fix

Increase only the test fixture timeout:

    BRIC_DRAIN_TIMEOUT=120 -> 300

300 seconds keeps the test bounded while providing >2x headroom over observed normal drain time. Production
`bric-finalize.sh` behavior and its default drain timeout are unchanged.

## Gate

1. `test/run_real_e2e.sh`
2. full `test/run_all_tests.sh`

Expected full-suite result: 68/68 PASS.
