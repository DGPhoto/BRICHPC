#!/bin/bash
# Reset operational cluster-catalog state while preserving institutional config and user escrows.
# Root only. Creates a consistent SQLite backup first and refuses to run while BRIC processes exist.
set -euo pipefail
IFS=$'\n\t'
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
. "$HERE/lib_common.sh"
[ "${EUID:-$(id -u)}" -eq 0 ] || die "bric-reset-catalog must be run as root"
bric_log_process_start "bric-reset-catalog" "$@"
require_cmds sqlite3 pgrep date mkdir chmod

YES=0; FORCE=0; BACKUP_DIR="${BRIC_CATALOG_BACKUP_DIR:-/var/backups/bric}"
while [ "$#" -gt 0 ]; do case "$1" in
    --yes) YES=1; shift;;
    --force) FORCE=1; shift;;
    --backup-dir) BACKUP_DIR="${2:-}"; shift 2;;
    -h|--help)
        cat <<'USAGE'
usage: bric-reset-catalog --yes [--force] [--backup-dir DIR]

Deletes projects, runs, chunks, file maps, reservations, tape mappings and audit rows.
Preserves config and users/key escrow. A timestamped SQLite backup is written first.
Refuses while BRIC backup/restore/planner processes are running unless --force is supplied.
USAGE
        exit 0;;
    *) die "unknown option: $1";;
esac; done
[ "$YES" -eq 1 ] || die "refusing destructive reset without --yes"
[ -s "$BRIC_DB" ] || die "cluster catalog not found/empty: $BRIC_DB"
case "$BACKUP_DIR" in /*) ;; *) die "backup directory must be absolute";; esac

ACTIVE="$(pgrep -af '(/cluster/(bin/bric|libexec/bric-tar-stream|scripts/bric-(plan|chunk|stream-backup|stream-plan|stream-gate|stream-publish|reserve-extend|finalize|close|restore)\.sh)|/usr/local/bin/bric (backup|restore))' || true)"
if [ -n "$ACTIVE" ] && [ "$FORCE" -ne 1 ]; then
    printf '%s\n' "$ACTIVE" >&2
    die "BRIC processes are still running; stop them first or use --force after verifying the PIDs"
fi

mkdir -p "$BACKUP_DIR"; chmod 700 "$BACKUP_DIR"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP="$BACKUP_DIR/cluster_catalog.before-reset.$STAMP.db"
LOCK="$(dirname "$BRIC_DB")/.bric-catalog-reset.lock"
exec 9>"$LOCK"
flock -x 9 || die "cannot acquire catalog reset lock: $LOCK"

sqlite3 -batch -cmd '.timeout 60000' "$BRIC_DB" ".backup '$BACKUP'"
chmod 600 "$BACKUP"

sqlite3 -batch -cmd '.timeout 60000' "$BRIC_DB" >/dev/null <<'SQL'
PRAGMA foreign_keys=ON;
BEGIN IMMEDIATE;
DELETE FROM audit_log;
DELETE FROM project_tapes;
DELETE FROM reservation;
DELETE FROM files;
DELETE FROM chunks;
DELETE FROM runs;
DELETE FROM projects;
DELETE FROM sqlite_sequence WHERE name='audit_log';
UPDATE config SET value='0' WHERE key='run_counter';
COMMIT;
PRAGMA wal_checkpoint(TRUNCATE);
SQL

# Legacy root-owned run scratch is never authoritative and may be discarded after the DB reset.
rm -rf "$(dirname "$BRIC_DB")/runstate" 2>/dev/null || true

printf 'BRIC cluster catalog reset complete\n'
printf '  database: %s\n' "$BRIC_DB"
printf '  backup:   %s\n' "$BACKUP"
printf '  preserved: config, users/key escrow\n'
printf 'Users may remove stale private scratch with: rm -rf "$HOME/.bric/runstate/"*\n'
