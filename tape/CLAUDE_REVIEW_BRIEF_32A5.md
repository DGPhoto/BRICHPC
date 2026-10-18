# Claude review brief — BRIC Review 32A5

Please review 32A5 as a test-contract-only correction on top of 32A4. No production data-path code is intentionally changed.

## Native failure being corrected

After the 32A4 worker-target cap fixed `raw/huge.bam`, standalone `run_local_e2e.sh` reached CLOSED and then failed:

    FAIL: project catalog built expected=1 got=0

The old assertion searched QNAP for `*/close/catalog_project.enc` after CLOSED.

## Why that assertion is stale

Production close explicitly calls `bus_cleanup_run_dir(..., CLOSED)` after the signed CLOSED receipt has been verified and the cluster catalog has committed CLOSED. Unless `BRIC_KEEP_TERMINAL_BUS=1` is set, the complete terminal run directory is then removed from QNAP.

The durable close catalog is tracked on tape in `tape_artifacts`:

    filename='catalog_project.enc'
    kind='CATALOG'
    state='VERIFIED'

The final tape TOC is likewise tracked as `kind='TOC'`.

The tape daemon's close scope is every tape belonging to the project (`SELECT DISTINCT volumetag FROM segments WHERE project_name=...`), not merely the volumes used by the current child run.

## Harness inconsistency also fixed

`run_all_tests.sh` exports `BRIC_KEEP_TERMINAL_BUS=1`, while a standalone `KEEP=1 run_local_e2e.sh` only preserves the test workroot and does not retain the terminal bus. Thus the same assertion could pass in the full suite and fail standalone.

32A5 makes `run_local_e2e.sh` explicitly set `BRIC_KEEP_TERMINAL_BUS=0`, so this gate always exercises production terminal cleanup semantics.

## New assertions

After CLOSED, verify:

1. one VERIFIED `catalog_project.enc` row per project tape in `tape_artifacts`;
2. one VERIFIED `TAPE_TOC.txt` row per project tape;
3. the QNAP run directory is absent.

Please inspect the exact SQL and confirm it matches the daemon's close scope/barrier.

## Clarification on restore evidence

Do not infer DR correctness solely from ordinary `bric restore`: normal restore can still use the cluster catalog for path/chunk resolution. The dedicated DR/rebuild tests remain the correct proof that the encrypted on-tape project catalog is independently usable.

## Requested native gate

Run first:

    test/run_local_e2e.sh

Expected new lines include:

    ok: project catalog VERIFIED on every project tape (...)
    ok: final TOC VERIFIED on every project tape (...)
    ok: terminal QNAP run directory cleaned (0)

Then run:

    test/run_dr_e2e.sh
    test/run_parallel_target_policy.sh
    test/run_single_run_parallel.sh
    test/run_all_tests.sh

If anything fails, preserve the workroot plus:

    SELECT run_id,volumetag,filename,kind,file_number,state
    FROM tape_artifacts
    WHERE run_id='<RUN>'
    ORDER BY volumetag,file_number;

and:

    SELECT DISTINCT project_name,volumetag
    FROM segments
    WHERE project_name='<PROJECT>'
    ORDER BY volumetag;

## Unchanged next-phase requirements

- physical smoke forcing at least one tape-pair transition before the large campaign;
- CLOSED child-run slices under one logical operation as durable checkpoints;
- do not reopen ABORTED runs.
