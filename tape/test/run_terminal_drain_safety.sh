#!/bin/bash
# Review 30AC: terminal/error marker existence fences tape I/O but is never delete authority.
# Only a cryptographically verified/path-bound ABORT may destroy pending staging. Also prove that
# READY->CLAIMED refreshes mtime and ERROR/terminal claims cannot be reclaimed into a retry loop.
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
sqlite3 "$BRIC_TAPE_DB" "UPDATE config SET value='6' WHERE key='claim_ttl_hours'; UPDATE config SET value='1' WHERE key='poll_seconds'; UPDATE config SET value='1' WHERE key='require_bus_signing';" >/dev/null
DAEMON="$REPO/tape/bin/bric-tape-daemon"

# Independent cluster/tape bus identities. The daemon signs receipts with tape.pem and verifies
# producer markers with cluster.pub. Tests create producer markers with cluster.pem.
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

make_meta(){
    local rd="$1" run="$2" project="$3" chunk="$4" size="${5:-4}" cb
    cb="chunk_$(printf '%04d' "$chunk")"
    sign_cluster_marker "$rd" "$cb.meta" "run_id=$run
project=$project
owner=tester
chunk_no=$chunk
type=TAR_PART
size_bytes=$size
payload_sha256=deadbeef"
}
make_ready(){ local rd="$1" chunk="$2" cb; cb="chunk_$(printf '%04d' "$chunk")"; sign_cluster_marker "$rd" "$cb.READY" x; }

# RUN1: genuine signed ABORT. This is the ONLY terminal scenario allowed to delete pending staging.
RUN1=abortok__20260828T000000Z__0001; RD1="$BRIC_QNAP/archive/abortok/$RUN1"; mkdir -p "$RD1"
sign_cluster_marker "$RD1" run.ABORTED "run_id=$RUN1
project=abortok"
make_ready "$RD1" 1; printf ciphertext >"$RD1/chunk_0001.enc"; make_meta "$RD1" "$RUN1" abortok 1
printf x >"$RD1/chunk_0002.CLAIMED"; printf ciphertext >"$RD1/chunk_0002.enc"; make_meta "$RD1" "$RUN1" abortok 2

# RUN2: forged/unsigned CLOSED with no VERIFIED placement. Existence must fence tape I/O and preserve ciphertext.
# The daemon may atomically claim READY while determining that no idempotent receipt can be reconstructed;
# either marker state is acceptable because CLOSED prevents reclaim and no destructive cleanup is authorized.
RUN2=forgedclosed__20260828T000000Z__0001; RD2="$BRIC_QNAP/archive/forgedclosed/$RUN2"; mkdir -p "$RD2"
printf 'run_id=%s\nproject=forgedclosed\n' "$RUN2" >"$RD2/run.CLOSED"
make_ready "$RD2" 1; printf ciphertext >"$RD2/chunk_0001.enc"; make_meta "$RD2" "$RUN2" forgedclosed 1

# RUN3: old READY, then a missing blob. Claim mtime must be refreshed and ERROR must fence reclaim.
RUN3=err__20260828T000000Z__0001; RD3="$BRIC_QNAP/archive/err/$RUN3"; mkdir -p "$RD3"
make_ready "$RD3" 1; make_meta "$RD3" "$RUN3" err 1
touch -d '2 days ago' "$RD3/chunk_0001.READY"

# RUN4: forged/unsigned ERROR. It may fence the chunk but must never delete its only ciphertext copy.
RUN4=forgederr__20260828T000000Z__0001; RD4="$BRIC_QNAP/archive/forgederr/$RUN4"; mkdir -p "$RD4"
make_ready "$RD4" 1; make_meta "$RD4" "$RUN4" forgederr 1; printf ciphertext >"$RD4/chunk_0001.enc"
printf forged >"$RD4/chunk_0001.ERROR"

# RUN5: terminal marker visible at daemon startup. Startup reclaim must use the complete terminal fence
# (including ABORT_DONE/DENIED) and must not rename or delete the old claim on marker existence alone.
RUN5=abortdone__20260828T000000Z__0001; RD5="$BRIC_QNAP/archive/abortdone/$RUN5"; mkdir -p "$RD5"
printf 'run_id=%s\nproject=abortdone\n' "$RUN5" >"$RD5/run.ABORT_DONE"
printf x >"$RD5/chunk_0001.CLAIMED"; touch -d '2 days ago' "$RD5/chunk_0001.CLAIMED"

# RUN6: CLOSED is terminal for new tape I/O but must preserve the pre-existing bus contract: a
# re-published READY for a chunk already VERIFIED on both copies reconstructs DONE without rewriting.
RUN6=closedredo__20260828T000000Z__0001; RD6="$BRIC_QNAP/archive/closedredo/$RUN6"; mkdir -p "$RD6"
printf 'run_id=%s\nproject=closedredo\n' "$RUN6" >"$RD6/run.CLOSED"
make_ready "$RD6" 1; make_meta "$RD6" "$RUN6" closedredo 1
sqlite3 "$BRIC_TAPE_DB" "INSERT INTO segments(seg_id,run_id,project_name,owner,chunk_no,copy_role,volumetag,file_number,payload_sha256,size_bytes,state) VALUES
('${RUN6}__c1__PRIMARY','$RUN6','closedredo','tester',1,'PRIMARY','000001L9',17,'deadbeef',4,'VERIFIED'),
('${RUN6}__c1__BACKUP','$RUN6','closedredo','tester',1,'BACKUP','000002L9',17,'deadbeef',4,'VERIFIED');"

echo "== one pass over verified and unverified terminal/error scenarios =="
"$DAEMON" --once >/dev/null 2>&1

[ -f "$RD1/run.ABORT_DONE" ] || fail "verified ABORT did not publish ABORT_DONE"
if find "$RD1" -maxdepth 1 -type f \( -name 'chunk_*.READY' -o -name 'chunk_*.CLAIMED' -o -name 'chunk_*.ERROR' -o -name 'chunk_*.enc' \) | grep -q .; then
    fail "verified ABORT cleanup left pending data-path files"
fi
echo "  ok: verified/path-bound ABORT owns destructive cleanup"

[ -e "$RD2/chunk_0001.READY" ] || [ -e "$RD2/chunk_0001.CLAIMED" ] || fail "unsigned CLOSED lost both READY and CLAIMED"
[ -e "$RD2/chunk_0001.enc" ] || fail "unsigned CLOSED deleted ciphertext"
[ ! -e "$RD2/chunk_0001.DONE" ] || fail "unsigned CLOSED fabricated DONE without VERIFIED placement"
echo "  ok: unsigned CLOSED fences new I/O without destructive cleanup"

[ -f "$RD3/chunk_0001.ERROR" ] || fail "missing-blob ERROR receipt not published"
[ -f "$RD3/chunk_0001.CLAIMED" ] || fail "ERROR claim was destructively removed"
[ ! -e "$RD3/chunk_0001.READY" ] || fail "ERROR claim was incorrectly requeued READY"
now=$(date +%s); mt=$(stat -c %Y "$RD3/chunk_0001.CLAIMED")
[ $((now-mt)) -lt 120 ] || fail "CLAIMED mtime was not refreshed at claim time"
echo "  ok: claim timestamp is fresh and ERROR cannot form the old reclaim loop"

[ -e "$RD4/chunk_0001.enc" ] || fail "unsigned ERROR deleted ciphertext"
[ -e "$RD4/chunk_0001.READY" ] || fail "unsigned ERROR deleted READY"
echo "  ok: ERROR existence fences but is not delete authority"

[ -e "$RD5/chunk_0001.CLAIMED" ] || fail "terminal startup fence deleted CLAIMED"
[ ! -e "$RD5/chunk_0001.READY" ] || fail "ABORT_DONE claim was requeued READY at startup"
echo "  ok: startup reclaim uses complete terminal fence without destructive marker cleanup"

[ -e "$RD6/chunk_0001.DONE" ] || fail "CLOSED requeue did not reconstruct DONE from VERIFIED placement"
[ "$(sqlite3 "$BRIC_TAPE_DB" "SELECT COUNT(*) FROM segments WHERE run_id='$RUN6' AND chunk_no=1;")" = 2 ] || fail "CLOSED idempotency changed physical segment count"
echo "  ok: CLOSED preserves idempotent DONE receipt without a tape rewrite"

[ -z "$(find "$BRIC_TAPELIB" -type f -name 'f_*' -print -quit 2>/dev/null)" ] || fail "terminal/error scenarios wrote to simulated tape"
echo "  ok: no terminal/error scenario touched tape"

echo "PASS run_terminal_drain_safety"
