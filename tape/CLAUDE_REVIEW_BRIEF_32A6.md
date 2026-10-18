# Claude review brief — BRIC Review 32A6

Please review 32A6 as a packaging/portability correction on top of 32A5.

## Native failure

On RHEL8 `supekgate04fl`, all four parallel workers failed before producing chunks because the packaged helper required newer glibc symbols:

    GLIBC_2.34 not found
    GLIBC_2.32 not found

The run then correctly transitioned to ABORTED.

## Confirmed package defect

The Review-32A5 helper was dynamically linked and had `NEEDED libc.so.6`. This violates the Review-30Q contract that the shipped helper is static Linux amd64.

32A6 rebuilds the **unchanged** `bric-tar-stream.go` with:

    CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags='-s -w'

Expected inspection:

    file cluster/libexec/bric-tar-stream
    # ... statically linked ...

    readelf -d cluster/libexec/bric-tar-stream | grep NEEDED
    # no output

## Test cleanup

`run_helper_portability.sh` has a dynamic-ELF rejection check, but its earlier version probe was stale and required the string `31`, so Review 32A exited before reaching the useful dependency diagnostic. That is now changed to require only the `BRIC tar-stream ` prefix. Review-specific helper version remains checked elsewhere (`run_performance_policy.sh`).

## No functional source change

No Go source, producer, allocator, catalog, close, restore, tape daemon, SQL, crypto, or tape-format behavior changed from 32A5.

## Requested native gate

Run first:

    test/run_helper_portability.sh
    KEEP=1 test/run_local_e2e.sh

If local_e2e passes, continue with DR, the two parallel gates, then the full suite.

The 32A5 CLOSED-catalog assertions remain unchanged and are still the next semantic gate after helper portability.
