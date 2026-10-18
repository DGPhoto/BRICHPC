#!/bin/bash
. "$(cd "$(dirname "$(readlink -f "$0")")" && pwd)/lib_test_daemon.sh"
# A physical append that reached WRITTEN has consumed tape even if the daemon crashes during
# read-back before VERIFIED. Recovery must account that orphan exactly once, requeue the CLAIMED
# chunk, rewrite it, and still close the backup.
set -euo pipefail
export BRIC_CONFIG=none
REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
ROOT="$(mktemp -d)"
DA=0; DB=0; BK=0
export BRIC_LOG_DIR="$ROOT/log/primary" BRIC_LOG_FALLBACK_DIR="$ROOT/log/fallback" BRIC_REQUIRE_LOGGING=1
mkdir -p "$BRIC_LOG_DIR" "$BRIC_LOG_FALLBACK_DIR"
kill_tree(){
  local pid="${1:-0}" child
  [ "$pid" -gt 0 ] 2>/dev/null || return 0
  while read -r child; do [ -n "$child" ] && kill_tree "$child"; done < <(pgrep -P "$pid" 2>/dev/null || true)
  kill -9 "$pid" 2>/dev/null || true
}
trap 'bric_test_stop_group "${DA:-0}" KILL; bric_test_stop_group "${DB:-0}" KILL; kill_tree "${BK:-0}"; bric_test_rmrf_retry "$ROOT"' EXIT
fail(){ echo "FAIL: $*" >&2; exit 1; }

export BRIC_HOME="$REPO/cluster" BRIC_DB="$ROOT/cluster.db" BRIC_QNAP="$ROOT/qnap/bric" BRIC_KEYS="$ROOT/keys"
export BRIC_SQL_INIT="$REPO/cluster/sql/cluster_init.sql" BRIC_USER="writtenuser" BRIC_RUN_MODE=local
export BRIC_RESERVE_TIMEOUT=60 BRIC_DRAIN_TIMEOUT=120 BRIC_CLOSE_TIMEOUT=120 BRIC_POLL=1
export BRIC_TAPE_HOME="$REPO/tape" BRIC_TAPE_DB="$ROOT/tape.db" BRIC_TAPE_SQL_INIT="$REPO/tape/sql/tape_init.sql"
export BRIC_TAPE_BACKEND=sim BRIC_TAPELIB="$ROOT/tapelib" BRIC_TAPE_LOCK="$ROOT/tape.lock"
mkdir -p "$BRIC_QNAP" "$BRIC_KEYS" "$BRIC_TAPELIB"
sqlite3 "$BRIC_DB" < "$BRIC_SQL_INIT" >/dev/null
sqlite3 "$BRIC_TAPE_DB" < "$BRIC_TAPE_SQL_INIT" >/dev/null
sqlite3 "$BRIC_DB" "UPDATE config SET value='8388608' WHERE key='segment_target_bytes';"
sqlite3 "$BRIC_TAPE_DB" "UPDATE config SET value='1' WHERE key='poll_seconds';"
head -c 32 /dev/urandom | base64 > "$BRIC_KEYS/${BRIC_USER}_user_key.txt"
head -c 32 /dev/urandom | base64 > "$BRIC_KEYS/master.key"; chmod 600 "$BRIC_KEYS"/*
sqlite3 "$BRIC_TAPE_DB" "INSERT INTO tapes(volumetag,slot,role,pair_number,paired_volumetag,capacity_tb,used_tb,status)
 VALUES('000000L9',1,'PRIMARY',1,'000001L9',18,0,'EMPTY'),('000001L9',2,'BACKUP',1,'000000L9',18,0,'EMPTY');"
SRC="$ROOT/src"; mkdir -p "$SRC"; dd if=/dev/urandom of="$SRC/payload.bin" bs=1M count=4 status=none
SIZE="$(stat -c%s "$SRC/payload.bin")"

BRIC_FAULT_AFTER_WRITTEN_DELAY=12 setsid "$REPO/tape/bin/bric-tape-daemon" --loop >"$ROOT/daemonA.log" 2>&1 & DA=$!
(
  set +e
  "$REPO/cluster/bin/bric" backup --project written_recovery --source "$SRC" >"$ROOT/backup.log" 2>&1
  echo "$?" > "$ROOT/backup.rc"
) & BK=$!

waited=0
while :; do
  STATE="$(sqlite3 "$BRIC_TAPE_DB" "SELECT state FROM segments WHERE copy_role='PRIMARY' LIMIT 1;" 2>/dev/null || true)"
  [ "$STATE" = WRITTEN ] && break
  sleep 1; waited=$((waited+1))
  if [ "$waited" -ge 60 ]; then
    echo "  diagnostic: segment states: $(sqlite3 "$BRIC_TAPE_DB" "SELECT copy_role||':'||state FROM segments ORDER BY copy_role;" 2>/dev/null | tr '\n' ' ')" >&2
    fail "fault daemon did not reach WRITTEN window"
  fi
done
# Review 31D runs one_pass in a supervised child so Bash errexit remains effective. Simulate the
# service-generation crash that systemd KillMode=control-group provides: kill descendants first,
# then the MainPID. Killing only MainPID would intentionally leave the supervised pass alive.
bric_test_stop_group "$DA" KILL; DA=0
[ "$STATE" = WRITTEN ] || fail "expected crash-left WRITTEN, got '$STATE'"
[ "$(find "$BRIC_TAPELIB/000000L9" -type f -name 'f_*' 2>/dev/null | wc -l | tr -d ' ')" = 1 ] || fail "expected one physical orphan on PRIMARY"

echo "  ok: forced crash after physical append at WRITTEN"
setsid "$REPO/tape/bin/bric-tape-daemon" --loop >"$ROOT/daemonB.log" 2>&1 & DB=$!
waited=0
while [ ! -f "$ROOT/backup.rc" ]; do sleep 1; waited=$((waited+1)); [ "$waited" -ge 120 ] && fail "backup did not finish after WRITTEN recovery"; done
wait "$BK" 2>/dev/null || true; BK=0
[ "$(cat "$ROOT/backup.rc")" = 0 ] || fail "backup returned $(cat "$ROOT/backup.rc")"
bric_test_stop_group "$DB" KILL; DB=0

grep -Rq 'RECOVERY_END.*segments_abandoned=' "$BRIC_LOG_DIR/events" "$BRIC_LOG_FALLBACK_DIR/events" 2>/dev/null || fail "recovery event missing"
[ "$(sqlite3 "$BRIC_DB" "SELECT status FROM runs WHERE project_name='written_recovery';")" = CLOSED ] || fail "run not CLOSED"
# PRIMARY contains orphan + verified rewrite; BACKUP contains its verified copy.
[ "$(find "$BRIC_TAPELIB/000000L9" -type f -name 'f_*' | wc -l | tr -d ' ')" -ge 2 ] || fail "PRIMARY orphan was not followed by rewrite"
[ "$(find "$BRIC_TAPELIB/000001L9" -type f -name 'f_*' | wc -l | tr -d ' ')" -ge 1 ] || fail "BACKUP copy missing"
# Integer-byte projection avoids floating comparison noise: primary must account at least 2x payload.
PBYTES="$(sqlite3 "$BRIC_TAPE_DB" "SELECT CAST(used_tb*1000000000000 AS INTEGER) FROM tapes WHERE volumetag='000000L9';")"
BBYTES="$(sqlite3 "$BRIC_TAPE_DB" "SELECT CAST(used_tb*1000000000000 AS INTEGER) FROM tapes WHERE volumetag='000001L9';")"
[ "$PBYTES" -ge "$((SIZE*2-2))" ] || fail "PRIMARY used_tb undercounts orphan+rewrite ($PBYTES < $((SIZE*2)))"
[ "$BBYTES" -ge "$((SIZE-2))" ] || fail "BACKUP used_tb undercounts verified copy ($BBYTES < $SIZE)"
echo "  ok: orphan capacity accounted and backup recovered to CLOSED"
echo "PASS run_written_recovery"
