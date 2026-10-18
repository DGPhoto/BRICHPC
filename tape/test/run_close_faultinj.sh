#!/bin/bash
. "$(cd "$(dirname "$(readlink -f "$0")")" && pwd)/lib_test_daemon.sh"
# Fault-injection on the project-close transitions. Drives close deterministically, crashes the
# daemon mid-way through appending the catalogs (a row left WRITING + a dead partial on tape), then
# resumes and verifies: close completes, every artifact is VERIFIED exactly once (no duplicate tape
# files), and the tapes are still fully disaster-recoverable.
set -euo pipefail
export BRIC_CONFIG=none   # hermetic: never read /etc/bric/bric.conf inside tests
REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
ROOT="$(mktemp -d)"; echo "workroot=$ROOT"

export BRIC_HOME="$REPO/cluster" BRIC_DB="$ROOT/c.db" BRIC_QNAP="$ROOT/qnap/bric"
export BRIC_KEYS="$ROOT/keys" BRIC_SQL_INIT="$REPO/cluster/sql/cluster_init.sql"
export BRIC_USER="vsz652" BRIC_RESERVE_TIMEOUT=60 BRIC_DRAIN_TIMEOUT=120 BRIC_CLOSE_TIMEOUT=120 BRIC_POLL=1
export BRIC_TAPE_HOME="$REPO/tape" BRIC_TAPE_DB="$ROOT/t.db" BRIC_TAPE_SQL_INIT="$REPO/tape/sql/tape_init.sql"
export BRIC_TAPE_BACKEND="sim" BRIC_TAPELIB="$ROOT/tapelib" BRIC_TAPE_LOCK="$ROOT/t.lock"
CL="$REPO/cluster/scripts"; DAEMON_BIN="$REPO/tape/bin/bric-tape-daemon"

mkdir -p "$BRIC_QNAP" "$BRIC_KEYS" "$BRIC_TAPELIB" "$(dirname "$BRIC_DB")"
chmod +x "$CL"/*.sh "$DAEMON_BIN" 2>/dev/null || true
sqlite3 "$BRIC_DB" < "$BRIC_SQL_INIT" >/dev/null
sqlite3 "$BRIC_TAPE_DB" < "$BRIC_TAPE_SQL_INIT" >/dev/null
sqlite3 "$BRIC_DB" "UPDATE config SET value='8388608' WHERE key='segment_target_bytes';"
sqlite3 "$BRIC_TAPE_DB" "UPDATE config SET value='1' WHERE key='poll_seconds';"
head -c 32 /dev/urandom | base64 > "$BRIC_KEYS/${BRIC_USER}_user_key.txt"
head -c 32 /dev/urandom | base64 > "$BRIC_KEYS/master.key"
cp "$BRIC_KEYS/${BRIC_USER}_user_key.txt" "$ROOT/userkey.txt"
sqlite3 "$BRIC_TAPE_DB" "INSERT INTO tapes(volumetag,slot,role,pair_number,paired_volumetag,capacity_tb,used_tb,status)
  VALUES('000001L9',1,'PRIMARY',1,'000002L9',18,0,'EMPTY'),('000002L9',2,'BACKUP',1,'000001L9',18,0,'EMPTY');"
SRC="$ROOT/data/proj"; mkdir -p "$SRC"
for i in 1 2 3; do dd if=/dev/urandom of="$SRC/f_$i.dat" bs=1M count=1 status=none; done

fail=0; chk(){ if [ "$2" = "$3" ]; then echo "  ok: $1 ($2)"; else echo "  FAIL: $1 expected=$3 got=$2"; fail=1; fi; }

# ---- produce phase (daemon loop drains chunks; finalize writes PROJECT_CLOSING) ----
setsid "$DAEMON_BIN" --loop & LOOP=$!
trap 'bric_test_stop_group "$LOOP"; [ -n "${KEEP:-}" ] || rm -rf "$ROOT"' EXIT
sleep 1
RUN="$("$CL/bric-plan.sh" --project proj --source "$SRC" 2>/dev/null)"
NCH="$(sqlite3 "$BRIC_DB" "SELECT n_chunks FROM runs WHERE run_id='$RUN';")"
for c in $(seq 1 "$NCH"); do "$CL/bric-chunk.sh" --run "$RUN" --chunk "$c" >/dev/null 2>&1; done
"$CL/bric-finalize.sh" --run "$RUN" >/dev/null 2>&1
bric_test_stop_group "$LOOP"

RD="$BRIC_QNAP/archive/proj/$RUN"
# publish placement, then let the cluster build+drop the catalogs (bric-close blocks until CLOSED)
"$DAEMON_BIN" --once >/dev/null 2>&1
"$CL/bric-close.sh" --run "$RUN" >/dev/null 2>&1 & CLOSER=$!
# wait until the catalogs are staged and CLOSE_CATALOGS is published
for _ in $(seq 1 60); do [ -e "$RD/run.CLOSE_CATALOGS" ] && break; sleep 1; done
chk "CLOSE_CATALOGS present" "$([ -e "$RD/run.CLOSE_CATALOGS" ] && echo yes || echo no)" "yes"

echo "=== inject crash during catalog append (after 3 physical appends) ==="
set +e
BRIC_FAULT_CLOSE_AFTER=3 "$DAEMON_BIN" --once >/dev/null 2>&1; CRASH_RC=$?
set -e
chk "fault pass exited nonzero (simulated crash)" "$([ "$CRASH_RC" -ne 0 ] && echo yes || echo no)" "yes"
WRIT="$(sqlite3 "$BRIC_TAPE_DB" "SELECT COUNT(*) FROM tape_artifacts WHERE state='WRITING';")"
chk "an interrupted artifact is left WRITING" "$([ "$WRIT" -ge 1 ] && echo yes || echo no)" "yes"
CLOSED_NOW="$([ -e "$RD/run.CLOSED" ] && echo yes || echo no)"
chk "run NOT yet CLOSED after crash" "$CLOSED_NOW" "no"
PHYS_BEFORE=$(find "$BRIC_TAPELIB/000001L9" -name 'f_*' | wc -l | tr -d ' ')

echo "=== resume (recover abandons WRITING, re-appends, completes) ==="
"$DAEMON_BIN" --once >/dev/null 2>&1   # recover() + finish; may need one more pass if 2nd tape pending
for _ in $(seq 1 5); do [ -e "$RD/run.CLOSED" ] && break; "$DAEMON_BIN" --once >/dev/null 2>&1; sleep 1; done
wait "$CLOSER" 2>/dev/null || true

chk "run CLOSED after resume" "$([ -e "$RD/run.CLOSED" ] && echo yes || echo no)" "yes"
chk "no artifact left WRITING" "$(sqlite3 "$BRIC_TAPE_DB" "SELECT COUNT(*) FROM tape_artifacts WHERE state='WRITING';")" "0"
# idempotency: exactly one VERIFIED artifact per (tape,filename); without escrow this test has 5 per tape (4 files + TOC)
DUP="$(sqlite3 "$BRIC_TAPE_DB" "SELECT COUNT(*) FROM (SELECT volumetag,filename FROM tape_artifacts WHERE state='VERIFIED' GROUP BY volumetag,filename HAVING COUNT(*)>1);")"
chk "no duplicate VERIFIED artifact" "$DUP" "0"
chk "VERIFIED artifacts on PRIMARY tape" "$(sqlite3 "$BRIC_TAPE_DB" "SELECT COUNT(*) FROM tape_artifacts WHERE volumetag='000001L9' AND state='VERIFIED';")" "5"
TRACKED=$(( $(sqlite3 "$BRIC_TAPE_DB" "SELECT COUNT(*) FROM segments WHERE volumetag='000001L9' AND state='VERIFIED';") + $(sqlite3 "$BRIC_TAPE_DB" "SELECT COUNT(*) FROM tape_artifacts WHERE volumetag='000001L9' AND state='VERIFIED';") ))
PHYS=$(find "$BRIC_TAPELIB/000001L9" -name 'f_*' | wc -l | tr -d ' ')
echo "  info: PRIMARY tape has $PHYS physical files, $TRACKED referenced; $((PHYS-TRACKED)) dead partial(s) from the crash, never referenced by the TOC (tolerated, append-only)"
chk "crash left >=1 unreferenced physical block on tape (orphan)" "$([ "$((PHYS-TRACKED))" -ge 1 ] && echo yes || echo no)" "yes"
# the TOC must reference ONLY VERIFIED records: no ABANDONED row may appear in any on-tape TOC
ABANDONED_REFD=$(sqlite3 "$BRIC_TAPE_DB" "SELECT COUNT(*) FROM tape_artifacts WHERE state='ABANDONED' AND file_number IS NOT NULL;")
chk "no ABANDONED artifact carries a referenced file_number" "$ABANDONED_REFD" "0"

echo "=== prove the tapes are still fully disaster-recoverable after crash+resume ==="
DR="$ROOT/recovered"
if "$CL/bric-dr-from-tapes.sh" --tapelib "$BRIC_TAPELIB" --project proj --user-key-file "$ROOT/userkey.txt" --dest "$DR" >/dev/null 2>&1 && diff -r "$SRC" "$DR" >/dev/null 2>&1; then
    echo "  ok: DR from tapes still reconstructs the project exactly"
else
    echo "  FAIL: DR after crash+resume did not match"; fail=1
fi

echo
[ "$fail" -eq 0 ] && echo "✓ CLOSE FAULT-INJECTION PASSED (idempotent, no duplicate appends, still recoverable)" || { echo "✗ FAILURES"; exit 1; }