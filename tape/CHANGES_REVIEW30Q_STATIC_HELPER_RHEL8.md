# Review 30Q — portable tar-stream helper for RHEL 8

- Rebuilt `cluster/libexec/bric-tar-stream` with `CGO_ENABLED=0`.
- The shipped helper is now a static Linux amd64 executable and does not require glibc 2.34.
- Fixes setup failure on RHEL 8 hosts such as `supekgate04fl` (kernel architecture x86-64, older glibc).
- `bric-setup.sh` now distinguishes architecture from loader/libc incompatibility.
- If the bundled helper ever cannot execute and `go` is installed, setup recompiles it locally as a static binary from `bric-tar-stream.go` and validates `--version` before continuing.
- No catalog, tape-format, encryption-format, sparse-format, or systemd changes from Review 30P.
