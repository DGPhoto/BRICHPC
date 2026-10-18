#!/bin/bash
. "$(cd "$(dirname "$(readlink -f "$0")")" && pwd)/lib_test_daemon.sh"
# Review 31D: end-to-end daemon regression for the 0011 failure class. A transport/local verify
# failure must consume/account the physical append but must NOT increment media error telemetry;
# a clean short stream and an exact-size hash mismatch must both penalize media.
set -euo pipefail
export BRIC_CONFIG=none
REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
ROOT="$(mktemp -d)"; DAEMON=0
trap 'if [ "${DAEMON:-0}" -gt 0 ]; then bric_test_stop_group "$DAEMON"; fi; bric_test_rmrf_retry "$ROOT"' EXIT
fail(){ echo "FAIL: $*" >&2; exit 1; }

run_case(){
    local mode="$1" expect_health="$2" case_root
    case_root="$ROOT/$mode"
    mkdir -p "$case_root/qnap/bric" "$case_root/keys" "$case_root/tapelib" "$case_root/src" "$case_root/log/primary" "$case_root/log/fallback"
    export BRIC_LOG_DIR="$case_root/log/primary" BRIC_LOG_FALLBACK_DIR="$case_root/log/fallback" BRIC_REQUIRE_LOGGING=1
    export BRIC_HOME="$REPO/cluster" BRIC_DB="$case_root/cluster.db" BRIC_QNAP="$case_root/qnap/bric" BRIC_KEYS="$case_root/keys"
    export BRIC_SQL_INIT="$REPO/cluster/sql/cluster_init.sql" BRIC_USER="verifyuser" BRIC_RUN_MODE=local
    export BRIC_RESERVE_TIMEOUT=30 BRIC_DRAIN_TIMEOUT=60 BRIC_CLOSE_TIMEOUT=60 BRIC_POLL=1
    export BRIC_TAPE_HOME="$REPO/tape" BRIC_TAPE_DB="$case_root/tape.db" BRIC_TAPE_SQL_INIT="$REPO/tape/sql/tape_init.sql"
    export BRIC_TAPE_BACKEND=sim BRIC_TAPELIB="$case_root/tapelib" BRIC_TAPE_LOCK="$case_root/tape.lock"
    export BRIC_TAPE_DRIVES="0 1" BRIC_PARALLEL_DRIVES=2 BRIC_FAULT_SIM_VERIFY_MODE="$mode"
    sqlite3 "$BRIC_DB" < "$BRIC_SQL_INIT" >/dev/null
    sqlite3 "$BRIC_TAPE_DB" < "$BRIC_TAPE_SQL_INIT" >/dev/null
    sqlite3 "$BRIC_DB" "UPDATE config SET value='8388608' WHERE key='segment_target_bytes';"
    sqlite3 "$BRIC_TAPE_DB" "UPDATE config SET value='1' WHERE key='poll_seconds'; UPDATE config SET value='2' WHERE key='parallel_drives';"
    head -c 32 /dev/urandom | base64 > "$BRIC_KEYS/${BRIC_USER}_user_key.txt"
    head -c 32 /dev/urandom | base64 > "$BRIC_KEYS/master.key"; chmod 600 "$BRIC_KEYS"/*
    sqlite3 "$BRIC_TAPE_DB" "INSERT INTO tapes(volumetag,slot,role,pair_number,paired_volumetag,capacity_tb,used_tb,status)
      VALUES('000001L9',1,'PRIMARY',1,'000002L9',18,0,'EMPTY'),('000002L9',2,'BACKUP',1,'000001L9',18,0,'EMPTY');"
    head -c 1048576 /dev/urandom > "$case_root/src/payload.bin"

    BRIC_FAULT_SIM_VERIFY_MODE="$mode" setsid "$REPO/tape/bin/bric-tape-daemon" --loop >"$case_root/daemon.log" 2>&1 & DAEMON=$!
    sleep 1
    if timeout 50 "$REPO/cluster/bin/bric" backup --project "verify_$mode" --source "$case_root/src" --wait >"$case_root/backup.log" 2>&1; then
        bric_test_stop_group "$DAEMON"; DAEMON=0
        fail "$mode verify fault unexpectedly produced a successful backup"
    fi
    bric_test_stop_group "$DAEMON"; DAEMON=0

    local abandoned used_min err_sum bad_health
    abandoned="$(sqlite3 "$BRIC_TAPE_DB" "SELECT COUNT(*) FROM segments WHERE state='ABANDONED';")"
    used_min="$(sqlite3 "$BRIC_TAPE_DB" "SELECT MIN(CAST(used_tb*1000000000000 AS INTEGER)) FROM tapes WHERE pair_number=1;")"
    err_sum="$(sqlite3 "$BRIC_TAPE_DB" "SELECT SUM(write_errors) FROM tapes WHERE pair_number=1;")"
    bad_health="$(sqlite3 "$BRIC_TAPE_DB" "SELECT COUNT(*) FROM tapes WHERE pair_number=1 AND health='$expect_health';")"
    [ "$abandoned" -ge 2 ] || fail "$mode: expected abandoned physical copies, got $abandoned"
    [ "${used_min:-0}" -gt 0 ] || fail "$mode: physical append was not accounted in used_tb"
    [ "$bad_health" -eq 2 ] || fail "$mode: expected both tapes health=$expect_health"
    if [ "$mode" = io ]; then
        [ "${err_sum:-99}" -eq 0 ] || fail "host/readback failure polluted write_errors ($err_sum)"
        grep -Rq 'SEGMENT_READBACK_FAILED' "$case_root/log/primary/events" "$case_root/log/fallback/events" 2>/dev/null || fail "host/readback classification event missing"
        ! grep -Rq 'SEGMENT_VERIFY_FAILED' "$case_root/log/primary/events" "$case_root/log/fallback/events" 2>/dev/null || fail "host/readback failure was misclassified as media failure"
        echo "  ok: local/transport verify failure accounted bytes but left media health OK"
    elif [ "$mode" = short ]; then
        [ "${err_sum:-0}" -ge 2 ] || fail "clean short stream did not increment media write_errors"
        grep -Rq 'SEGMENT_VERIFY_FAILED' "$case_root/log/primary/events" "$case_root/log/fallback/events" 2>/dev/null || fail "short-stream media classification event missing"
        grep -Rq 'class=media-size-mismatch' "$case_root/log/primary/events" "$case_root/log/fallback/events" 2>/dev/null || fail "short-stream media-size class missing"
        echo "  ok: clean short stream is a media-health failure"
    else
        [ "${err_sum:-0}" -ge 2 ] || fail "exact-size corruption did not increment media write_errors"
        grep -Rq 'SEGMENT_VERIFY_FAILED' "$case_root/log/primary/events" "$case_root/log/fallback/events" 2>/dev/null || fail "media hash classification event missing"
        echo "  ok: exact-size hash mismatch remains a media-health failure"
    fi
}

run_case io OK
run_case short SUSPECT
run_case corrupt SUSPECT

echo "PASS run_verify_failure_attribution"
