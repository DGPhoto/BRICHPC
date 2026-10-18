# Review 30R — execution diagnostics and robust systemd launch

- `bric-setup.sh` no longer discards the first `bric-tar-stream --version` error.
- The original execution diagnostic is retained across the optional static Go rebuild.
- If rebuilding fails, setup reports both the original helper failure and the Go build failure, so architecture, loader, `noexec`, policy and permission faults are not conflated.
- The local static rebuild fallback for RHEL 8 remains intact.
- The tape systemd unit launches the Bash daemon explicitly through `/bin/bash`, avoiding direct-script `execve()` failures caused by filesystem or execution policy while still syntax-checking the script before startup.
- Setup now waits briefly and verifies that `bric-tape-daemon.service` remains active; it no longer prints “started” after an immediate service failure.
- No catalog, tape-format, encryption-format, sparse-format or restore-format changes.
