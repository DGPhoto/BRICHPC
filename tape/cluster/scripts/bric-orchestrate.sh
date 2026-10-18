#!/bin/bash
# bric-orchestrate: runs as a short SLURM job (NOT on the login node). It performs the blocking
# reservation handshake (bric-plan waits for the tape server's RESERVED) here, on a compute node, then
# submits the chunk array and the dependent finalize/close job. This keeps the login node free and makes
# the whole pipeline survive an SSH disconnect. Inputs come from the environment: BRIC_PROJECT, BRIC_SOURCE.
set -euo pipefail
IFS=$'\n\t'
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
. "$HERE/lib_common.sh"
bric_log_process_start "bric-orchestrate" "$@"
require_role slurm
require_cmds sqlite3 sbatch awk
enforce_bus_signing

PROJECT="${BRIC_PROJECT:?BRIC_PROJECT not set}"
SOURCE="${BRIC_SOURCE:?BRIC_SOURCE not set}"

# If we die AFTER acquiring the producer slot but BEFORE finalize is submitted, free the slot so it
# does not wedge every other backup. (Once finalize is submitted it owns slot release + reservation
# cleanup via its afterany dependency.) The tape reservation, if held, expires by its TTL.
orch_abort() {
    local rc=$?
    [ -n "${RUN_ID:-}" ] && sql "UPDATE runs SET status='FAILED', error='orchestrator aborted before finalize submission' WHERE run_id='$(sql_quote "$RUN_ID")' AND status IN ('RESERVED','PRODUCING');" 2>/dev/null || true
    log "orchestrator aborted (rc=$rc); released producer slot for ${RUN_ID:-?}"
    exit "$rc"
}

# 1) plan + reserve (this is the step that can block until tapes are free — now off the login node)
RUN_ID="$("$HERE/bric-plan.sh" --project "$PROJECT" --source "$SOURCE")"
n="$(sql "SELECT n_chunks FROM runs WHERE run_id='$(sql_quote "$RUN_ID")';")"
[ -n "$n" ] && [ "$n" -gt 0 ] || die "planning produced no chunks for $PROJECT"

# 2) sliding window: cap concurrently-running array tasks so at most that many encrypted blobs sit on
#    the QNAP at once (the tape daemon frees each blob right after DONE).
maxinflight="$(cfg max_inflight_chunks)"; maxinflight="${maxinflight:-8}"
case "$maxinflight" in ''|*[!0-9]*) maxinflight=8;; esac; [ "$maxinflight" -lt 1 ] && maxinflight=1
ARRAYSPEC="1-$n"; [ "$n" -gt "$maxinflight" ] && ARRAYSPEC="1-$n%$maxinflight"

# Export only the variables the jobs actually need (no blanket --export=ALL and no values in
# Slurm's comma-delimited grammar). Values are injected into the sbatch process environment; the
# export option carries only allow-listed names.
EXPORTS="BRIC_RUN_ID"
SBATCH_ENV=("BRIC_RUN_ID=$RUN_ID")
for v in BRIC_ROLE BRIC_HOME BRIC_DB BRIC_QNAP BRIC_QNAP_MNT BRIC_REQUIRE_NFS_BUS BRIC_KEYS BRIC_USER_KEYS_DIR BRIC_USER_KEY_FILE BRIC_RUNSTATE BRIC_LOCAL_LOCK_DIR \
         BRIC_BUS_SIGN_KEY BRIC_BUS_VERIFY_KEY BRIC_DRAIN_TIMEOUT BRIC_CLOSE_TIMEOUT \
         BRIC_POLL BRIC_CHUNK_RETRIES BRIC_LOCAL_TMPDIR BRIC_USER BRIC_CONFIG \
         BRIC_SLURM_OPENSSL_MODULE BRIC_MODULE_INIT BRIC_SLURM_LOGDIR \
             BRIC_LOG_DIR BRIC_LOG_FALLBACK_DIR BRIC_LOG_CAPTURE_STDIO BRIC_LOG_GROUP BRIC_LOG_MAX_MESSAGE BRIC_REQUIRE_LOGGING BRIC_NOTIFY_LOG; do
    if [ -n "${!v:-}" ]; then SBATCH_ENV+=("$v=${!v}"); EXPORTS="$EXPORTS,$v"; fi
done

# 2.5) Global producer admission: the network (Isilon read + NFS write to the QNAP) is the real
#      bottleneck, so only `max_concurrent_producers` backups stream to the QNAP at once. Block here
#      (on a compute node, not the login node) until it is our turn, then mark the run PRODUCING
#      atomically. The slot is released the moment producing ends (bric-finalize.sh -> DRAINING), so
#      the next backup produces while this run's blobs are still being written to tape.
trap 'orch_abort' ERR INT TERM
producer_slot_acquire "$RUN_ID"

LOGDIR="$(bric_slurm_logdir)"
AID="$(env "${SBATCH_ENV[@]}" sbatch --parsable -p archive --array="$ARRAYSPEC" --requeue \
        --output="$LOGDIR/bric-chunk-%A_%a.out" \
        --export="$EXPORTS" "$HERE/../slurm/archive_array.sbatch")"
sql "UPDATE runs SET slurm_array_job='$AID' WHERE run_id='$(sql_quote "$RUN_ID")';"
BRIC_LOG_RUN_ID="$RUN_ID" BRIC_LOG_PROJECT="$PROJECT" bric_event INFO SLURM_JOB_SUBMITTED     "kind=chunk-array job=$AID array=$ARRAYSPEC window=$maxinflight requeue=yes output=$LOGDIR/bric-chunk-%A_%a.out"
log "submitted chunk array $AID (--array=$ARRAYSPEC; window=$maxinflight; --requeue on)"

# 3) finalize/close depends on afterANY (not afterok): it must run even if some array tasks failed, so
#    it can detect the failure, mark the run FAILED and tell the tape server to release/clean up. On
#    success it requests close. finalize && close: close only runs if finalize succeeds.
FID="$(env "${SBATCH_ENV[@]}" sbatch --parsable -p archive --dependency=afterany:"$AID" \
    --output="$LOGDIR/bric-finalize-%j.out" \
    --export="$EXPORTS" "$HERE/../slurm/finalize_close.sbatch")"
BRIC_LOG_RUN_ID="$RUN_ID" BRIC_LOG_PROJECT="$PROJECT" bric_event INFO SLURM_JOB_SUBMITTED     "kind=finalize job=$FID dependency=afterany:$AID output=$LOGDIR/bric-finalize-%j.out"
log "submitted finalize/close (afterany:$AID) for $RUN_ID"
trap - ERR INT TERM   # finalize now owns producer-slot release and reservation cleanup
echo "$RUN_ID"
