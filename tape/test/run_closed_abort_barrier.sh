#!/bin/bash
# Review 32B3: a durable tape-side CLOSED commit is irreversible. A late, valid cluster ABORTED
# marker must not orphan VERIFIED segments, mutate the RELEASED reservation, or publish ABORT_DONE.
set -euo pipefail
export BRIC_CONFIG=none
REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
fail(){ echo "FAIL: $*" >&2; exit 1; }

export BRIC_TAPE_HOME="$REPO/tape"
export BRIC_TAPE_DB="$ROOT/tape.db"
export BRIC_TAPE_SQL_INIT="$REPO/tape/sql/tape_init.sql"
export BRIC_TAPE_BACKEND=sim
export BRIC_TAPELIB="$ROOT/tapelib"
export BRIC_TAPE_LOCK="$ROOT/tape.lock"
export BRIC_TAPE_WORK_LOCK="$ROOT/tape.work.lock"
export BRIC_QNAP="$ROOT/qnap/bric"
export BRIC_REQUIRE_LOGGING=0
export BRIC_LOG_CAPTURE_STDIO=0
mkdir -p "$BRIC_QNAP/archive" "$BRIC_TAPELIB"
sqlite3 "$BRIC_TAPE_DB" < "$BRIC_TAPE_SQL_INIT" >/dev/null
sqlite3 "$BRIC_TAPE_DB" "UPDATE config SET value='1' WHERE key='require_bus_signing'; UPDATE config SET value='1' WHERE key='poll_seconds';" >/dev/null

openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$ROOT/cluster.pem" >/dev/null 2>&1
openssl pkey -in "$ROOT/cluster.pem" -pubout -out "$ROOT/cluster.pub" >/dev/null 2>&1
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$ROOT/tape.pem" >/dev/null 2>&1
export BRIC_BUS_SIGN_KEY="$ROOT/tape.pem"
export BRIC_BUS_VERIFY_KEY="$ROOT/cluster.pub"

sign_cluster_marker(){ # dir name body
    local rd="$1" name="$2" body="$3" in sig
    mkdir -p "$rd"
    printf '%s' "$body" >"$rd/$name"
    in="$ROOT/sign.$$.$RANDOM"; sig="$ROOT/sig.$$.$RANDOM"
    {
        printf 'BRIC-MARKER-V1\n%s/%s/%s\n' "$(basename "$(dirname "$rd")")" "$(basename "$rd")" "$name"
        cat "$rd/$name"
    } >"$in"
    openssl dgst -sha256 -sign "$ROOT/cluster.pem" -out "$sig" "$in" >/dev/null 2>&1
    openssl base64 -A -in "$sig" >"$rd/$name.sig"
    rm -f "$in" "$sig"
}

RUN=closedlateabort__20260914T000000Z__0001
PROJECT=closedlateabort
RD="$BRIC_QNAP/archive/$PROJECT/$RUN"
mkdir -p "$RD"

sqlite3 "$BRIC_TAPE_DB" <<SQL
INSERT INTO reservation(run_id,project_name,owner,requested_tb,pairs_csv,state)
VALUES('$RUN','$PROJECT','tester',0.001,'1','RELEASED');
INSERT INTO segments(seg_id,run_id,project_name,owner,chunk_no,copy_role,volumetag,file_number,payload_sha256,size_bytes,state)
VALUES
('${RUN}__c1__PRIMARY','$RUN','$PROJECT','tester',1,'PRIMARY','000001L9',10,'abc',4194304,'VERIFIED'),
('${RUN}__c1__BACKUP','$RUN','$PROJECT','tester',1,'BACKUP','000002L9',10,'abc',4194304,'VERIFIED');
INSERT INTO audit_log(actor,action,object,result,detail)
VALUES('tape-daemon','CLOSED','$RUN','OK','durable close committed before receipt publication');
SQL

# Exact race seen on hardware: the cluster publishes a valid ABORT after the tape daemon has already
# committed CLOSED. The bus marker is authentic, but it is stale relative to the local durability barrier.
sign_cluster_marker "$RD" run.ABORTED "run_id=$RUN
project=$PROJECT
reason=late cluster interruption"

"$REPO/tape/bin/bric-tape-daemon" --once >"$ROOT/daemon.log" 2>&1

[ "$(sqlite3 "$BRIC_TAPE_DB" "SELECT COUNT(*) FROM segments WHERE run_id='$RUN' AND state='VERIFIED';")" = 2 ] \
    || fail "late ABORT de-terminalized VERIFIED segments"
[ "$(sqlite3 "$BRIC_TAPE_DB" "SELECT state FROM reservation WHERE run_id='$RUN';")" = RELEASED ] \
    || fail "late ABORT changed terminal reservation state"
[ ! -e "$RD/run.ABORT_DONE" ] || fail "late ABORT after CLOSED was incorrectly acknowledged as a real abort"
grep -q "IGNORED late ABORTED $RUN" "$ROOT/daemon.log" || fail "late ABORT ignore was not logged"
[ "$(sqlite3 "$BRIC_TAPE_DB" "SELECT COUNT(*) FROM audit_log WHERE action='ABORT_IGNORED_CLOSED' AND object='$RUN' AND result='OK';")" = 1 ] \
    || fail "late ABORT ignore was not audited"

echo "PASS run_closed_abort_barrier"
