#!/bin/bash
. "$(cd "$(dirname "$(readlink -f "$0")")" && pwd)/lib_test_daemon.sh"
# Restore fallback (invariant 5 applies to restore, not only DR):
#   A) corrupt the PRIMARY copy of a chunk ON TAPE -> bric-restore must succeed transparently from
#      the BACKUP copy, and the PRIMARY tape must be marked SUSPECT with read_errors incremented.
#   B) make a tape file physically unreadable (removed in sim) -> the daemon must NOT die; the
#      restore must still succeed from the surviving copy.
#   C) destroy BOTH copies of a chunk -> restore must fail with the daemon's explicit
#      "no readable verified copy" reason (not a misleading "blob missing").
set -euo pipefail
export BRIC_CONFIG=none   # hermetic: never read /etc/bric/bric.conf inside tests
REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
ROOT="$(mktemp -d)"
echo "workroot=$ROOT"
fail=0; ok() { echo "  ok: $*"; }; bad() { echo "  FAIL: $*"; fail=1; }

export BRIC_HOME="$REPO/cluster" BRIC_DB="$ROOT/cluster_catalog.db" BRIC_QNAP="$ROOT/qnap/bric"
export BRIC_KEYS="$ROOT/keys" BRIC_SQL_INIT="$REPO/cluster/sql/cluster_init.sql"
export BRIC_USER="vsz652" BRIC_RUN_MODE="local"
export BRIC_RESERVE_TIMEOUT=60 BRIC_DRAIN_TIMEOUT=60 BRIC_CLOSE_TIMEOUT=60 BRIC_POLL=1 BRIC_RESTORE_TIMEOUT=30
export BRIC_TAPE_HOME="$REPO/tape" BRIC_TAPE_DB="$ROOT/tape_catalog.db" BRIC_TAPE_SQL_INIT="$REPO/tape/sql/tape_init.sql"
export BRIC_TAPE_BACKEND="sim" BRIC_TAPELIB="$ROOT/tapelib" BRIC_TAPE_LOCK="$ROOT/tape.lock"

mkdir -p "$BRIC_QNAP" "$BRIC_KEYS" "$BRIC_TAPELIB"
chmod +x "$REPO"/cluster/scripts/*.sh "$REPO"/cluster/bin/bric "$REPO"/tape/bin/bric-tape-daemon 2>/dev/null || true
sqlite3 "$BRIC_DB" < "$BRIC_SQL_INIT" >/dev/null
sqlite3 "$BRIC_TAPE_DB" < "$BRIC_TAPE_SQL_INIT" >/dev/null
sqlite3 "$BRIC_DB" "UPDATE config SET value='4194304' WHERE key='segment_target_bytes';"
sqlite3 "$BRIC_TAPE_DB" "UPDATE config SET value='1' WHERE key='poll_seconds';"
head -c 32 /dev/urandom | base64 > "$BRIC_KEYS/${BRIC_USER}_user_key.txt"
head -c 32 /dev/urandom | base64 > "$BRIC_KEYS/master.key"
sqlite3 "$BRIC_TAPE_DB" "INSERT INTO tapes(volumetag,slot,role,pair_number,paired_volumetag,capacity_tb,used_tb,status)
  VALUES('000000L9',1,'PRIMARY',1,'000001L9',18,0,'EMPTY'),('000001L9',2,'BACKUP',1,'000000L9',18,0,'EMPTY');"

setsid "$REPO/tape/bin/bric-tape-daemon" --loop >"$ROOT/daemon.log" 2>&1 & DAEMON=$!
trap 'bric_test_stop_group "$DAEMON"; [ -n "${KEEP:-}" ] || { rm -rf "$ROOT" 2>/dev/null || { sleep 1; rm -rf "$ROOT"; }; }' EXIT
sleep 1

echo "=== archive a project with a large file (multiple chunk kinds) ==="
SRC="$ROOT/data/fbk"; mkdir -p "$SRC"
dd if=/dev/urandom of="$SRC/small.dat" bs=1M count=2 status=none
dd if=/dev/urandom of="$SRC/huge.bam"  bs=1M count=9 status=none
RUN="$("$REPO/cluster/bin/bric" backup --project fbk --source "$SRC")"
[ "$(sqlite3 "$BRIC_DB" "SELECT status FROM runs WHERE run_id='$RUN';")" = CLOSED ] && ok "run CLOSED" || { bad "run not closed"; exit 1; }

echo "=== A) corrupt the PRIMARY copy of chunk 1 on tape ==="
read -r PVT PFN <<<"$(sqlite3 -separator ' ' "$BRIC_TAPE_DB" "SELECT volumetag,file_number FROM segments WHERE run_id='$RUN' AND chunk_no=1 AND copy_role='PRIMARY';")"
dd if=/dev/urandom of="$BRIC_TAPELIB/$PVT/$(printf 'f_%06d' "$PFN")" bs=4096 count=1 conv=notrunc status=none
ok "flipped bytes in $PVT#$PFN (PRIMARY of chunk 1)"
if "$REPO/cluster/scripts/bric-restore.sh" --project fbk --dest "$ROOT/restA" >"$ROOT/restA.log" 2>&1 \
   && diff -r "$SRC" "$ROOT/restA" >/dev/null 2>&1; then
    ok "restore succeeded transparently from the BACKUP copy (tree bit-identical)"
else bad "restore did not heal from BACKUP"; tail -3 "$ROOT/restA.log"; fi
H="$(sqlite3 "$BRIC_TAPE_DB" "SELECT health||'|'||read_errors FROM tapes WHERE volumetag='$PVT';")"
[ "$H" = "SUSPECT|1" ] && ok "PRIMARY tape marked SUSPECT with read_errors=1" || bad "tape health not updated: $H"
grep -q "fails sha256 — marking $PVT SUSPECT" "$ROOT/daemon.log" && ok "daemon logged the per-copy verification failure" || bad "no verify-fail log"

echo "=== B) physically unreadable PRIMARY file: daemon must survive ==="
read -r P2VT P2FN <<<"$(sqlite3 -separator ' ' "$BRIC_TAPE_DB" "SELECT volumetag,file_number FROM segments WHERE run_id='$RUN' AND chunk_no=2 AND copy_role='PRIMARY';")"
mv "$BRIC_TAPELIB/$P2VT/$(printf 'f_%06d' "$P2FN")" "$ROOT/hidden_f2"
if "$REPO/cluster/scripts/bric-restore.sh" --project fbk --dest "$ROOT/restB" >"$ROOT/restB.log" 2>&1 \
   && diff -r "$SRC" "$ROOT/restB" >/dev/null 2>&1; then
    ok "restore succeeded despite an unreadable PRIMARY tape file"
else bad "restore failed with unreadable PRIMARY"; tail -3 "$ROOT/restB.log"; fi
kill -0 "$DAEMON" 2>/dev/null && ok "daemon is still alive (read failure did not kill it)" || bad "DAEMON DIED on unreadable tape file"
mv "$ROOT/hidden_f2" "$BRIC_TAPELIB/$P2VT/$(printf 'f_%06d' "$P2FN")"

echo "=== C) BOTH copies of chunk 1 destroyed: explicit failure reason ==="
read -r BVT BFN <<<"$(sqlite3 -separator ' ' "$BRIC_TAPE_DB" "SELECT volumetag,file_number FROM segments WHERE run_id='$RUN' AND chunk_no=1 AND copy_role='BACKUP';")"
dd if=/dev/urandom of="$BRIC_TAPELIB/$BVT/$(printf 'f_%06d' "$BFN")" bs=4096 count=1 conv=notrunc status=none
if "$REPO/cluster/scripts/bric-restore.sh" --project fbk --dest "$ROOT/restC" >"$ROOT/restC.log" 2>&1; then
    bad "restore should have failed with both copies destroyed"
else
    grep -q "no readable verified copy" "$ROOT/restC.log" \
        && ok "failure carries the daemon's explicit reason (no readable verified copy)" \
        || { bad "failure reason not surfaced"; tail -3 "$ROOT/restC.log"; }
fi
kill -0 "$DAEMON" 2>/dev/null && ok "daemon still alive after total-loss scenario" || bad "daemon died"

echo
[ "$fail" -eq 0 ] && echo "✓ RESTORE FALLBACK CHECKS PASSED" || { echo "✗ RESTORE FALLBACK FAILURES"; exit 1; }
