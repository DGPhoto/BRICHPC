# Review 31E3 — direct test hermeticity

31E3 is a test-safety follow-up to 31E2. Production runtime behavior is unchanged.

## Trigger

A direct invocation of `test/run_setup_e2e.sh` from an administrator shell that already had
production `BRIC_*` variables exported created a `realproj` PLANNING row in the production cluster
catalog. The full `run_all_tests.sh` runner already sanitized inherited `BRIC_*` / `_BRIC_*`
variables before every test, so the 31E2 64/64 full-suite result remains valid. The individual E2E
script, however, incorrectly relied on being launched only through the runner despite claiming to be
hermetic.

## Fix

`test/run_setup_e2e.sh` now clears every inherited `BRIC_*` and `_BRIC_*` variable before it creates
its private config and workroot. It then assigns private test logging roots under that workroot.
Therefore environment precedence (`environment > config`) cannot redirect the direct test into a
production catalog, QNAP bus, key tree, or logging tree.

## Runtime delta

None. Cluster/tape runtime, on-tape format, streaming verifier, positioning, media-health policy,
central user logging, and the FD lifecycle fix are byte-identical to 31E2 except for release metadata.
