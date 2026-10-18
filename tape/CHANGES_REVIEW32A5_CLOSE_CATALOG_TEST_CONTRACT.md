# BRIC Archive 2.0 — Review 32A5
## CLOSED catalog durability test-contract correction

Date: 2026-09-09
State: candidate
Base: Review 32A4
On-tape format: BRIC-FORMAT-V1 unchanged
Production data path: unchanged

## Trigger

After the Review-32A4 LARGE_FILE_CHUNK fix, native `test/run_local_e2e.sh` progressed through:

    all chunks DONE
    segments verified
    run CLOSED
    project_tapes populated
    QNAP blobs freed

and then failed:

    FAIL: project catalog built expected=1 got=0

The failing assertion searched the QNAP bus for:

    */close/catalog_project.enc

*after* the run had reached CLOSED.

## Root cause

The assertion was stale relative to the terminal-bus contract.

`bric-close.sh` waits for the signed `run.CLOSED` receipt, records the cluster run CLOSED, and then calls:

    bus_cleanup_run_dir "$PROJECT" "$RUN_ID" CLOSED

`bus_cleanup_run_dir()` removes the entire terminal run directory unless the operator debugging escape hatch `BRIC_KEEP_TERMINAL_BUS=1` is set.

Therefore absence of `close/catalog_project.enc` from QNAP after CLOSED is expected production behavior. The QNAP is a transport bus, not durable archival storage.

The durable close artifacts are recorded in the tape catalog table `tape_artifacts`, not `segments`. The tape daemon requires every signed close artifact to be VERIFIED on every tape belonging to the project, then writes/verifies a final TOC, before it can publish CLOSED.

## Test fix

`test/run_local_e2e.sh` now explicitly sets:

    BRIC_KEEP_TERMINAL_BUS=0

so it exercises production cleanup semantics even when invoked by `run_all_tests.sh`, which currently exports the debugging retention flag for the suite harness.

The stale QNAP assertion was replaced by three checks:

1. `catalog_project.enc` is `CATALOG` + `VERIFIED` in `tape_artifacts` once per project tape;
2. `TAPE_TOC.txt` is `TOC` + `VERIFIED` once per project tape;
3. the terminal QNAP run directory no longer exists.

The expected tape count is derived from the daemon's actual close scope:

    SELECT COUNT(DISTINCT volumetag)
    FROM segments
    WHERE project_name='mouse_rnaseq';

This matches the daemon's close logic, which replicates signed close artifacts to every tape already belonging to the project.

## Important clarification

A successful ordinary `bric restore` is not, by itself, proof that `catalog_project.enc` can reconstruct the archive without the cluster catalog: ordinary restore still uses cluster catalog metadata to resolve logical paths/chunks.

The disaster-recovery invariant remains covered by the dedicated DR/rebuild tests. Review 32A5 only corrects the local-e2e close assertion; it does not change restore or DR implementation.

## No production change

Review 32A5 does not modify:

- chunk production or allocation;
- LARGE_FILE_CHUNK ordering;
- tape write/readback semantics;
- close artifact generation;
- tape artifact replication;
- CLOSED barrier semantics;
- crypto/on-tape format;
- database schema;
- resume/slice architecture.

## Required native gate

Run, in order:

1. `test/run_local_e2e.sh`
2. `test/run_dr_e2e.sh`
3. `test/run_parallel_target_policy.sh`
4. `test/run_single_run_parallel.sh`
5. full `test/run_all_tests.sh`

For `run_local_e2e.sh`, specifically require:

- `raw/huge.bam` split restore exact;
- project catalog VERIFIED on every project tape;
- final TOC VERIFIED on every project tape;
- terminal QNAP run directory cleaned;
- scripted single-file, split-file and whole-run restore exact.
