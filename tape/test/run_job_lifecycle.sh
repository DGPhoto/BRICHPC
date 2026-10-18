#!/bin/bash
. "$(cd "$(dirname "$(readlink -f "$0")")" && pwd)/lib_test_daemon.sh"
# Job-lifecycle hardening (cluster review point b):
#  A) requeue idempotency — a re-published READY for an already-VERIFIED chunk must NOT write a
#     duplicate segment to the append-only tape; the daemon just re-emits DONE.
#  B) failure handling — a run with chunks that never reached tape (dead producer tasks) is marked
#     FAILED by finalize, which signals run.ABORTED; the daemon releases the reservation, orphans any
#     partials and acks run.ABORT_DONE (no run left stuck in PRODUCING, no leaked reservation).
set -euo pipefail
export BRIC_CONFIG=none   # hermetic: never read /etc/bric/bric.conf inside tests
REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"; ROOT="$(mktemp -d)"; echo "workroot=$ROOT"
export BRIC_HOME="$REPO/cluster" BRIC_DB="$ROOT/cluster_catalog.db" BRIC_QNAP="$ROOT/qnap/bric"
export BRIC_KEYS="$ROOT/keys" BRIC_RUNSTATE="$ROOT/runstate" BRIC_SQL_INIT="$REPO/cluster/sql/cluster_init.sql"
export BRIC_USER="vsz652" BRIC_RUN_MODE="local" BRIC_RESERVE_TIMEOUT=60 BRIC_DRAIN_TIMEOUT=60 BRIC_POLL=1
export BRIC_TAPE_HOME="$REPO/tape" BRIC_TAPE_DB="$ROOT/tape_catalog.db" BRIC_TAPE_SQL_INIT="$REPO/tape/sql/tape_init.sql"
export BRIC_TAPE_BACKEND="sim" BRIC_TAPELIB="$ROOT/tapelib" BRIC_TAPE_LOCK="$ROOT/tape.lock"
mkdir -p "$BRIC_QNAP" "$BRIC_KEYS" "$BRIC_TAPELIB" "$(dirname "$BRIC_DB")"
chmod +x "$REPO"/cluster/scripts/*.sh "$REPO"/cluster/bin/bric "$REPO"/tape/bin/bric-tape-daemon 2>/dev/null || true
sqlite3 "$BRIC_DB" < "$BRIC_SQL_INIT" >/dev/null
sqlite3 "$BRIC_TAPE_DB" < "$BRIC_TAPE_SQL_INIT" >/dev/null
sqlite3 "$BRIC_DB" "UPDATE config SET value='5242880' WHERE key='segment_target_bytes';"
sqlite3 "$BRIC_TAPE_DB" "UPDATE config SET value='1' WHERE key='poll_seconds';"
head -c 32 /dev/urandom | base64 > "$BRIC_KEYS/${BRIC_USER}_user_key.txt"
head -c 32 /dev/urandom | base64 > "$BRIC_KEYS/master.key"; chmod 600 "$BRIC_KEYS"/*
pair=1; for n in 1 3 5 7; do p=$(printf '%06dL9' "$n"); b=$(printf '%06dL9' "$((n+1))")
  sqlite3 "$BRIC_TAPE_DB" "INSERT INTO tapes (volumetag,slot,role,pair_number,paired_volumetag,capacity_tb,used_tb,status) VALUES ('$p',$n,'PRIMARY',$pair,'$b',18.0,0,'EMPTY'),('$b',$((n+1)),'BACKUP',$pair,'$p',18.0,0,'EMPTY');"; pair=$((pair+1)); done
fail=0; ok(){ echo "  ok: $1"; }; bad(){ echo "  FAIL: $1"; fail=1; }

DLOG="$ROOT/daemon.log"
setsid "$REPO/tape/bin/bric-tape-daemon" --loop >"$DLOG" 2>&1 & DAEMON=$!
trap 'bric_test_stop_group "$DAEMON"; [ -n "${KEEP:-}" ] || { rm -rf "$ROOT" 2>/dev/null || { sleep 1; rm -rf "$ROOT"; }; }' EXIT
sleep 1

echo "=== A: requeue idempotency (no duplicate segment) ==="
SRC="$ROOT/data/genome"; mkdir -p "$SRC/raw"; for i in 1 2; do dd if=/dev/urandom of="$SRC/raw/r_$i.fastq" bs=1K count=600 status=none; done
RUN_ID="$("$REPO/cluster/bin/bric" backup --project genome --source "$SRC")"
[ "$(sqlite3 "$BRIC_DB" "SELECT status FROM runs WHERE run_id='$RUN_ID';")" = CLOSED ] && ok "baseline run CLOSED" || bad "baseline run not closed"
RD="$BRIC_QNAP/archive/genome/$RUN_ID"
SEG_BEFORE=$(sqlite3 "$BRIC_TAPE_DB" "SELECT COUNT(*) FROM segments WHERE run_id='$RUN_ID' AND chunk_no=1;")
# re-publish a READY+meta for chunk 1 (already VERIFIED) as a SLURM requeue would
printf 'run_id=%s\nproject=genome\nowner=%s\nchunk_no=1\ntype=TAR_PART\nsize_bytes=1\npayload_sha256=deadbeef\n' "$RUN_ID" "$BRIC_USER" > "$RD/chunk_0001.meta"
printf 'sha256=deadbeef\nsize_bytes=1\n' > "$RD/chunk_0001.READY"
sleep 4
SEG_AFTER=$(sqlite3 "$BRIC_TAPE_DB" "SELECT COUNT(*) FROM segments WHERE run_id='$RUN_ID' AND chunk_no=1;")
[ "$SEG_AFTER" = "$SEG_BEFORE" ] && ok "no duplicate segment written for re-published chunk ($SEG_AFTER == $SEG_BEFORE)" || bad "duplicate segment! $SEG_BEFORE -> $SEG_AFTER"
grep -qi "already VERIFIED on tape — re-published DONE" "$DLOG" && ok "daemon re-emitted DONE idempotently" || bad "no idempotent re-DONE log"
# the bric-chunk guard itself: re-running an already-DONE chunk exits 0 without work
if "$REPO/cluster/scripts/bric-chunk.sh" --run "$RUN_ID" --chunk 1 >"$ROOT/rechunk.log" 2>&1; then
  grep -qi "already DONE" "$ROOT/rechunk.log" && ok "bric-chunk skips an already-DONE chunk (requeue-safe)" || bad "bric-chunk did not short-circuit a DONE chunk"
else bad "re-running bric-chunk on a DONE chunk exited nonzero"; fi

echo "=== B: failure -> run FAILED + reservation released + ABORT_DONE ==="
SRC2="$ROOT/data/abortme"; mkdir -p "$SRC2"; for i in 1 2 3; do dd if=/dev/urandom of="$SRC2/f_$i.dat" bs=1K count=600 status=none; done
RID2="$("$REPO/cluster/scripts/bric-plan.sh" --project abortme --source "$SRC2")"
[ -n "$RID2" ] && ok "planned run $([ -n "$RID2" ] && echo ok)" || bad "plan failed"
RESV_BEFORE=$(sqlite3 "$BRIC_TAPE_DB" "SELECT state FROM reservation WHERE run_id='$RID2';")
[ "$RESV_BEFORE" = GRANTED ] && ok "tapes reserved for the run (state GRANTED)" || bad "reservation not granted ($RESV_BEFORE)"
# do NOT produce any chunk (simulate all producer tasks dying); finalize must abort
"$REPO/cluster/scripts/bric-finalize.sh" --run "$RID2" >"$ROOT/fin.log" 2>&1 || true
[ "$(sqlite3 "$BRIC_DB" "SELECT status FROM runs WHERE run_id='$RID2';")" = FAILED ] && ok "finalize marked the run FAILED" || bad "run not marked FAILED"
[ -f "$BRIC_QNAP/archive/abortme/$RID2/run.ABORTED" ] && ok "finalize published run.ABORTED" || bad "no run.ABORTED published"
sleep 4
RESV_AFTER=$(sqlite3 "$BRIC_TAPE_DB" "SELECT state FROM reservation WHERE run_id='$RID2';")
[ "$RESV_AFTER" = RELEASED ] && ok "tape server released the reservation" || bad "reservation not released ($RESV_AFTER)"
[ -f "$BRIC_QNAP/archive/abortme/$RID2/run.ABORT_DONE" ] && ok "tape server acked run.ABORT_DONE" || bad "no run.ABORT_DONE ack"
grep -qi "ABORTED $RID2" "$DLOG" && ok "daemon logged the abort cleanup" || bad "no abort cleanup log"

echo
[ "$fail" -eq 0 ] && echo "✓ JOB-LIFECYCLE CHECKS PASSED" || { echo "✗ FAILURES"; exit 1; }
