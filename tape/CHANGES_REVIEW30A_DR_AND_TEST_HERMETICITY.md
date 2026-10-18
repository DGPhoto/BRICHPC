# CHANGES — Review 30A: DR logging independence and hermetic dual-drive tests

## Correctness fix: disaster recovery cannot depend on logging

Review 30 called `bric_log_process_start`/`bric_log_process_end` from
`bric-dr-from-tapes.sh` without defining them. The DR script therefore aborted before scanning tapes.

Review 30A ships a standalone `cluster/scripts/lib_logging.sh` containing only the logging subsystem.
The DR script loads it when present with `BRIC_REQUIRE_LOGGING=0`; if the library is absent, logging
functions degrade to no-ops. Recovery remains runnable from tapes + key + the DR script bundle, while
installed environments still receive structured logs whenever a destination is writable.

## Dual-drive setup test

Production remains fail-closed and dual-drive by default (`BRIC_TAPE_DRIVES="0 1"`,
`BRIC_PARALLEL_DRIVES=2`). There is no automatic degradation to one drive: that would violate the
site requirement that both copies complete before DONE/CLOSED.

`run_setup_e2e.sh` previously created a hermetic config without the two drive entries while setup
stored `parallel_drives=2`. The test now explicitly provisions two simulated drives.

## Hermetic logs in tests

`run_all_tests.sh` gives every test private primary/fallback log directories beneath the suite log
root. Direct VTL and parallel-drive tests do the same. Tests no longer write `/var/log/bric` or depend
on system/NFS permissions. The VTL drive-count assertion now prints the actual inventory and stored `ndrives` value on failure.

## Regression test

`run_dr_logging_independence.sh` copies the DR script and tape abstraction without the standalone
logger and verifies that unwritable log destinations do not stop recovery startup.
