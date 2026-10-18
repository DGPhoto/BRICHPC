# Review 30Z — inventory-import daemon restart lock fix

## Fixed

`bric-tape-import-inventory --apply` stopped the tape daemon, acquired the daemon singleton
and work-fence locks, updated the catalog, and then attempted to restart systemd from its EXIT
trap while still holding both locks. The new daemon therefore exited immediately with
`another daemon holds ...`, although the inventory transaction had completed successfully.

The importer now:

- explicitly unlocks and closes both administrative lock descriptors before `systemctl start`;
- waits up to ten seconds for the restarted daemon to remain active;
- prints `systemctl status` and recent journal lines when restart validation fails;
- retains all previous transaction, backup, active-work and catalog-integrity safeguards.

The systemd unit now also contains `RuntimeDirectoryPreserve=yes`, matching the 30Y design
and preventing unnecessary removal of `/run/bric` on an ordinary service stop.

No database migration and no on-tape format change are required. A 30Y import that printed
`Inventory import complete` before the restart error is already committed and must not be
repeated solely because of this restart bug.
