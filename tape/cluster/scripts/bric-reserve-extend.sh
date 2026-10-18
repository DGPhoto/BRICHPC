#!/bin/bash
# Extend an existing stream reservation to an absolute logical byte target.
set -euo pipefail
IFS=$'\n\t'
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"; . "$HERE/lib_common.sh"
bric_log_process_start "bric-reserve-extend" "$@"; enforce_bus_signing
RUN_ID=""; REQUIRED=""
while [ "$#" -gt 0 ]; do case "$1" in --run) RUN_ID="${2:-}"; shift 2;; --required-total) REQUIRED="${2:-}"; shift 2;; *) die "unknown option: $1";; esac; done
[ -n "$RUN_ID" ] && [ -n "$REQUIRED" ] || die "usage: bric-reserve-extend --run RUN --required-total BYTES"
case "$REQUIRED" in ''|*[!0-9]*) die "required total must be numeric";; esac
IFS='|' read -r PROJECT OWNER <<EOF2
$(sqlc "SELECT project_name,owner FROM runs WHERE run_id='$(sql_quote "$RUN_ID")';")
EOF2
[ -n "$PROJECT" ] || die "run not found: $RUN_ID"
RUN_DIR="$(qnap_run_dir "$PROJECT" "$RUN_ID")"; RUNSTATE="$(run_state_dir "$RUN_ID")"
rm -f "$RUN_DIR/run.RESERVE_EXTEND_REQUEST" "$RUN_DIR/run.RESERVE_EXTEND_REQUEST.sig" "$RUN_DIR/run.RESERVE_EXTENDED" "$RUN_DIR/run.RESERVE_EXTENDED.sig" "$RUN_DIR/run.RESERVE_EXTEND_DENIED" "$RUN_DIR/run.RESERVE_EXTEND_DENIED.sig"
marker_set_signed "$RUN_DIR" run.RESERVE_EXTEND_REQUEST "run_id=$RUN_ID
project=$PROJECT
owner=$OWNER
requested_total_bytes=$REQUIRED"
log "requesting reservation extension to $REQUIRED logical bytes"
ANS="$(marker_wait "$RUN_DIR" run.RESERVE_EXTENDED run.RESERVE_EXTEND_DENIED "${BRIC_RESERVE_TIMEOUT:-600}")" || die "timed out waiting for reservation extension"
marker_verify "$RUN_DIR" "$ANS" || die "reservation extension response failed signature verification"
[ "$(marker_field run_id "$RUN_DIR/$ANS")" = "$RUN_ID" ] || die "extension response not bound to run"
if [ "$ANS" = run.RESERVE_EXTEND_DENIED ]; then die "reservation extension DENIED: $(marker_field reason "$RUN_DIR/$ANS")"; fi
CAP="$(marker_field capacity_bytes "$RUN_DIR/$ANS")"; NPAIRS="$(marker_field pairs "$RUN_DIR/$ANS")"
case "$CAP" in ''|*[!0-9]*) die "invalid capacity_bytes in extension response";; esac
printf '%s\n' "$CAP" > "$RUNSTATE/reserved_capacity.tmp.$$"; mv -f "$RUNSTATE/reserved_capacity.tmp.$$" "$RUNSTATE/reserved_capacity"
sql "UPDATE reservation SET requested_tb=$(awk -v b="$REQUIRED" 'BEGIN{printf "%.6f",b/1000000000000}'),n_pairs='${NPAIRS:-0}',heartbeat_at=datetime('now') WHERE run_id='$(sql_quote "$RUN_ID")';"
log "reservation extended: pairs=${NPAIRS:-?}, capacity=$CAP bytes"
printf '%s\n' "$CAP"
