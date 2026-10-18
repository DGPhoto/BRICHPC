#!/bin/bash
# Per-chunk QNAP window/budget gate plus dynamic tape-capacity extension.
set -euo pipefail
IFS=$'\n\t'
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"; . "$HERE/lib_common.sh"
RUN_ID=""; REQUIRED=""
while [ "$#" -gt 0 ]; do case "$1" in --run) RUN_ID="${2:-}"; shift 2;; --required-total) REQUIRED="${2:-}"; shift 2;; *) die "unknown option: $1";; esac; done
[ -n "$RUN_ID" ] && [ -n "$REQUIRED" ] || die "usage: bric-stream-gate --run RUN --required-total BYTES"
PROJECT="$(sql "SELECT project_name FROM runs WHERE run_id='$(sql_quote "$RUN_ID")';")"; [ -n "$PROJECT" ] || die "run not found: $RUN_ID"
RUN_DIR="$(qnap_run_dir "$PROJECT" "$RUN_ID")"; CAPFILE="$(run_state_dir "$RUN_ID")/reserved_capacity"
MAX="$(cfg max_inflight_chunks)"; case "$MAX" in ''|*[!0-9]*|0) MAX=8;; esac
BUDGET="$(cfg qnap_budget_bytes)"; case "$BUDGET" in ''|*[!0-9]*) BUDGET=0;; esac
POLL="${BRIC_POLL:-5}"; case "$POLL" in ''|*[!0-9]*|0) POLL=5;; esac
PROBE_MAX="$(qnap_probe_failure_limit)"
probe_failures=0
# Do not count with find(1): the tape daemon removes chunk_*.enc concurrently after a signed DONE.
# Under `set -o pipefail`, GNU find may return 1 when an entry disappears between readdir/stat,
# which used to abort a healthy producer and turn tar's upstream exit into rc=141/SIGPIPE.
shopt -s nullglob
while :; do
  [ -d "$RUN_DIR" ] || die "run staging directory disappeared: $RUN_DIR"
  _staged_files=("$RUN_DIR"/chunk_*.enc)
  staged="${#_staged_files[@]}"
  unset _staged_files
  [ -d "$RUN_DIR" ] || die "run staging directory disappeared while counting chunks: $RUN_DIR"
  reason=""; [ "$staged" -ge "$MAX" ] && reason="window full ($staged/$MAX staged)"
  if [ -z "$reason" ] && [ "$BUDGET" -gt 0 ]; then
    if inflight="$(qnap_inflight_bytes)"; then
      probe_failures=0
      inflight="${inflight:-0}"
      [ "$inflight" -ge "$BUDGET" ] && reason="QNAP at budget ($inflight/$BUDGET bytes)"
    else
      probe_rc=$?
      probe_failures=$((probe_failures+1))
      log "WARN: QNAP budget probe failed ($probe_failures/$PROBE_MAX consecutive, rc=$probe_rc); staging remains paused"
      if [ "$probe_failures" -ge "$PROBE_MAX" ]; then
        die "QNAP budget probe failed $probe_failures consecutive times (last rc=$probe_rc); refusing to continue with unknown bus occupancy"
      fi
      reason="QNAP budget probe unavailable ($probe_failures/$PROBE_MAX failures)"
    fi
  fi
  [ -z "$reason" ] && break; log "stream gate: $reason; waiting for tape drain"; sleep "$POLL"
done
CAP="$(cat "$CAPFILE" 2>/dev/null || echo 0)"; case "$CAP" in ''|*[!0-9]*) CAP=0;; esac
if [ "$REQUIRED" -gt "$CAP" ]; then "$HERE/bric-reserve-extend.sh" --run "$RUN_ID" --required-total "$REQUIRED" >/dev/null; fi
