#!/bin/bash
. "$(cd "$(dirname "$(readlink -f "$0")")" && pwd)/lib_test_daemon.sh"
# Full virtual backup+restore with a real logical user and parallel PRIMARY/BACKUP copies.
# The deterministic append delay + trace proves both workers start before either finishes.
set -euo pipefail
export BRIC_CONFIG=none
REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
ROOT="$(mktemp -d)"
export BRIC_LOG_DIR="$ROOT/log-primary" BRIC_LOG_FALLBACK_DIR="$ROOT/log-fallback" BRIC_REQUIRE_LOGGING=1; DA=0
trap '[ "$DA" -gt 0 ] && { bric_test_stop_group "$DA" KILL; } || true; rm -rf "$ROOT"' EXIT
fail(){ echo "FAIL: $*" >&2; exit 1; }
export BRIC_ROLE=slurm
export BRIC_HOME="$REPO/cluster" BRIC_DB="$ROOT/cluster.db" BRIC_QNAP="$ROOT/qnap/bric" BRIC_KEYS="$ROOT/keys"
export BRIC_SQL_INIT="$REPO/cluster/sql/cluster_init.sql" BRIC_USER="${BRIC_ACCEPTANCE_USER:-vsz652}" BRIC_RUN_MODE=local
export BRIC_RESERVE_TIMEOUT=60 BRIC_DRAIN_TIMEOUT=120 BRIC_CLOSE_TIMEOUT=120 BRIC_RESTORE_TIMEOUT=120 BRIC_POLL=1
export BRIC_TAPE_HOME="$REPO/tape" BRIC_TAPE_DB="$ROOT/tape.db" BRIC_TAPE_SQL_INIT="$REPO/tape/sql/tape_init.sql"
export BRIC_TAPE_BACKEND=sim BRIC_TAPELIB="$ROOT/tapelib" BRIC_TAPE_LOCK="$ROOT/tape.lock" BRIC_TAPE_WORK_LOCK="$ROOT/tape.work"
export BRIC_TAPE_DRIVES="0 1" BRIC_PARALLEL_DRIVES=2 BRIC_PARALLEL_TRACE="$ROOT/parallel.trace"
export BRIC_FAULT_SIM_APPEND_DELAY_0=1 BRIC_FAULT_SIM_APPEND_DELAY_1=3
mkdir -p "$BRIC_QNAP" "$BRIC_KEYS" "$BRIC_TAPELIB"
sqlite3 "$BRIC_DB" < "$BRIC_SQL_INIT" >/dev/null
sqlite3 "$BRIC_TAPE_DB" < "$BRIC_TAPE_SQL_INIT" >/dev/null
sqlite3 "$BRIC_DB" "UPDATE config SET value='8388608' WHERE key='segment_target_bytes';"
sqlite3 "$BRIC_TAPE_DB" "UPDATE config SET value='1' WHERE key='poll_seconds'; UPDATE config SET value='2' WHERE key='parallel_drives';"
if [ -n "${BRIC_ACCEPTANCE_KEY_FILE:-}" ]; then
    [ -r "$BRIC_ACCEPTANCE_KEY_FILE" ] && [ -s "$BRIC_ACCEPTANCE_KEY_FILE" ] || { echo "FAIL: BRIC_ACCEPTANCE_KEY_FILE is missing/empty/unreadable: $BRIC_ACCEPTANCE_KEY_FILE" >&2; exit 1; }
    [ "$(wc -l < "$BRIC_ACCEPTANCE_KEY_FILE" | tr -d ' ')" -le 1 ] || { echo "FAIL: acceptance user key must be one line" >&2; exit 1; }
    cp -f "$BRIC_ACCEPTANCE_KEY_FILE" "$BRIC_KEYS/${BRIC_USER}_user_key.txt"
    echo "  using supplied acceptance key for logical user $BRIC_USER"
else
    head -c 32 /dev/urandom | base64 > "$BRIC_KEYS/${BRIC_USER}_user_key.txt"
    echo "  using generated disposable key for logical user $BRIC_USER"
fi
head -c 32 /dev/urandom | base64 > "$BRIC_KEYS/master.key"
chmod 600 "$BRIC_KEYS"/*
sqlite3 "$BRIC_TAPE_DB" "INSERT INTO tapes(volumetag,slot,role,pair_number,paired_volumetag,capacity_tb,used_tb,status)
 VALUES('000000L9',1,'PRIMARY',1,'000001L9',18,0,'EMPTY'),('000001L9',2,'BACKUP',1,'000000L9',18,0,'EMPTY');"
SRC="$ROOT/source"; mkdir -p "$SRC/sub"; dd if=/dev/urandom of="$SRC/sub/payload.bin" bs=1M count=1 status=none
# The tape daemon is a tape-role process even though this hermetic test shares one host.
BRIC_ROLE=tape setsid "$REPO/tape/bin/bric-tape-daemon" --loop >"$ROOT/daemon.log" 2>&1 & DA=$!
RUN="$(BRIC_ROLE=slurm "$REPO/cluster/bin/bric" backup --project parallel_vtl_user --source "$SRC")"
[ "$(sqlite3 "$BRIC_DB" "SELECT status FROM runs WHERE run_id='$RUN';")" = CLOSED ] || fail "run not CLOSED"
NCH="$(sqlite3 "$BRIC_DB" "SELECT n_chunks FROM runs WHERE run_id='$RUN';")"
[[ "$NCH" =~ ^[1-9][0-9]*$ ]] || fail "invalid planned n_chunks for run $RUN: '$NCH'"
VER="$(sqlite3 "$BRIC_TAPE_DB" "SELECT COUNT(*) FROM segments WHERE run_id='$RUN' AND state='VERIFIED';")"
EXP=$((NCH * 2))
[ "$VER" = "$EXP" ] || fail "expected $EXP VERIFIED segments (2 copies x $NCH chunks), got $VER"
BAD_PAIRS="$(sqlite3 "$BRIC_TAPE_DB" "
  SELECT COUNT(*) FROM (
    SELECT chunk_no,
           SUM(CASE WHEN copy_role='PRIMARY' AND state='VERIFIED' THEN 1 ELSE 0 END) AS p,
           SUM(CASE WHEN copy_role='BACKUP'  AND state='VERIFIED' THEN 1 ELSE 0 END) AS b
    FROM segments WHERE run_id='$RUN'
    GROUP BY chunk_no
    HAVING p<>1 OR b<>1
  );")"
[ "$BAD_PAIRS" = 0 ] || fail "$BAD_PAIRS chunk(s) lack exactly one VERIFIED PRIMARY and one VERIFIED BACKUP"
[ "$(sqlite3 "$BRIC_TAPE_DB" "SELECT COUNT(DISTINCT chunk_no) FROM segments WHERE run_id='$RUN' AND state='VERIFIED';")" = "$NCH" ] \
  || fail "not every planned chunk has a VERIFIED pair"
mapfile -t ev < "$BRIC_PARALLEL_TRACE"
[ "${ev[0]%%|*}" = start ] && [ "${ev[1]%%|*}" = start ] || { printf '%s\n' "${ev[@]}" >&2; fail "copies did not overlap"; }
end0="$(awk -F'|' '$1=="end" && $3=="0"{print $5; exit}' "$BRIC_PARALLEL_TRACE")"
end1="$(awk -F'|' '$1=="end" && $3=="1"{print $5; exit}' "$BRIC_PARALLEL_TRACE")"
[ -n "$end0" ] && [ -n "$end1" ] && [ "$end1" -gt "$end0" ] || { cat "$BRIC_PARALLEL_TRACE" >&2; fail "the slower drive was not independently awaited"; }
grep -q 'streamed concurrently on drives 0/1' "$ROOT/daemon.log" || fail "daemon did not report dual-drive path"
find "$BRIC_LOG_DIR" "$BRIC_LOG_FALLBACK_DIR" -type f -name '*.events.v1.log' -exec grep -h 'PARALLEL_COPY_BARRIER_END' {} + | grep -q 'primary_rc=0 backup_rc=0' \
  || fail "parallel completion barrier was not logged"
DEST="$ROOT/restore"
BRIC_ROLE=slurm "$REPO/cluster/bin/bric" restore --project parallel_vtl_user --run "$RUN" --dest "$DEST" >/dev/null
cmp -s "$SRC/sub/payload.bin" "$DEST/sub/payload.bin" || fail "restored file differs"
echo "  ok: logical user=$BRIC_USER; drive 0 finished first, drive 1 was awaited; restore matched"
echo "PASS run_parallel_drives"
