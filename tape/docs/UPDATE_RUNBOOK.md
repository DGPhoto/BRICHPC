# BRIC Archive in-place update runbook

This runbook starts with Review 30U. Do not rerun `bric-setup.sh` for a normal software update.

## Preconditions

Finish or cancel all backup and restore jobs first. On the Slurm host:

```bash
bric jobs
bric status
```

No job may be `RUNNING`, and no archive run may be in `PLANNING`, `RESERVED`, `PRODUCING`,
`DRAINING` or `CLOSING`. The updater also performs catalog safety checks and refuses active work.

Copy the complete release tarball to each host and verify its SHA-256 file before extraction.

## Extract the incoming release

From the directory containing both the tarball and its `.sha256` file, substitute the incoming
release filename:

```bash
sha256sum -c bric_archive_2_0_reviewNN_description_YYYYMMDD.tar.gz.sha256

rm -rf /tmp/bric-new
mkdir -p /tmp/bric-new

tar -xzf bric_archive_2_0_reviewNN_description_YYYYMMDD.tar.gz \
    -C /tmp/bric-new \
    --strip-components=1

cd /tmp/bric-new
sha256sum -c MANIFEST.sha256
```

## Slurm/cluster host

From Review 30X onward the updater reads `BRIC_ROLE` from `/etc/bric/bric.conf`. Do not normally
pass `--role`; a conflicting manual role is rejected before any service or file is touched.

Preview:

```bash
sudo /tmp/bric-new/bric-update --target /opt/bric2 --dry-run
```

Apply:

```bash
sudo /tmp/bric-new/bric-update --target /opt/bric2
```

Verify:

```bash
bric version
bric status
bric jobs
sudo bric-update --current
```

## Tape server

The same commands are used. `BRIC_ROLE=tape` in `/etc/bric/bric.conf` selects the tape files and
systemd integration automatically:

```bash
sudo /tmp/bric-new/bric-update --target /opt/bric2 --dry-run
sudo /tmp/bric-new/bric-update --target /opt/bric2
```

`--role slurm|tape` remains available only as an optional assertion, or when the selected config file
does not exist (offline/test trees). It can no longer override an existing host config.

The updater refuses active tape reservations/writes, stops the daemon, updates changed static files
and the installed unit, then restarts the daemon only if it was active before the update.

Verify:

```bash
sudo bric-update --current
systemctl status bric-tape-daemon.service --no-pager -l
BRIC_CONFIG=/etc/bric/bric.conf /opt/bric2/tape/bin/bric-library-preflight
```

## Preserved state

The updater does not modify:

- `/opt/bric2/cluster/db/` and `/opt/bric2/tape/db/`;
- catalog WAL/SHM files;
- `/etc/bric/bric.conf`;
- `/etc/bric/keys/`;
- `/root/.bric/`;
- users' `~/.bric/` directories and personal keys;
- cluster/tape runtime logs;
- the QNAP/NFS archive and restore bus.

Replaced and removed static files are copied under:

```text
/var/backups/bric2/update-OLD-to-NEW-ROLE-TIMESTAMP/
```

The first update from a pre-30U installation has no previous managed-file manifest, so it does not
remove unknown legacy files. From 30U onward, obsolete files are removed only when they were listed
in the previous `.bric-managed-files` manifest, and they are backed up first.

## Cleaning terminal QNAP bus directories (Review 30V+)

The shared `archive/` and `restore/` trees are transient transport areas. Normal 30V+ backup/restore
completion removes its own terminal directory. To inspect and clean leftovers from older releases:

```bash
sudo bric-bus-cleanup --dry-run
sudo bric-bus-cleanup
```

CLOSED and DENIED runs require valid signed terminal receipts. FAILED/CANCELLED runs require the
signed tape-side `run.ABORT_DONE`, so cleanup cannot race reservation release or crash recovery.
Use `--force` only after separately proving no recovery is pending.


## Importing the physical tape inventory (Review 30X+)

On the tape server, preview all complete pairs currently reported by the changer:

```bash
sudo bric-tape-import-inventory --dry-run
```

Apply after reviewing the pair convention and orphan list:

```bash
sudo bric-tape-import-inventory --apply
```

The importer preserves existing ownership, used space, health and write history. It adds only
complete PRIMARY/BACKUP pairs, refreshes their real home slots, leaves catalog-only/offsite media
untouched, and creates a SQLite backup before committing.
