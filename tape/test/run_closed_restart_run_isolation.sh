#!/bin/bash
# Review 32B4: CLOSED survives daemon restart with a stale ABORT marker, while an ABORT for another
# run of the same project remains fully effective. The durability fence is per run_id, never project-wide.
set -euo pipefail
export BRIC_CONFIG=none
REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
fail(){ echo "FAIL: $*" >&2; exit 1; }

export BRIC_TAPE_HOME="$REPO/tape"
export BRIC_TAPE_DB="$ROOT/tape.db"
export BRIC_TAPE_SQL_INIT="$REPO/tape/sql/tape_init.sql"
export BRIC_TAPE_BACKEND=sim
export BRIC_TAPELIB="$ROOT/tapelib"
export BRIC_TAPE_LOCK="$ROOT/tape.lock"
export BRIC_TAPE_WORK_LOCK="$ROOT/tape.work.lock"
export BRIC_QNAP="$ROOT/qnap/bric"
export BRIC_REQUIRE_LOGGING=0 BRIC_LOG_CAPTURE_STDIO=0
mkdir -p "$BRIC_QNAP/archive" "$BRIC_TAPELIB"
sqlite3 "$BRIC_TAPE_DB" < "$BRIC_TAPE_SQL_INIT" >/dev/null
sqlite3 "$BRIC_TAPE_DB" "UPDATE config SET value='1' WHERE key='require_bus_signing'; UPDATE config SET value='1' WHERE key='poll_seconds';" >/dev/null

openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$ROOT/cluster.pem" >/dev/null 2>&1
openssl pkey -in "$ROOT/cluster.pem" -pubout -out "$ROOT/cluster.pub" >/dev/null 2>&1
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$ROOT/tape.pem" >/dev/null 2>&1
export BRIC_BUS_SIGN_KEY="$ROOT/tape.pem" BRIC_BUS_VERIFY_KEY="$ROOT/cluster.pub"

sign_marker(){
    local rd="$1" name="$2" body="$3" in sig
    mkdir -p "$rd"; printf '%s' "$body" > "$rd/$name"
    in="$ROOT/in.$$.$RANDOM"; sig="$ROOT/sig.$$.$RANDOM"
    { printf 'BRIC-MARKER-V1\n%s/%s/%s\n' "$(basename "$(dirname "$rd")")" "$(basename "$rd")" "$name"; cat "$rd/$name"; } > "$in"
    openssl dgst -sha256 -sign "$ROOT/cluster.pem" -out "$sig" "$in" >/dev/null 2>&1
    openssl base64 -A -in "$sig" > "$rd/$name.sig"
    rm -f "$in" "$sig"
}

PROJECT=sameproject
CLOSED_RUN=sameproject__20260914T000000Z__0001
OPEN_RUN=sameproject__20260914T000001Z__0002
CRD="$BRIC_QNAP/archive/$PROJECT/$CLOSED_RUN"
ORD="$BRIC_QNAP/archive/$PROJECT/$OPEN_RUN"
mkdir -p "$CRD" "$ORD"

sqlite3 "$BRIC_TAPE_DB" <<SQL
INSERT INTO reservation(run_id,project_name,owner,requested_tb,pairs_csv,state) VALUES
('$CLOSED_RUN','$PROJECT','tester',0.001,'1','RELEASED'),
('$OPEN_RUN','$PROJECT','tester',0.001,'1','GRANTED');
INSERT INTO segments(seg_id,run_id,project_name,owner,chunk_no,copy_role,volumetag,file_number,payload_sha256,size_bytes,state) VALUES
('${CLOSED_RUN}__p','$CLOSED_RUN','$PROJECT','tester',1,'PRIMARY','000001L9',10,'abc',1,'VERIFIED'),
('${CLOSED_RUN}__b','$CLOSED_RUN','$PROJECT','tester',1,'BACKUP','000002L9',10,'abc',1,'VERIFIED'),
('${OPEN_RUN}__p','$OPEN_RUN','$PROJECT','tester',1,'PRIMARY','000001L9',11,'def',1,'VERIFIED'),
('${OPEN_RUN}__b','$OPEN_RUN','$PROJECT','tester',1,'BACKUP','000002L9',11,'def',1,'VERIFIED');
INSERT INTO audit_log(actor,action,object,result,detail)
VALUES('tape-daemon','CLOSED','$CLOSED_RUN','OK','durable close committed before crash');
SQL

sign_marker "$CRD" run.ABORTED "run_id=$CLOSED_RUN
project=$PROJECT
reason=stale abort surviving restart"
sign_marker "$ORD" run.ABORTED "run_id=$OPEN_RUN
project=$PROJECT
reason=legitimate abort of another run"

# First process lifetime: CLOSED is fenced, other run aborts normally.
"$REPO/tape/bin/bric-tape-daemon" --once >"$ROOT/pass1.log" 2>&1
[ "$(sqlite3 "$BRIC_TAPE_DB" "SELECT COUNT(*) FROM segments WHERE run_id='$CLOSED_RUN' AND state='VERIFIED';")" = 2 ] || fail "CLOSED run mutated on first pass"
[ "$(sqlite3 "$BRIC_TAPE_DB" "SELECT COUNT(*) FROM segments WHERE run_id='$OPEN_RUN' AND state='ABANDONED';")" = 2 ] || fail "other run in same project was not legitimately aborted"
[ -e "$ORD/run.ABORT_DONE" ] || fail "legitimate abort did not publish ABORT_DONE"
[ ! -e "$CRD/run.ABORT_DONE" ] || fail "stale CLOSED abort was acknowledged destructively"

# Simulated restart: stale CLOSED abort is still on the bus and must remain harmless after a new daemon
# process starts with no in-memory history of the previous pass.
"$REPO/tape/bin/bric-tape-daemon" --once >"$ROOT/pass2.log" 2>&1
[ "$(sqlite3 "$BRIC_TAPE_DB" "SELECT COUNT(*) FROM segments WHERE run_id='$CLOSED_RUN' AND state='VERIFIED';")" = 2 ] || fail "CLOSED run de-terminalized after daemon restart"
[ "$(sqlite3 "$BRIC_TAPE_DB" "SELECT state FROM reservation WHERE run_id='$CLOSED_RUN';")" = RELEASED ] || fail "CLOSED reservation changed after restart"
grep -q "IGNORED late ABORTED $CLOSED_RUN" "$ROOT/pass2.log" || fail "restart did not recognize durable CLOSED barrier"

echo "PASS run_closed_restart_run_isolation"
