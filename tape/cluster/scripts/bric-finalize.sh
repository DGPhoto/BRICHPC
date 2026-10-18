#!/bin/bash
# bric-finalize: wait until every chunk of a run is DONE on tape, free its QNAP blob as each
# receipt arrives, then request project closing (run.PROJECT_CLOSING).
set -euo pipefail
IFS=$'\n\t'
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
. "$HERE/lib_common.sh"
bric_log_process_start "bric-finalize" "$@"
require_cmds sqlite3 awk
enforce_bus_signing   # refuse to run unsigned when config require_bus_signing=1

RUN_ID=""
while [ "$#" -gt 0 ]; do case "$1" in --run) RUN_ID="${2:-}"; shift 2;; *) die "unknown option: $1";; esac; done
[ -n "$RUN_ID" ] || die "usage: bric-finalize --run RUN_ID"

IFS='|' read -r PROJECT NCHUNKS <<EOF
$(sqlc "SELECT project_name,n_chunks FROM runs WHERE run_id='$(sql_quote "$RUN_ID")';")
EOF
[ -n "$PROJECT" ] || die "run not found: $RUN_ID"
RUN_DIR="$(qnap_run_dir "$PROJECT" "$RUN_ID")"
sql "UPDATE runs SET status='DRAINING' WHERE run_id='$(sql_quote "$RUN_ID")';"
run_status_event "$RUN_ID" "$PROJECT" DRAINING "waiting for tape receipts"

# Failure handler: mark the run FAILED and tell the tape server (signed run.ABORTED) to release the
# reservation, orphan any partial segments and free the staging blobs. Used for both a dead producer
# task and a tape-side chunk ERROR. The cluster owns its catalog; the daemon owns tape + staging.
fail_run() {
    local msg="$1"
    log "run $RUN_ID FAILED: $msg"
    bric_notify BACKUP_FAILED "${OWNER:-$(sql "SELECT owner FROM runs WHERE run_id='$(sql_quote "$RUN_ID")';")}" "$RUN_ID" "$msg"
    sql "UPDATE runs SET status='FAILED', error='$(sql_quote "$msg")' WHERE run_id='$(sql_quote "$RUN_ID")';"
    run_status_event "$RUN_ID" "$PROJECT" FAILED "$msg"
    rm -rf "$(run_state_dir "$RUN_ID")" 2>/dev/null || true
    marker_set_signed "$RUN_DIR" run.ABORTED "run_id=$RUN_ID
project=$PROJECT
reason=$msg"
    if marker_wait "$RUN_DIR" run.ABORT_DONE "" "${BRIC_ABORT_ACK_TIMEOUT:-120}" >/dev/null; then
        if marker_verify "$RUN_DIR" run.ABORT_DONE; then
            bus_cleanup_run_dir "$PROJECT" "$RUN_ID" FAILED || warn_log "FAILED run acknowledged but QNAP bus cleanup was deferred: $RUN_DIR"
        else
            warn_log "FAILED run $RUN_ID received an invalid run.ABORT_DONE; preserving QNAP bus directory"
        fi
    else
        warn_log "FAILED run $RUN_ID: tape abort acknowledgement timed out; preserving QNAP bus directory for daemon recovery"
    fi
    die "$msg"
}

# Reconcile up front. Under SLURM we run via --dependency=afterany, so when we start the chunk array is
# already terminal: any chunk still PENDING/PRODUCING never reached READY = a producer task that died
# (node failure, OOM, preemption) without an ERROR marker. Detect it immediately instead of blocking on
# the drain timeout. (In local mode chunks run inline, so this set is empty unless one truly failed.)
DEAD="$(sql "SELECT COUNT(*) FROM chunks WHERE run_id='$(sql_quote "$RUN_ID")' AND state IN ('PLANNED','PENDING','PRODUCING','ERROR');")"
if [ "${DEAD:-0}" -gt 0 ]; then
    fail_run "$DEAD chunk(s) never reached the tape (producer died, produce failed, or quiescence guard aborted); aborting run"
fi
log "waiting for $NCHUNKS chunk(s) to reach tape..."

TIMEOUT="${BRIC_DRAIN_TIMEOUT:-86400}"; t=0
while :; do
    done_n=0
    for cno in $(seq 1 "$NCHUNKS"); do
        cb="$(printf 'chunk_%04d' "$cno")"
        if [ -e "$RUN_DIR/$cb.DONE" ]; then
            # A forged DONE would make us free a blob that is NOT really on tape -> data loss. Verify.
            marker_verify "$RUN_DIR" "$cb.DONE" || die "DONE for $cb failed signature verification (forged?) — refusing to free blob"
            [ "$(marker_field run_id "$RUN_DIR/$cb.DONE")" = "$RUN_ID" ] || die "DONE for $cb not bound to this run"
            done_n=$((done_n+1))
            if [ "$(sql "SELECT state FROM chunks WHERE run_id='$(sql_quote "$RUN_ID")' AND chunk_no=$cno;")" != "DONE" ]; then
                sql "UPDATE chunks SET state='DONE', updated_at=datetime('now') WHERE run_id='$(sql_quote "$RUN_ID")' AND chunk_no=$cno;"
                chunk_status_event "$RUN_ID" "$PROJECT" "$cno" DONE "tape receipt verified"
                rm -f "$RUN_DIR/$cb.enc" "$RUN_DIR/$cb.enc.sha256" "$RUN_DIR/$cb.enc.hmac"
            fi
        elif [ -e "$RUN_DIR/$cb.ERROR" ]; then
            marker_verify "$RUN_DIR" "$cb.ERROR" || die "ERROR marker for $cb failed signature verification (forged?)"
            sql "UPDATE chunks SET state='ERROR', error='$(sql_quote "$(marker_read "$RUN_DIR" "$cb.ERROR")")' WHERE run_id='$(sql_quote "$RUN_ID")' AND chunk_no=$cno;"
            fail_run "chunk $cno failed on tape: $(marker_read "$RUN_DIR" "$cb.ERROR")"
        fi
    done
    [ "$done_n" -ge "$NCHUNKS" ] && break
    sql "UPDATE reservation SET heartbeat_at=datetime('now') WHERE run_id='$(sql_quote "$RUN_ID")';"
    sleep "${BRIC_POLL:-2}"; t=$((t+${BRIC_POLL:-2}))
    [ "$t" -ge "$TIMEOUT" ] && fail_run "drain timed out ($done_n/$NCHUNKS done)"
done

sql "UPDATE runs SET status='CLOSING' WHERE run_id='$(sql_quote "$RUN_ID")';"
run_status_event "$RUN_ID" "$PROJECT" CLOSING "all chunks done; sealing catalogs and TOC"
rm -rf "$(run_state_dir "$RUN_ID")"   # NUL-safe member lists were consumed during production
marker_set_signed "$RUN_DIR" run.PROJECT_CLOSING "run_id=$RUN_ID
project=$PROJECT"
log "all $NCHUNKS chunk(s) on tape; requested project closing"
