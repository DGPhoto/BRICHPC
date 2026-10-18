# Review 30U — in-place updates and authoritative release identity

This review turns BRIC releases into self-identifying, safely updatable packages.

## New release identity

Every complete release contains `/opt/bric2/RELEASE`. Users can query it with:

```bash
bric version
```

Administrators can query an installation without the user CLI:

```bash
bric-update --current
```

The release marker is installed last by the updater, so an interrupted update does not advertise a
new review prematurely.

## New `bric-update`

Run the updater from an extracted new release, once per host:

```bash
./bric-update --role slurm --target /opt/bric2
./bric-update --role tape  --target /opt/bric2
```

The updater:

- verifies the incoming package against `MANIFEST.sha256`;
- refuses to update while cluster runs or tape writes/reservations are active;
- stops/restarts the systemd tape daemon only on the tape host;
- compares checksums and replaces only changed static files;
- backs up every replaced or removed managed file under `/var/backups/bric2`;
- preserves catalogs, WAL/SHM files, logs, configuration, bus keys, master keys and user homes;
- updates the `bric`, `bric-activate-user`, `bric-update`, man-page and systemd integrations;
- validates checksums and Bash syntax after installation;
- records the selected installed-file manifest for safe obsolete-file removal in later updates.

It deliberately does not run `bric-setup.sh` and performs no database migration in this review.

## Setup safety

For `BRIC_TAPE_BACKEND=real`, setup no longer invents barcode labels when
`BRIC_BARCODES_FILE` is missing. Synthetic labels remain available only for simulation/staging.
