#!/bin/bash
. "$(cd "$(dirname "$(readlink -f "$0")")" && pwd)/lib_test_daemon.sh"
# Review 32B1: hermetic multi-pair transition + reserve extension + multi-tape close replication.
# This does NOT replace the physical LTO smoke; it proves the software contract before hardware use.
set -euo pipefail
export BRIC_CONFIG=none BRIC_KEEP_TERMINAL_BUS=1 BRIC_KEEP_RESTORE_BUS=1
REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
ROOT="$(mktemp -d)"; echo "workroot=$ROOT"
fail=0; ok(){ echo "  ok: $*"; }; bad(){ echo "  FAIL: $*"; fail=1; }
export BRIC_HOME="$REPO/cluster" BRIC_DB="$ROOT/cluster.db" BRIC_QNAP="$ROOT/qnap/bric" BRIC_KEYS="$ROOT/keys" BRIC_SQL_INIT="$REPO/cluster/sql/cluster_init.sql"
export BRIC_USER=vsz652 BRIC_RUN_MODE=local BRIC_POLL=1 BRIC_RESERVE_TIMEOUT=60 BRIC_DRAIN_TIMEOUT=120 BRIC_CLOSE_TIMEOUT=120 BRIC_RESTORE_TIMEOUT=90
export BRIC_STREAM_PARALLEL_WORKERS=4 BRIC_STREAM_WORKER_CHUNK_BYTES=4194304 BRIC_STREAM_INITIAL_RESERVATION_BYTES=4194304
export BRIC_TAPE_HOME="$REPO/tape" BRIC_TAPE_DB="$ROOT/tape.db" BRIC_TAPE_SQL_INIT="$REPO/tape/sql/tape_init.sql" BRIC_TAPE_BACKEND=sim BRIC_TAPELIB="$ROOT/tapelib" BRIC_TAPE_LOCK="$ROOT/tape.lock"
export BRIC_RESTORE_PROGRESS_INTERVAL=1 BRIC_RESTORE_CONSUME_TIMEOUT=60
mkdir -p "$BRIC_QNAP" "$BRIC_KEYS" "$BRIC_TAPELIB"
sqlite3 "$BRIC_DB" < "$BRIC_SQL_INIT" >/dev/null
sqlite3 "$BRIC_TAPE_DB" < "$BRIC_TAPE_SQL_INIT" >/dev/null
sqlite3 "$BRIC_DB" "UPDATE config SET value='4194304' WHERE key='segment_target_bytes'; UPDATE config SET value='4' WHERE key='stream_parallel_workers'; UPDATE config SET value='4194304' WHERE key='stream_worker_chunk_bytes';"
sqlite3 "$BRIC_TAPE_DB" "UPDATE config SET value='0' WHERE key='tape_headroom_tb'; UPDATE config SET value='4194304' WHERE key='chunk_target_bytes'; UPDATE config SET value='1' WHERE key='poll_seconds';"
head -c 32 /dev/urandom | base64 > "$BRIC_KEYS/${BRIC_USER}_user_key.txt"; head -c 32 /dev/urandom | base64 > "$BRIC_KEYS/master.key"
# Pair 1 holds only ~12 MB; pair 2 has ample test capacity. The explicit 4 MiB initial reservation
# pins pair 1 first, then the stream gate must extend when required_total crosses that capacity.
sqlite3 "$BRIC_TAPE_DB" "INSERT INTO tapes(volumetag,slot,role,pair_number,paired_volumetag,capacity_tb,used_tb,status,health) VALUES
 ('000101L9',1,'PRIMARY',1,'000102L9',0.0000120,0,'EMPTY','OK'),('000102L9',2,'BACKUP',1,'000101L9',0.0000120,0,'EMPTY','OK'),
 ('000103L9',3,'PRIMARY',2,'000104L9',0.0000500,0,'EMPTY','OK'),('000104L9',4,'BACKUP',2,'000103L9',0.0000500,0,'EMPTY','OK');"
SRC="$ROOT/src"; mkdir -p "$SRC"
for i in 1 2 3 4 5 6; do dd if=/dev/urandom of="$SRC/f$i.bin" bs=1M count=4 status=none; done
setsid "$REPO/tape/bin/bric-tape-daemon" --loop >"$ROOT/daemon.log" 2>&1 & DAEMON=$!
trap 'bric_test_stop_group "$DAEMON"; [ -n "${KEEP:-}" ] || { rm -rf "$ROOT" 2>/dev/null || { sleep 1; rm -rf "$ROOT"; }; }' EXIT
sleep 1
RUN="$("$REPO/cluster/bin/bric" backup --project multipair --source "$SRC")"
STATUS="$(sqlite3 "$BRIC_DB" "SELECT status FROM runs WHERE run_id='$RUN';")"
[ "$STATUS" = CLOSED ] && ok "run CLOSED across pair transition" || { bad "run status=$STATUS"; tail -40 "$ROOT/daemon.log"; }
RDIR="$BRIC_QNAP/archive/multipair/$RUN"
[ -f "$RDIR/run.RESERVE_EXTENDED" ] && ok "run.RESERVE_EXTENDED published" || bad "reservation extension marker missing"
grep -q '^pairs=2$' "$RDIR/run.RESERVE_EXTENDED" 2>/dev/null && ok "reservation expanded to two pairs" || bad "extension did not report pairs=2"
PAIRS="$(sqlite3 "$BRIC_TAPE_DB" "SELECT COUNT(DISTINCT t.pair_number) FROM segments s JOIN tapes t ON t.volumetag=s.volumetag WHERE s.run_id='$RUN' AND s.copy_role='PRIMARY' AND s.state='VERIFIED';")"
[ "$PAIRS" -ge 2 ] && ok "VERIFIED chunks span $PAIRS tape pairs" || bad "chunks did not transition pairs ($PAIRS)"
FIRST="$(sqlite3 "$BRIC_TAPE_DB" "SELECT t.pair_number FROM segments s JOIN tapes t ON t.volumetag=s.volumetag WHERE s.run_id='$RUN' AND s.copy_role='PRIMARY' AND s.state='VERIFIED' ORDER BY s.chunk_no LIMIT 1;")"
LAST="$(sqlite3 "$BRIC_TAPE_DB" "SELECT t.pair_number FROM segments s JOIN tapes t ON t.volumetag=s.volumetag WHERE s.run_id='$RUN' AND s.copy_role='PRIMARY' AND s.state='VERIFIED' ORDER BY s.chunk_no DESC LIMIT 1;")"
[ "$FIRST" != "$LAST" ] && ok "placement transitioned pair $FIRST -> pair $LAST" || bad "first/last chunk stayed on pair $FIRST"
CATS="$(sqlite3 "$BRIC_TAPE_DB" "SELECT COUNT(*) FROM tape_artifacts WHERE run_id='$RUN' AND filename='catalog_project.enc' AND state='VERIFIED';")"
TOCS="$(sqlite3 "$BRIC_TAPE_DB" "SELECT COUNT(*) FROM tape_artifacts WHERE run_id='$RUN' AND filename='TAPE_TOC.txt' AND state='VERIFIED';")"
[ "$CATS" = 4 ] && ok "catalog_project.enc VERIFIED on all four cartridges" || bad "catalog copies=$CATS expected=4"
[ "$TOCS" = 4 ] && ok "final TOC VERIFIED on all four cartridges" || bad "TOC copies=$TOCS expected=4"
DEST="$ROOT/restore"
if "$REPO/cluster/scripts/bric-restore.sh" --project multipair --dest "$DEST" >"$ROOT/restore.log" 2>&1 && diff -r "$SRC" "$DEST" >/dev/null 2>&1; then
  ok "whole restore across both pairs is exact"
else bad "multi-pair restore failed"; tail -30 "$ROOT/restore.log" || true; fi

echo
[ "$fail" -eq 0 ] && echo "✓ MULTI-PAIR TRANSITION CHECKS PASSED" || { echo "✗ MULTI-PAIR TRANSITION FAILURES"; exit 1; }
