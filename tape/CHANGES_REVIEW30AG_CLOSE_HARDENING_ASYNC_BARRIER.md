# Review 30AG — deterministic close-hardening async barrier

## Scope

Test-only reliability fix. No production datapath changes.

## Problem

`test/run_close_hardening.sh` drove a real asynchronous tape-daemon loop but used fixed sleeps between
fixture mutations. In the signed-missing-artifact case it waited five seconds, asserted only that
`run.CLOSED` was absent, then immediately restored the missing artifact. Under host load the daemon
could consume `run.CLOSE_CATALOGS` only after that restore. The safety property still held (the run
was not sealed), but the expected `REQUIRED artifact MISSING` diagnostic had never been generated,
producing an intermittent false failure.

This exact signature was observed on Review 30AF: 56/57 tests passed; the only failure was
`run_close_hardening.sh` reporting `no missing-artifact log`, while the same test had passed in the
preceding 30AE native-sqlite run.

## Fix

`run_close_hardening.sh` now uses explicit asynchronous barriers:

- wait for `run.CLOSE_PLACEMENT` instead of sleeping after daemon start;
- wait for the daemon's unsigned-marker refusal before removing the unsigned marker;
- wait for `REQUIRED artifact MISSING` before restoring the missing fixture;
- wait for the signed-manifest SHA mismatch diagnostic before repairing that fixture;
- wait for `run.CLOSED` in the successful close case.

Each wait has a bounded timeout and also fails if the daemon exits, so a genuinely stuck or dead
daemon still fails the test.

## Compatibility

- database migration: none
- bus protocol: unchanged
- on-tape format: `BRIC-FORMAT-V1` unchanged
- production cluster/tape code: unchanged from Review 30AF
