#!/bin/bash
. "$(cd "$(dirname "$(readlink -f "$0")")" && pwd)/lib_test_daemon.sh"
set -euo pipefail
export BRIC_CONFIG=none
REPO="${1:-$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)}"
for c in sqlite3 setfacl getfacl setfattr getfattr; do command -v "$c" >/dev/null 2>&1 || { echo "SKIP Review34 metadata E2E: need $c"; exit 0; }; done
ROOT="$(mktemp -d /tmp/bric-r34.XXXXXX)"; echo "workroot=$ROOT"
fail=0; ok(){ echo "  ok: $*"; }; bad(){ echo "  FAIL: $*"; fail=1; }
export BRIC_HOME="$REPO/cluster" BRIC_DB="$ROOT/cluster.db" BRIC_QNAP="$ROOT/qnap/bric" BRIC_KEYS="$ROOT/keys" BRIC_SQL_INIT="$REPO/cluster/sql/cluster_init.sql"
export BRIC_USER=r34user BRIC_RUN_MODE=local BRIC_POLL=1 BRIC_RESERVE_TIMEOUT=120 BRIC_DRAIN_TIMEOUT=180 BRIC_CLOSE_TIMEOUT=180 BRIC_RESTORE_TIMEOUT=180 BRIC_KEEP_RESTORE_BUS=1
export BRIC_TAPE_HOME="$REPO/tape" BRIC_TAPE_DB="$ROOT/tape.db" BRIC_TAPE_SQL_INIT="$REPO/tape/sql/tape_init.sql" BRIC_TAPE_BACKEND=sim BRIC_TAPELIB="$ROOT/tapelib" BRIC_TAPE_LOCK="$ROOT/tape.lock"
export BRIC_LOG_DIR="$ROOT/log/primary" BRIC_LOG_FALLBACK_DIR="$ROOT/log/fallback" BRIC_REQUIRE_LOGGING=1 BRIC_RESTORE_JOURNAL_ROOT="$ROOT/journal"
mkdir -p "$BRIC_QNAP" "$BRIC_KEYS" "$BRIC_TAPELIB" "$BRIC_LOG_DIR" "$BRIC_LOG_FALLBACK_DIR" "$ROOT/journal"
sqlite3 "$BRIC_DB" < "$BRIC_SQL_INIT" >/dev/null; sqlite3 "$BRIC_TAPE_DB" < "$BRIC_TAPE_SQL_INIT" >/dev/null
sqlite3 "$BRIC_DB" "UPDATE config SET value='1048576' WHERE key='segment_target_bytes';"; sqlite3 "$BRIC_TAPE_DB" "UPDATE config SET value='1' WHERE key='poll_seconds';"
head -c32 /dev/urandom | base64 > "$BRIC_KEYS/${BRIC_USER}_user_key.txt"; head -c32 /dev/urandom | base64 > "$BRIC_KEYS/master.key"
sqlite3 "$BRIC_TAPE_DB" "INSERT INTO tapes(volumetag,slot,role,pair_number,paired_volumetag,capacity_tb,used_tb,status) VALUES('000114L9',1,'PRIMARY',1,'000115L9',18,0,'EMPTY'),('000115L9',2,'BACKUP',1,'000114L9',18,0,'EMPTY');"
SRC="$ROOT/source"; mkdir -p "$SRC"
dd if=/dev/urandom of="$SRC/big600.bin" bs=1M count=3 status=none; dd if=/dev/urandom of="$SRC/big755.bin" bs=1M count=3 status=none; dd if=/dev/urandom of="$SRC/big-setgid.bin" bs=1M count=3 status=none; printf small > "$SRC/small.txt"; printf smallsgid > "$SRC/small-setgid.txt"
chmod 600 "$SRC/big600.bin"; chmod 755 "$SRC/big755.bin"; chmod 2755 "$SRC/big-setgid.bin"; chmod 640 "$SRC/small.txt"; chmod 2755 "$SRC/small-setgid.txt"
if [ "$(id -u)" = 0 ]; then mkdir -p "$SRC/frozen/data"; dd if=/dev/urandom of="$SRC/frozen/data/locked444.bin" bs=1M count=3 status=none; chmod 444 "$SRC/frozen/data/locked444.bin"; chmod 000 "$SRC/frozen"; fi
touch -d @1577930640 "$SRC/big600.bin" "$SRC/big755.bin" "$SRC/big-setgid.bin" "$SRC/small.txt" "$SRC/small-setgid.txt"
[ "$(id -u)" != 0 ] || touch -d @1420070400 "$SRC/frozen/data/locked444.bin"
setfacl -m u:nobody:r-- "$SRC/big755.bin" "$SRC/small.txt"
setfattr -n user.bric34 -v 'metadata-roundtrip' "$SRC/big600.bin"; setfattr -n user.bric34 -v 'tar-roundtrip' "$SRC/small.txt"
ACL_BIG="$(getfacl -cp "$SRC/big755.bin")"; ACL_SMALL="$(getfacl -cp "$SRC/small.txt")"
setsid "$REPO/tape/bin/bric-tape-daemon" --loop >"$ROOT/daemon.log" 2>&1 & DAEMON=$!
cleanup(){ bric_test_stop_group "$DAEMON"; chmod -R u+rwx "$ROOT" 2>/dev/null || true; [ -n "${KEEP:-}" ] || bric_test_rmrf_retry "$ROOT"; }; trap cleanup EXIT
sleep 1
RUN="$("$REPO/cluster/bin/bric" backup --project r34 --source "$SRC" --as data 2>"$ROOT/backup.err")" || { tail -40 "$ROOT/backup.err"; exit 1; }
[ "$(sqlite3 "$BRIC_DB" "SELECT status FROM runs WHERE run_id='$RUN';")" = CLOSED ] && ok "run CLOSED" || bad "run not CLOSED"
for f in big600.bin big755.bin big-setgid.bin; do [ "$(sqlite3 "$BRIC_DB" "SELECT type FROM chunks WHERE run_id='$RUN' AND big_rel_path='$f' LIMIT 1;")" = LARGE_FILE_CHUNK ] && ok "$f is LARGE_FILE_CHUNK" || bad "$f not large"; done
if [ "$(id -u)" = 0 ]; then [ "$(sqlite3 "$BRIC_DB" "SELECT type FROM chunks WHERE run_id='$RUN' AND big_rel_path='frozen/data/locked444.bin' LIMIT 1;")" = LARGE_FILE_CHUNK ] && ok "restrictive descendant is LARGE_FILE_CHUNK" || bad "restrictive descendant not large"; fi
[ "$(sqlite3 "$BRIC_DB" "SELECT mode FROM files WHERE run_id='$RUN' AND rel_path='big600.bin';")" = 384 ] && ok "catalog mode 0600 recorded" || bad "catalog mode 0600 missing"
[ -n "$(sqlite3 "$BRIC_DB" "SELECT metadata_b64 FROM files WHERE run_id='$RUN' AND rel_path='big600.bin';")" ] && ok "large metadata envelope recorded" || bad "metadata envelope empty"
DEST="$ROOT/restored"; umask 022; "$REPO/cluster/scripts/bric-restore.sh" --project r34 --dest "$DEST" >"$ROOT/restore.log" 2>&1 || { tail -50 "$ROOT/restore.log"; bad "restore failed"; }
[ "$(stat -c %a "$DEST/big600.bin")" = 600 ] && ok "large 0600 -> 0600" || bad "big600 mode $(stat -c %a "$DEST/big600.bin")"
[ "$(stat -c %a "$DEST/big755.bin")" = 755 ] && ok "large 0755 -> 0755" || bad "big755 mode $(stat -c %a "$DEST/big755.bin")"
[ "$(stat -c %a "$DEST/big-setgid.bin")" = 755 ] && ok "large setgid 2755 -> 0755 by policy" || bad "large setgid mode $(stat -c %a "$DEST/big-setgid.bin")"
[ "$(stat -c %a "$DEST/small.txt")" = 640 ] && ok "TAR_PART 0640 -> 0640" || bad "small mode"
[ "$(stat -c %a "$DEST/small-setgid.txt")" = 755 ] && ok "TAR_PART setgid 2755 -> 0755 by policy" || bad "small setgid mode $(stat -c %a "$DEST/small-setgid.txt")"
for f in big600.bin big755.bin big-setgid.bin small.txt small-setgid.txt; do [ "$(stat -c %Y "$DEST/$f")" = 1577930640 ] && ok "$f mtime restored" || bad "$f mtime $(stat -c %Y "$DEST/$f")"; done
if [ "$(id -u)" = 0 ]; then
    [ "$(stat -c %a "$DEST/frozen")" = 0 ] && ok "restrictive ancestor finalized to mode 000" || bad "restrictive ancestor mode $(stat -c %a "$DEST/frozen")"
    [ "$(stat -c %a "$DEST/frozen/data/locked444.bin")" = 444 ] && ok "large file under mode-000 ancestor restored 0444 exactly" || bad "restrictive descendant mode $(stat -c %a "$DEST/frozen/data/locked444.bin")"
    [ "$(stat -c %Y "$DEST/frozen/data/locked444.bin")" = 1420070400 ] && ok "restrictive descendant mtime restored" || bad "restrictive descendant mtime"
fi
[ "$(getfattr --only-values -n user.bric34 "$DEST/big600.bin" 2>/dev/null)" = metadata-roundtrip ] && ok "large user.* xattr restored" || bad "large xattr"
[ "$(getfattr --only-values -n user.bric34 "$DEST/small.txt" 2>/dev/null)" = tar-roundtrip ] && ok "TAR_PART user.* xattr restored" || bad "small xattr"
[ "$(getfacl -cp "$DEST/big755.bin")" = "$ACL_BIG" ] && ok "large POSIX ACL restored" || bad "large ACL differs"
[ "$(getfacl -cp "$DEST/small.txt")" = "$ACL_SMALL" ] && ok "TAR_PART POSIX ACL restored" || bad "small ACL differs"
# Legacy compatibility: pre-34 large-file catalog did contain mtime but not mode/metadata.
sqlite3 "$BRIC_DB" "UPDATE files SET mode=NULL,metadata_b64='' WHERE run_id='$RUN' AND rel_path='big600.bin';"
DEST2="$ROOT/legacy"; umask 022; "$REPO/cluster/scripts/bric-restore.sh" --project r34 --dest "$DEST2" >"$ROOT/legacy.log" 2>&1 || bad "legacy restore failed"
[ "$(stat -c %Y "$DEST2/big600.bin")" = 1577930640 ] && ok "legacy large-file mtime recovered retroactively" || bad "legacy mtime not restored"
[ "$(stat -c %a "$DEST2/big600.bin")" = 644 ] && ok "legacy mode is not invented (restore umask behavior retained)" || bad "legacy mode unexpectedly $(stat -c %a "$DEST2/big600.bin")"

echo; [ "$fail" -eq 0 ] && echo "REVIEW34 METADATA PASS" || echo "REVIEW34 METADATA FAIL"; exit "$fail"
