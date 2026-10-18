# CHANGES — Review 30B (NFS bus contract, OpenSSL fail-fast, asynchronous dual-drive timing)

Review 30B is a targeted correction on top of Review 30A. It does not change the archive format.

## NFS is the production bus

- Active documentation and code comments now describe the QNAP bus as NFS, not SMB/CIFS. Historical
  review notes remain unchanged as history.
- New role-config variables:
  - `BRIC_QNAP_MNT=/mnt/data`
  - `BRIC_REQUIRE_NFS_BUS=1`
- Backup, restore, every Slurm job, and the tape daemon fail closed when the declared bus mount is
  absent or is not NFS. This prevents a lost mount from silently turning `/mnt/data/bric` into an
  unrelated local directory on one host.
- The Slurm node healthcheck also drains a node when the QNAP mount is non-NFS.
- Hermetic tests/local sandboxes retain `BRIC_REQUIRE_NFS_BUS=0`.

## OpenSSL fail-fast restored

`cluster/bin/bric` again requires `openssl` in its dispatcher preflight. Slurm jobs still load the
pinned OpenSSL 3.5 module themselves; the dispatcher check preserves clear fail-fast behaviour in
local mode and restores the security regression test.

## Dual-drive timing semantics clarified

PRIMARY and BACKUP are parallel but not lockstep. Each drive may take a different amount of time to
load, become ready, stream, verify, rewind, and unload. The faster worker waits at the completion
barrier; `DONE/CLOSED/STAGED` remain impossible until both required sides finish successfully. No
separate peer-grace timer was added because it would duplicate or shorten the existing independent
phase deadlines.

For asymmetric streaming hardware, optional `BRIC_TAPE_IO_TIMEOUT_0` and
`BRIC_TAPE_IO_TIMEOUT_1` overrides now complement the existing per-drive READY and UNLOAD timeouts.
The daemon logs barrier begin, each worker join, and barrier end.

## Tests

- Added `run_nfs_bus.sh` for strict/disabled NFS-contract behaviour.
- Extended wrapper export checks and dual-drive barrier logging checks.
