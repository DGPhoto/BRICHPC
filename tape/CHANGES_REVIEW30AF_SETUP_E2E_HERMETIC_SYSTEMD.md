# Review 30AF — hermetic setup E2E systemd/admin-path isolation

## Problem

The complete Review 30AE native suite on `supekgate04fl` passed 56/57 tests. The sole failure was
`run_setup_e2e.sh`. Its functional provisioning path was healthy — backup CLOSED, restore was
bit-identical, DR was bit-identical — but the test itself was not fully hermetic. `bric-setup.sh --role all`
used the default administrative destinations and the host's real systemd, so the test could install
`/etc/systemd/system/bric-tape-daemon.service`, invoke `systemctl enable --now`, and inspect/kill a
manual `/opt/bric2/tape/bin/bric-tape-daemon --loop` process. On a SLURM host this made the test result
depend on the unrelated role-filtered `/opt/bric2` installation and could mutate host state.

## Changes

- `run_setup_e2e.sh` redirects every administrative setup destination into its temporary test root:
  - `BRIC_SYSTEMD_UNIT_DIR`;
  - `BRIC_COMMAND_LINK`;
  - `BRIC_ACTIVATE_USER_LINK`;
  - `BRIC_BUS_CLEANUP_LINK`;
  - `BRIC_UPDATE_LINK`;
  - `BRIC_TAPE_IMPORT_LINK`;
  - `BRIC_MAN_DIR`.
- The setup calls run with test-local shims for `systemctl`, `ps`, and `pgrep`.
  - `ps` deterministically reports PID 1 as systemd so the systemd installation branch is exercised.
  - `systemctl` logs and succeeds for the expected lifecycle calls instead of touching the real service manager.
  - `pgrep` records the manual-daemon collision check but never returns a host PID, so the test cannot kill a real daemon.
- The test asserts that the temporary systemd unit and tape-import link were created.
- The test asserts that `daemon-reload`, `enable --now`, and `is-active --quiet` were exercised.
- The test fingerprints the real administrative paths before setup and verifies they are unchanged after both setup runs.
- `run_update.sh` release assertions were advanced to Review 30AF.

## Scope

This is a test-harness hermeticity release. Production cluster/tape datapaths are unchanged from Review 30AE.

## Compatibility

- Database migration: none.
- Bus protocol: unchanged.
- On-tape format: `BRIC-FORMAT-V1` unchanged.
- Existing catalogs, keys, assignments and media remain compatible.
