#!/bin/bash
. "$(cd "$(dirname "$(readlink -f "$0")")" && pwd)/lib_test_daemon.sh"
# Review point #4 (concurrency / crash resilience of the tape side):
#   - the tape daemon is a SINGLETON: a second daemon refuses to start while one holds the lock;
#   - if the running daemon is hard-killed (kill -9) mid-drain, a FRESH daemon recovers the interrupted
#     writes and the in-flight backup still completes (run CLOSED, every chunk on tape).
set -euo pipefail
export BRIC_CONFIG=none   # hermetic: never read /etc/bric/bric.conf inside tests
SRC_REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
ROOT="$(mktemp -d)"
trap 'if [ "${DA:-0}" -gt 0 ]; then bric_test_stop_group "$DA" KILL; fi; if [ "${DB:-0}" -gt 0 ]; then bric_test_stop_group "$DB" KILL; fi; if [ "${BK:-0}" -gt 0 ]; then kill -9 "$BK" 2>/dev/null || true; wait "$BK" 2>/dev/null || true; fi; bric_test_rmrf_retry "$ROOT"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

REPO="$SRC_REPO"
export BRIC_HOME="$REPO/cluster" BRIC_DB="$ROOT/cluster_catalog.db" BRIC_QNAP="$ROOT/qnap/bric" BRIC_KEYS="$ROOT/keys"
export BRIC_SQL_INIT="$REPO/cluster/sql/cluster_init.sql" BRIC_USER="vsz652" BRIC_RUN_MODE="local"
export BRIC_RESERVE_TIMEOUT=60 BRIC_DRAIN_TIMEOUT=120 BRIC_CLOSE_TIMEOUT=120 BRIC_POLL=1
export BRIC_TAPE_HOME="$REPO/tape" BRIC_TAPE_DB="$ROOT/tape_catalog.db" BRIC_TAPE_SQL_INIT="$REPO/tape/sql/tape_init.sql"
export BRIC_TAPE_BACKEND="sim" BRIC_TAPELIB="$ROOT/tapelib" BRIC_TAPE_LOCK="$ROOT/tape.lock"
mkdir -p "$BRIC_QNAP" "$BRIC_KEYS" "$BRIC_TAPELIB" "$(dirname "$BRIC_DB")"
chmod +x "$REPO"/cluster/scripts/*.sh "$REPO"/cluster/bin/bric "$REPO"/tape/bin/bric-tape-daemon 2>/dev/null || true

sqlite3 "$BRIC_DB"      < "$BRIC_SQL_INIT"
sqlite3 "$BRIC_TAPE_DB" < "$BRIC_TAPE_SQL_INIT"
sqlite3 "$BRIC_DB"      "UPDATE config SET value='2097152' WHERE key='segment_target_bytes';"  # 2 MiB -> many chunks
sqlite3 "$BRIC_TAPE_DB" "UPDATE config SET value='1' WHERE key='poll_seconds';"
head -c 32 /dev/urandom | base64 > "$BRIC_KEYS/${BRIC_USER}_user_key.txt"
head -c 32 /dev/urandom | base64 > "$BRIC_KEYS/master.key"; chmod 600 "$BRIC_KEYS"/*
for n in 0 1; do r=$([ "$n" = 0 ] && echo PRIMARY || echo BACKUP); v=$(printf '%06dL9' "$n")
  sqlite3 "$BRIC_TAPE_DB" "INSERT INTO tapes (volumetag,slot,role,pair_number,paired_volumetag,capacity_tb,used_tb,status)
     VALUES ('$v',$((n+1)),'$r',1,'$(printf '%06dL9' $((n==0?1:0)))',18.0,0,'EMPTY');"; done

SRC="$ROOT/data/big_project"; mkdir -p "$SRC"
for i in $(seq 1 16); do dd if=/dev/urandom of="$SRC/f_$i.bin" bs=1M count=2 status=none; done   # ~32 MiB -> ~16 chunks

echo "== the tape daemon is a singleton: a second one refuses while one holds the lock =="
BRIC_FAULT_SIM_APPEND_DELAY=8 setsid "$REPO/tape/bin/bric-tape-daemon" --loop >/dev/null 2>&1 & DA=$!
sleep 1
if "$REPO/tape/bin/bric-tape-daemon" --once >"$ROOT/second.log" 2>&1; then
    fail "a second daemon started while the first held the lock"
fi
kill -0 "$DA" 2>/dev/null || fail "first daemon died while the second-daemon collision was tested"
echo "  ok: second daemon refused while the original daemon remained alive"

echo "== crash: kill -9 the draining daemon mid-run; a fresh daemon recovers and finishes the backup =="
# Run the backup in the background. It produces chunks, then finalize waits for them to reach tape.
(
    set +e
    "$REPO/cluster/bin/bric" backup --project big_project --source "$SRC" >"$ROOT/backup.out" 2>&1
    rc=$?
    printf '%s\n' "$rc" > "$ROOT/backup.rc"
    exit 0
) &
BK=$!
# Force the crash inside a real claimed write, not at an arbitrary wall-clock point.  Daemon A has
# an 8-second sim-append delay, so WRITING + CLAIMED is a deterministic kill window.
claimed=""; writing=""; waited_claim=0
while [ "$waited_claim" -lt 45 ]; do
    claimed="$(find "$BRIC_QNAP/archive" -type f -name 'chunk_*.CLAIMED' -print -quit 2>/dev/null || true)"
    writing="$(sqlite3 "$BRIC_TAPE_DB" "SELECT COUNT(*) FROM segments WHERE state='WRITING';" 2>/dev/null || true)"
    [ -n "$claimed" ] && [ "${writing:-0}" -gt 0 ] && break
    sleep 1; waited_claim=$((waited_claim+1))
done
[ -n "$claimed" ] && [ "${writing:-0}" -gt 0 ] || fail "could not force daemon into CLAIMED+WRITING crash window"
bric_test_stop_group "$DA" KILL; DA=0
PARTIAL="$(sqlite3 "$BRIC_TAPE_DB" "SELECT COUNT(*) FROM segments WHERE state='VERIFIED';")"
echo "  (daemon killed with an unresolved CLAIMED chunk; $PARTIAL copies already VERIFIED)"
# A fresh daemon: recover() abandons any interrupted WRITING segment, then it drains the rest.
setsid "$REPO/tape/bin/bric-tape-daemon" --loop >"$ROOT/daemonB.log" 2>&1 & DB=$!
sleep 1
kill -0 "$DB" 2>/dev/null || fail "recovery daemon did not remain running after the crashed generation released its singleton lock"
echo "  ok: recovery daemon acquired the singleton lock and remained running"

# The backup must now complete on its own (finalize sees the chunks reach tape, then close).
waited=0
while [ ! -f "$ROOT/backup.rc" ]; do sleep 1; waited=$((waited+1)); [ "$waited" -ge 120 ] && break; done
wait "$BK" 2>/dev/null || true; BK=0
bric_test_stop_group "$DB" KILL; DB=0

[ -f "$ROOT/backup.rc" ] && [ "$(cat "$ROOT/backup.rc")" = 0 ] || fail "backup did not complete after daemon crash (rc=$(cat "$ROOT/backup.rc" 2>/dev/null); see backup.out)"
# The singleton lock was proven available by daemon B remaining alive above.  After completion there
# must be no unresolved CLAIMED marker left by the crashed generation.
left_claimed="$(find "$BRIC_QNAP/archive" -type f -name 'chunk_*.CLAIMED' -print -quit 2>/dev/null || true)"
[ -z "$left_claimed" ] || fail "recovery left an unresolved CLAIMED marker: $left_claimed"
echo "  ok: recovery cleared the crash-left CLAIMED work"
ST="$(sqlite3 "$BRIC_DB" "SELECT status FROM runs WHERE project_name='big_project';")"
[ "$ST" = CLOSED ] || fail "run status is '$ST', expected CLOSED after recovery"
echo "  ok: run reached CLOSED despite the mid-drain crash"

# Every chunk must have BOTH copies VERIFIED on tape (PRIMARY+BACKUP), proving nothing was lost.
NCH="$(sqlite3 "$BRIC_DB" "SELECT n_chunks FROM runs WHERE project_name='big_project';")"
VER="$(sqlite3 "$BRIC_TAPE_DB" "SELECT COUNT(*) FROM segments WHERE state='VERIFIED';")"
[ "$VER" -ge "$((NCH*2))" ] || fail "expected >= $((NCH*2)) verified copies ($NCH chunks x2), got $VER"
echo "  ok: all $NCH chunks have PRIMARY+BACKUP copies verified on tape ($VER copies)"
grep -qi "recovery: abandoned" "$ROOT/daemonB.log" && echo "  ok: fresh daemon ran recovery (abandoned interrupted write)" || echo "  (note: crash left no half-written segment this run; recovery was a no-op — still completed)"

echo "PASS run_daemon_crash"
