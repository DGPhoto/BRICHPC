# Review 30S — production-environment isolation for the test suite

## Root cause

`run_all_tests.sh` claimed that every included test was hermetic, but it only supplied private log
paths.  It did not remove BRIC variables already exported by the calling shell.  Because runtime
configuration deliberately follows `environment > config file > defaults`, a tape host exporting
`BRIC_ROLE=tape`, real bus-signing keys, `BRIC_REQUIRE_SIGNING=1`, catalog paths or backend settings
silently overrode the temporary test configuration even when a test set `BRIC_CONFIG=none`.

The result was a broad cascade rather than independent regressions: cluster commands failed the role
gate, simulated markers were checked with production public keys, and reservation/close/crash tests
timed out after their temporary daemons refused those markers.

## Fix

The suite runner now enumerates all exported variables whose names begin with `BRIC_` or `_BRIC_`,
removes them from each child test environment using `env -u`, and then adds back only:

- `BRIC_CONFIG=none`;
- the test-private primary and fallback log directories;
- `BRIC_REQUIRE_LOGGING=1`.

`BRIC_TEST_LOGDIR` is consumed by the runner before sanitisation, so callers can still choose the
suite log directory without exposing it or any production setting to child tests.

The runner reports only the number of removed variables, never their values; key paths and other
sensitive configuration therefore do not appear in suite output.

## Regression proof

Launching the runner with deliberately poisoned values such as `BRIC_ROLE=tape`, production-style
signing settings and real-backend paths must still allow `run_host_roles.sh` to read the temporary
slurm/tape configuration files correctly.  Before this change that test deterministically reported
`slurm config produced role 'tape'`; after sanitisation it passes.
