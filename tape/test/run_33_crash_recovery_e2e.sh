#!/bin/bash
. "$(cd "$(dirname "$(readlink -f "$0")")" && pwd)/lib_test_daemon.sh"
# Review 33R3 E2E: SIGKILL a real restore while a directory is RELAXED, then recover/retry.
set -euo pipefail
export BRIC_CONFIG=none
REPO="${1:-$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)}"
ROOT="$(mktemp -d /tmp/bric-crash33.XXXXXX)"; echo "workroot=$ROOT"
fail=0; ok(){ echo "  ok: $*"; }; bad(){ echo "  FAIL: $*"; fail=1; }
export BRIC_HOME="$REPO/cluster" BRIC_DB="$ROOT/cluster.db" BRIC_QNAP="$ROOT/qnap/bric" BRIC_KEYS="$ROOT/keys" BRIC_SQL_INIT="$REPO/cluster/sql/cluster_init.sql"
export BRIC_USER=crashuser BRIC_RUN_MODE=local BRIC_POLL=1 BRIC_RESERVE_TIMEOUT=120 BRIC_DRAIN_TIMEOUT=180 BRIC_CLOSE_TIMEOUT=180 BRIC_RESTORE_TIMEOUT=180 BRIC_KEEP_RESTORE_BUS=1
export BRIC_TAPE_HOME="$REPO/tape" BRIC_TAPE_DB="$ROOT/tape.db" BRIC_TAPE_SQL_INIT="$REPO/tape/sql/tape_init.sql" BRIC_TAPE_BACKEND=sim BRIC_TAPELIB="$ROOT/tapelib" BRIC_TAPE_LOCK="$ROOT/tape.lock"
export BRIC_RESTORE_PROGRESS_INTERVAL=1 BRIC_RESTORE_CONSUME_TIMEOUT=120 BRIC_LOG_DIR="$ROOT/log/primary" BRIC_LOG_FALLBACK_DIR="$ROOT/log/fallback" BRIC_REQUIRE_LOGGING=1 BRIC_RESTORE_JOURNAL_ROOT="$ROOT/journal"
mkdir -p "$BRIC_QNAP" "$BRIC_KEYS" "$BRIC_TAPELIB" "$BRIC_LOG_DIR" "$BRIC_LOG_FALLBACK_DIR" "$ROOT/journal"
sqlite3 "$BRIC_DB" < "$BRIC_SQL_INIT" >/dev/null; sqlite3 "$BRIC_TAPE_DB" < "$BRIC_TAPE_SQL_INIT" >/dev/null
sqlite3 "$BRIC_DB" "UPDATE config SET value='1048576' WHERE key='segment_target_bytes';"; sqlite3 "$BRIC_TAPE_DB" "UPDATE config SET value='1' WHERE key='poll_seconds';"
head -c 32 /dev/urandom | base64 > "$BRIC_KEYS/${BRIC_USER}_user_key.txt"; head -c 32 /dev/urandom | base64 > "$BRIC_KEYS/master.key"
sqlite3 "$BRIC_TAPE_DB" "INSERT INTO tapes(volumetag,slot,role,pair_number,paired_volumetag,capacity_tb,used_tb,status) VALUES('000096L9',1,'PRIMARY',1,'000097L9',18,0,'EMPTY'),('000097L9',2,'BACKUP',1,'000096L9',18,0,'EMPTY');"
SRC="$ROOT/source"; mkdir -p "$SRC/frozen/data" "$SRC/open"; dd if=/dev/urandom of="$SRC/frozen/data/file.dat" bs=1K count=64 status=none
for i in 1 2 3 4; do dd if=/dev/urandom of="$SRC/open/f$i.bin" bs=1M count=2 status=none; done
WANT="$(sha256sum "$SRC/frozen/data/file.dat" | awk '{print $1}')"; chmod 000 "$SRC/frozen"
setsid "$REPO/tape/bin/bric-tape-daemon" --loop >"$ROOT/daemon.log" 2>&1 & DAEMON=$!
cleanup(){ bric_test_stop_group "$DAEMON"; chmod -R u+rwx "$ROOT" 2>/dev/null || true; [ -n "${KEEP:-}" ] || { rm -rf "$ROOT" 2>/dev/null || { sleep 1; rm -rf "$ROOT"; }; }; }
trap cleanup EXIT; sleep 1
RUN="$("$REPO/cluster/bin/bric" backup --project crash --source "$SRC" --as frozenset)" || exit 1
[ "$(sqlite3 "$BRIC_DB" "SELECT status FROM runs WHERE run_id='$RUN';")" = CLOSED ] && ok "backup CLOSED" || bad "backup not CLOSED"
DEST="$ROOT/restored"
setsid bash -c '"$0" --project crash --dest "$1" >"$2" 2>&1' "$REPO/cluster/scripts/bric-restore.sh" "$DEST" "$ROOT/restore1.log" & RPID=$!
JDB=""; got_relaxed=0
for i in $(seq 1 240); do
  sleep 0.5; [ -n "$JDB" ] || JDB="$(find "$ROOT/journal" -name '*.sqlite' 2>/dev/null | head -1)"
  if [ -n "$JDB" ]; then n="$(sqlite3 -batch "$JDB" "SELECT COUNT(*) FROM dirs WHERE state='RELAXED';" 2>/dev/null || echo 0)"; [ "${n:-0}" -ge 1 ] && { got_relaxed=1; break; }; fi
  kill -0 "$RPID" 2>/dev/null || break
done
[ "$got_relaxed" -eq 1 ] && ok "caught restore with RELAXED journal row" || bad "never observed RELAXED row"
kill -9 -- -"$RPID" 2>/dev/null || kill -9 "$RPID" 2>/dev/null || true; wait "$RPID" 2>/dev/null || true; sleep 1
[ "$(find "$ROOT/journal" -name '*.sqlite' 2>/dev/null | wc -l)" -ge 1 ] && ok "journal survived SIGKILL" || bad "journal missing after crash"
FM="$(stat -c '%a' "$DEST/frozen" 2>/dev/null || echo absent)"; echo "  mode after crash: $FM"
set +e; "$REPO/cluster/scripts/bric-restore.sh" --project crash --dest "$DEST" >"$ROOT/restore2.log" 2>&1; R2=$?; set -e
[ "$R2" -eq 0 ] && ok "second restore exited 0" || bad "second restore rc=$R2"
grep -q 'recovering stale restore metadata journal' "$ROOT/restore2.log" && ok "stale journal detected" || bad "stale recovery message missing"
grep -q 'stale restore metadata journal recovered' "$ROOT/restore2.log" && ok "stale journal recovered" || bad "stale recovery completion missing"
FM2="$(stat -c '%a' "$DEST/frozen" 2>/dev/null || echo '?')"; { [ "$FM2" = 0 ] || [ "$FM2" = 000 ]; } && ok "final restrictive mode restored" || bad "final mode=$FM2"
chmod -R u+rwx "$DEST" 2>/dev/null || true
[ "$(sha256sum "$DEST/frozen/data/file.dat" 2>/dev/null | awk '{print $1}')" = "$WANT" ] && ok "payload intact" || bad "payload mismatch"
[ "$(find "$ROOT/journal" -name '*.sqlite' 2>/dev/null | wc -l)" -eq 0 ] && ok "journal cleared after retry" || bad "journal left after retry"
echo
[ "$fail" -eq 0 ] && echo "CRASH-WINDOW PASS" || echo "CRASH-WINDOW FAIL"
exit "$fail"
