#!/bin/bash
. "$(cd "$(dirname "$(readlink -f "$0")")" && pwd)/lib_test_daemon.sh"
# Partial-pair resume: the daemon crashes BETWEEN the PRIMARY write (VERIFIED) and the BACKUP write
# (deterministic via BRIC_FAULT_DIE_BETWEEN_COPIES). On restart + reclaim, the daemon must:
#   - REUSE the surviving VERIFIED PRIMARY (same volumetag/file_number, NO new file on that tape),
#   - write ONLY the missing BACKUP on the partner tape of the SAME pair,
#   - publish DONE, and the run must reach CLOSED with data recoverable via DR.
# Rationale: rewriting the surviving copy would burn a ~1 TB orphan on the append-only tape per crash.
set -euo pipefail
export BRIC_CONFIG=none   # hermetic: never read /etc/bric/bric.conf inside tests
REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
ROOT="$(mktemp -d)"
echo "workroot=$ROOT"
fail=0; ok() { echo "  ok: $*"; }; bad() { echo "  FAIL: $*"; fail=1; }

export BRIC_HOME="$REPO/cluster" BRIC_DB="$ROOT/cluster_catalog.db" BRIC_QNAP="$ROOT/qnap/bric"
export BRIC_KEYS="$ROOT/keys" BRIC_SQL_INIT="$REPO/cluster/sql/cluster_init.sql"
export BRIC_USER="vsz652" BRIC_RUN_MODE="local"
export BRIC_RESERVE_TIMEOUT=60 BRIC_DRAIN_TIMEOUT=60 BRIC_CLOSE_TIMEOUT=60 BRIC_POLL=1
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
UK="$ROOT/uk.txt"; cp "$BRIC_KEYS/${BRIC_USER}_user_key.txt" "$UK"
# production parity convention: even=PRIMARY, BACKUP=PRIMARY+1
sqlite3 "$BRIC_TAPE_DB" "INSERT INTO tapes(volumetag,slot,role,pair_number,paired_volumetag,capacity_tb,used_tb,status)
  VALUES('000000L9',1,'PRIMARY',1,'000001L9',18,0,'EMPTY'),('000001L9',2,'BACKUP',1,'000000L9',18,0,'EMPTY');"

DAEMON_BIN="$REPO/tape/bin/bric-tape-daemon"
trap '[ -n "${KEEP:-}" ] || { rm -rf "$ROOT" 2>/dev/null || { sleep 1; rm -rf "$ROOT"; }; }' EXIT

echo "=== plan + produce (2 chunks), reservation handled by a clean --once pass ==="
SRC="$ROOT/data/crashy"; mkdir -p "$SRC"
dd if=/dev/urandom of="$SRC/a.dat" bs=1M count=2 status=none
dd if=/dev/urandom of="$SRC/b.dat" bs=1M count=2 status=none
RUN="$("$REPO/cluster/scripts/bric-plan.sh" --project crashy --source "$SRC" 2>/dev/null)" &
PLAN_PID=$!
# bric-plan waits for the reservation: serve it with daemon passes until granted
for i in $(seq 1 20); do "$DAEMON_BIN" --once >/dev/null 2>&1 || true; kill -0 $PLAN_PID 2>/dev/null || break; sleep 0.5; done
wait $PLAN_PID || { bad "plan failed"; exit 1; }
RUN="$(sqlite3 "$BRIC_DB" "SELECT run_id FROM runs WHERE project_name='crashy' ORDER BY run_id DESC LIMIT 1;")"
N="$(sqlite3 "$BRIC_DB" "SELECT n_chunks FROM runs WHERE run_id='$RUN';")"
for c in $(seq 1 "$N"); do "$REPO/cluster/scripts/bric-chunk.sh" --run "$RUN" --chunk "$c" >/dev/null 2>&1; done
ok "run $RUN planned and produced ($N chunks READY on the bus)"

echo "=== daemon pass with fault: die between PRIMARY and BACKUP of the first claimed chunk ==="
set +e; BRIC_FAULT_DIE_BETWEEN_COPIES=1 "$DAEMON_BIN" --once >"$ROOT/fault.log" 2>&1; RC=$?; set -e
[ "$RC" = 99 ] && ok "daemon died at the injected fault (rc=99)" || bad "expected rc=99, got $RC"
PPRE="$(sqlite3 -separator '|' "$BRIC_TAPE_DB" "SELECT seg_id,volumetag,file_number FROM segments WHERE run_id='$RUN' AND copy_role='PRIMARY' AND state='VERIFIED';")"
[ "$(printf '%s\n' "$PPRE" | grep -c .)" = 1 ] && ok "exactly one VERIFIED PRIMARY survives the crash" || bad "unexpected PRIMARY rows: $PPRE"
[ -z "$(sqlite3 "$BRIC_TAPE_DB" "SELECT 1 FROM segments WHERE run_id='$RUN' AND copy_role='BACKUP' LIMIT 1;")" ] \
    && ok "no BACKUP row yet (crash landed in the window)" || bad "BACKUP row exists before resume?"
PVT="$(printf '%s' "$PPRE" | cut -d'|' -f2)"; PFN="$(printf '%s' "$PPRE" | cut -d'|' -f3)"
P_FILES_PRE="$(ls "$BRIC_TAPELIB/$PVT" | wc -l)"

echo "=== backdate the CLAIMED marker past the TTL, restart clean, drive to CLOSED ==="
find "$BRIC_QNAP" -name 'chunk_*.CLAIMED' -exec touch -d '8 hours ago' {} +
setsid "$DAEMON_BIN" --loop >>"$ROOT/daemon.log" 2>&1 & DAEMON=$!
trap 'bric_test_stop_group "$DAEMON"; [ -n "${KEEP:-}" ] || { rm -rf "$ROOT" 2>/dev/null || { sleep 1; rm -rf "$ROOT"; }; }' EXIT
"$REPO/cluster/scripts/bric-finalize.sh" --run "$RUN" >/dev/null 2>&1 || bad "finalize failed"
"$REPO/cluster/scripts/bric-close.sh"    --run "$RUN" >/dev/null 2>&1 || bad "close failed"
[ "$(sqlite3 "$BRIC_DB" "SELECT status FROM runs WHERE run_id='$RUN';")" = CLOSED ] && ok "run CLOSED after resume" || bad "run not CLOSED"
bric_test_stop_group "$DAEMON"

echo "=== the surviving PRIMARY was REUSED, only the BACKUP was written ==="
PPOST="$(sqlite3 -separator '|' "$BRIC_TAPE_DB" "SELECT seg_id,volumetag,file_number FROM segments WHERE run_id='$RUN' AND copy_role='PRIMARY' AND state='VERIFIED' AND volumetag='$PVT' AND file_number=$PFN;")"
[ -n "$PPOST" ] && ok "PRIMARY row unchanged ($PVT#$PFN reused, not rewritten)" || bad "PRIMARY was rewritten (row moved from $PVT#$PFN)"
grep -q "reused VERIFIED PRIMARY" "$ROOT/daemon.log" && ok "daemon logged the partial-pair resume" || bad "resume log line missing"
# every chunk has exactly one PRIMARY + one BACKUP, on the two tapes of pair 1
DUP="$(sqlite3 "$BRIC_TAPE_DB" "SELECT COUNT(*) - COUNT(DISTINCT chunk_no||'|'||copy_role) FROM segments WHERE run_id='$RUN' AND state='VERIFIED';")"
[ "$DUP" = 0 ] && ok "no duplicate copies" || bad "$DUP duplicate segment row(s)"
BVT="$(sqlite3 "$BRIC_TAPE_DB" "SELECT DISTINCT volumetag FROM segments WHERE run_id='$RUN' AND copy_role='BACKUP';")"
[ "$BVT" = "$(sqlite3 "$BRIC_TAPE_DB" "SELECT paired_volumetag FROM tapes WHERE volumetag='$PVT';")" ] \
    && ok "BACKUP landed on the partner tape of the SAME pair ($BVT)" || bad "BACKUP on wrong tape: $BVT"
# tape-file accounting: PRIMARY tape gained only the chunks written AFTER the crash + close artifacts,
# crucially NOT a second copy of the reused chunk. Cheap proxy: the reused file_number is still the
# highest chunk file ON ITS TAPE written for that chunk (no duplicate payload file with its sha).
SHA_REUSED="$(sqlite3 "$BRIC_TAPE_DB" "SELECT payload_sha256 FROM segments WHERE run_id='$RUN' AND copy_role='PRIMARY' AND file_number=$PFN AND volumetag='$PVT';")"
NDUP_PAYLOAD="$(sqlite3 "$BRIC_TAPE_DB" "SELECT COUNT(*) FROM segments WHERE volumetag='$PVT' AND payload_sha256='$SHA_REUSED';")"
[ "$NDUP_PAYLOAD" = 1 ] && ok "reused payload exists exactly once on $PVT (no orphan duplicate)" || bad "payload duplicated on $PVT ($NDUP_PAYLOAD rows)"

echo "=== data proves out: DR from tapes alone ==="
DR="$ROOT/dr"
"$REPO/cluster/scripts/bric-dr-from-tapes.sh" --tapelib "$BRIC_TAPELIB" --project crashy \
    --user-key-file "$UK" --dest "$DR" >"$ROOT/dr.log" 2>&1 || bad "DR failed"
diff -r "$SRC" "$DR" >/dev/null 2>&1 && ok "DR tree == source" || bad "DR tree differs"

echo
[ "$fail" -eq 0 ] && echo "✓ PARTIAL-PAIR RESUME CHECKS PASSED" || { echo "✗ PARTIAL-PAIR RESUME FAILURES"; exit 1; }
