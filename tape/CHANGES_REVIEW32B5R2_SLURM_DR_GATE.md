# Review 32B5R2 — Slurm transport and DR gate closure

Date: 2026-10-07  
Base: Review 32B5R1  
Original baseline: Review 32B4A
`095878febc2f71f7f695aaf8976220470a0a445b63532685e6cc5378a4606ca4`

## Native-gate input

Independent review of 32B5R1 reported an effective 78/78 native result: the only
full-suite red item was `run_real_e2e.sh` killed by the runner's 300-second default,
and the same test passed standalone in 319 seconds. The reviewer also identified the
remaining Slurm restore CSV exposure (F2b), blanket `--export=ALL` hygiene regression
(N1), DR completion-summary honesty gap (N3), and the marginal test timeout (N2).

## B2 — baseline evidence closed

The exact 32B4A tarball is present and hashes to the declared baseline value above.
32B5R2 is compared directly against its extracted bytes. The protected producer files
and all `tape/**` files remain byte-identical; `BRIC-FORMAT-V1` is unchanged.

## F2b — Slurm restore transport closed

`BRIC_RESTORE_PROJECT`, `BRIC_RESTORE_DEST`, `BRIC_RESTORE_FILE` and optional
`BRIC_RESTORE_RUN_ID` no longer embed their values in Slurm's comma-delimited
`--export` string. Exact values travel in the `sbatch` process environment, while the
option contains variable names only. Restore destinations and relative file names may
therefore contain comma without truncation.

As an additional namespace hardening, `bric_validate_logical_root` now rejects comma.
This deliberately narrows the logical-root grammar: an archive root never needs comma,
and rejecting it prevents a write/read asymmetry from being reintroduced in any future
transport path. `=` remains allowed.

## N1 — environment hygiene restored

The login-node backup submission no longer uses `--export=ALL`. It constructs a
specific name allow-list and supplies the corresponding exact values with `env`.
The same names-only/value-via-env pattern is also applied to:

* login-node restore -> `restore.sbatch`;
* orchestrator -> archive array;
* orchestrator -> finalize/close.

Unrelated login-shell values (`LD_PRELOAD`, `OPENSSL_CONF`, `PYTHONPATH`, tokens, etc.)
are not requested for export to BRIC jobs. This again matches the policy already stated
inside `bric-orchestrate.sh`.

## N3 — DR verification summary

DR now counts and reports:

* `VERIFIED-DESTINATION`;
* `VERIFIED-STREAM`;
* `CHECKSUM-MISMATCH`.

If any recovered object is stream-only, DR emits an explicit line stating that the
destination was not independently re-read and that authenticated/decrypted recovery is
not proof of physical persistence. Single-file DR emits the same summary before its
completion line (and before a verification failure is raised).

This does not add directory/symlink type verification to DR; that remains outside this
corrective review.

## N2 — suite timeout

`test/run_all_tests.sh` now defaults to 600 seconds per test (and documents that value).
An explicit `--timeout` still overrides it.

## Tests

`run_32b5_schema_namespace.sh` now asserts comma roots are invalid.
`run_32b5_slurm_cli.sh` now asserts:

* comma root rejection;
* `=` root preservation;
* no blanket `ALL` export;
* names-only backup export;
* comma-containing restore destination and relative file transport;
* names-only restore export;
* downstream orchestrator array/finalize use the same pattern;
* `backup --wait` still uses the valid `requested_at` path.

`run_32b5_dr_verify_semantics.sh` now also asserts counters and the stream-only warning.

## Unchanged scope

Review 32B5A remains reserved for restore journal, temporary restrictive-directory
permission relaxation/rollback, ACL/xattr rollback, exact cross-chunk directory repair,
and `--require-destination-verify`. Those are not implemented here.

`build_state` remains `candidate` until this R2 is rerun through the native gate.
