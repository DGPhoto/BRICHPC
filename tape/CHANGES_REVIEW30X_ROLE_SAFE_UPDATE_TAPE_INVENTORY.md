# Review 30X — role-safe updates and real tape inventory import

## In-place updater role safety

`bric-update` now reads `BRIC_ROLE` directly and safely from the selected `/etc/bric/bric.conf`.
The config file is parsed, never sourced. With a config present:

- `--role` is no longer required;
- a matching `--role` is accepted only as an assertion;
- a conflicting `--role` fails before active-work checks, service stops or file changes;
- a missing or invalid `BRIC_ROLE` fails closed instead of guessing.

When the selected config does not exist, an explicit `--role` remains available for offline and test
trees.

## Physical tape inventory importer

New tape-host command:

```bash
bric-tape-import-inventory --dry-run
bric-tape-import-inventory --apply
```

It reads the real `mtx status` inventory and:

- follows the configured `BRIC_PRIMARY_PARITY` / catalog `primary_parity` convention;
- imports only complete PRIMARY/BACKUP pairs;
- records the real home Storage Element for each barcode, including loaded media;
- preserves status, project, owner, used space, health and wear telemetry of existing tapes;
- refuses to reinterpret any assigned or written tape under a different role/pair;
- reports and skips incomplete pair members;
- preserves catalog-only/offsite media;
- refuses active reservations/writes;
- stops and restarts the systemd daemon for an apply operation;
- creates a timestamped SQLite backup and runs `PRAGMA integrity_check`.

The importer is installed as `/usr/local/sbin/bric-tape-import-inventory` on the tape role.

## Preflight pairing correction

`bric-library-preflight` no longer assumes even-numbered PRIMARY barcodes. Its physical pair summary
uses the configured/catalog parity and reports orphan PRIMARY or BACKUP members consistently.

## Compatibility

- No database schema migration.
- No on-tape format change.
- Existing catalogs, keys, configuration, user homes and NFS bus content are preserved by update.
