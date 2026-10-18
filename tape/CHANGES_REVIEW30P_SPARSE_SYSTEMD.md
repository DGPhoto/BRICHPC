# Review 30P — sparse files and systemd tape daemon

## Sparse-file preservation

- The tar-driven local backup now accepts GNU/PAX sparse regular files.
- Sparse members are emitted as independent GNU sparse `TAR_PART` archives rather than being expanded into zero-filled payloads.
- GNU tar recreates the sparse layout during normal BRIC restore and written DR recovery.
- The streaming discovery pass remains authoritative; BRIC verifies the source checksum again after producing the sparse member and fails if it changed.
- The outer GNU tar invocation requests sparse format 0.1 for deterministic sparse-map detection.
- `run_tar_stream.sh` verifies content, logical size, and allocated-block preservation with a 1 GiB sparse fixture.

## systemd integration

- Added `tape/systemd/bric-tape-daemon.service`.
- `bric-setup.sh --role tape` installs, enables, and starts the service when systemd is active.
- Set `BRIC_SYSTEMD_AUTO_START=0` to install and enable without starting.
- Runtime lock moved from `/tmp/bric_tape.lock` to `/run/bric/bric-tape-daemon.lock`.
- The unit uses `RuntimeDirectory=bric`, waits for network/NFS, restarts on failure, logs to journald, and stops with SIGTERM.
- During upgrade, setup terminates a manually started daemon before handing ownership to systemd.
