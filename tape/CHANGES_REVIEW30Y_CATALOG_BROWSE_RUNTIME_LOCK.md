# Review 30Y — catalog browsing and runtime-lock repair

## User-visible archive contents

- Adds `bric contents PROJECT` to list paths from the latest CLOSED backup.
- Adds `bric find PROJECT QUERY` for case-insensitive path search.
- Both commands query the cluster catalog only: they do not mount, load or read tapes.
- `--run` selects a specific CLOSED run; normal users may inspect only projects they own.
- `--type all|file|dir|link`, `--long`, `--limit` and `--offset` support filtering and pagination.
- Paths containing tabs/newlines/backslashes are escaped for unambiguous terminal output.
- Help, man page, README and CLI tests document the commands.

## Tape inventory apply fix

`bric-tape-import-inventory --apply` now recreates missing parent directories for the daemon and work locks after stopping systemd. This fixes `/run/bric/bric-tape-daemon.lock: No such file or directory` when `RuntimeDirectory=bric` is removed on daemon stop. The unit also uses `RuntimeDirectoryPreserve=yes` as a defensive measure.

No database migration and no on-tape format change are required.
