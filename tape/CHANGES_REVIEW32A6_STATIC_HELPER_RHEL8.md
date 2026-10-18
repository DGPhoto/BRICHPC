# BRIC Archive 2.0 — Review 32A6
## Restore static `bric-tar-stream` packaging contract for RHEL 8

Date: 2026-09-09
State: candidate
Base: Review 32A5
On-tape format: BRIC-FORMAT-V1 unchanged
Database migration: unchanged

## Trigger

The native Review-32A5 `run_local_e2e.sh` on `supekgate04fl` failed before chunk publication with:

    bric-tar-stream: /lib64/libc.so.6: version `GLIBC_2.34' not found
    bric-tar-stream: /lib64/libc.so.6: version `GLIBC_2.32' not found

All four parallel workers exited with chunker rc=1 and the run was correctly ABORTED.

## Root cause

The shipped `cluster/libexec/bric-tar-stream` binary in Review 32A5 was dynamically linked against the build host glibc even though the repository contract since Review 30Q requires a static Linux amd64 helper built with `CGO_ENABLED=0`.

Inspection of the 32A5 package showed:

    ELF 64-bit ... dynamically linked
    NEEDED libc.so.6
    GLIBC_2.32
    GLIBC_2.34

This is a packaging/build regression, not a Go source or archive-format defect.

The existing `test/run_helper_portability.sh` contains the correct dynamic-dependency check, but a stale earlier version assertion (`grep '31'`) exits first under Review 32A and masks that diagnostic. That version coupling is unrelated to portability and is removed here.

## 32A6 changes

1. Rebuilt `cluster/libexec/bric-tar-stream` from the unchanged Review-32A5 Go source using:

       CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags='-s -w'

2. `test/run_helper_portability.sh` now checks only that `--version` has the BRIC helper prefix; Review-specific version policy remains covered by the dedicated performance-policy test.

No producer logic, allocator logic, sparse handling, crypto, SQL, close, restore, tape daemon, or tape format code changed.

## Static validation

The rebuilt helper is:

    ELF 64-bit LSB executable, x86-64, statically linked

and has no ELF `NEEDED` dynamic-library entries.

## Required native gate

Run in this order on `supekgate04fl`:

1. `test/run_helper_portability.sh`
2. `test/run_local_e2e.sh`
3. `test/run_dr_e2e.sh`
4. `test/run_parallel_target_policy.sh`
5. `test/run_single_run_parallel.sh`
6. full `test/run_all_tests.sh`
