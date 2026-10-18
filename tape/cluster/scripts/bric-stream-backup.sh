#!/bin/bash
# One-pass local backup: GNU tar walks the included source once; a static tar-aware chunker creates
# independent encrypted TAR_PART/LARGE_FILE_CHUNK payloads and publishes them under flow control.
# Review 32B4 keeps source readability fail-closed by default; --force converts precisely identified unreadable paths into logged/cataloged exclusions.
set -euo pipefail
IFS=$'\n\t'
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"; . "$HERE/lib_common.sh"
bric_log_process_start "bric-stream-backup" "$@"
require_cmds sqlite3 tar openssl awk mktemp find
PROJECT=""; SOURCE=""; SOURCE_CHANGE_POLICY=""; FORCE=0
declare -a EXCLUDES=() FORCED_EXCLUDES=() FORCED_REASONS=() ALL_EXCLUDES=()
while [ "$#" -gt 0 ]; do case "$1" in
 --project) PROJECT="${2:-}";shift 2;; --source) SOURCE="${2:-}";shift 2;;
 --source-change-policy) SOURCE_CHANGE_POLICY="${2:-}"; shift 2;;
 --force) FORCE=1; shift;;
 --exclude)
   [ "$#" -ge 2 ] || die "backup: --exclude requires a relative path"
   ex="$(bric_normalize_exclude_rel "$2" || true)"; [ -n "$ex" ] || die "backup: invalid exclusion '$2'"
   EXCLUDES+=("$ex"); shift 2;;
 *) die "unknown option: $1";; esac; done
[ -n "$PROJECT" ] && [ -n "$SOURCE" ] || die "usage: bric-stream-backup --project NAME --source DIR [--exclude RELPATH ...] [--source-change-policy strict|record] [--force]"
if [ -z "$SOURCE_CHANGE_POLICY" ]; then SOURCE_CHANGE_POLICY="$(cfg source_change_policy 2>/dev/null)"; fi
[ -n "$SOURCE_CHANGE_POLICY" ] || SOURCE_CHANGE_POLICY=strict
case "$SOURCE_CHANGE_POLICY" in strict|record) :;; *) die "invalid source change policy '$SOURCE_CHANGE_POLICY'";; esac
SOURCE="$(readlink -f "$SOURCE")"
STREAM="$HERE/../libexec/bric-tar-stream"; [ -x "$STREAM" ] || die "tar stream helper missing/not executable: $STREAM"

# Normal `bric backup` already performed this scan synchronously and exported its result into the
# detached child. Direct/internal invocation still cannot reserve tape without the integrity gate.
case "${BRIC_SOURCE_PREFLIGHT_FILES:-}" in ''|*[!0-9]*) need_scan=1;; *) need_scan=0;; esac
FORCE_FILE="${BRIC_FORCE_EXCLUDE_FILE:-}"
# A force run is only trustworthy if it has the exact omission manifest from its own preflight.
# Direct/internal invocations without that manifest must rescan rather than trusting stale counters.
[ "$FORCE" -eq 0 ] || [ -n "$FORCE_FILE" ] || need_scan=1
if [ "$FORCE" -eq 1 ] && [ -z "$FORCE_FILE" ]; then
    FORCE_FILE="$(mktemp "${BRIC_LOCAL_TMPDIR:-/tmp}/bric-force-excludes.$(id -u).XXXXXX")"
    chmod 600 "$FORCE_FILE"
    export BRIC_FORCE_EXCLUDE_FILE="$FORCE_FILE"
fi
if [ "$need_scan" -eq 1 ]; then
    scan_args=(--source "$SOURCE")
    for ex in "${EXCLUDES[@]}"; do scan_args+=(--exclude "$ex"); done
    [ "$FORCE" -eq 0 ] || scan_args+=(--force --force-exclude-file "$FORCE_FILE")
    scan="$($HERE/bric-source-preflight.sh "${scan_args[@]}")" || die "source integrity preflight failed; no tape reservation requested"
    IFS='|' read -r BRIC_SOURCE_PREFLIGHT_FILES BRIC_SOURCE_PREFLIGHT_LOGICAL_BYTES BRIC_SOURCE_PREFLIGHT_ALLOCATED_BYTES BRIC_SOURCE_PREFLIGHT_EXCLUSION_COUNT BRIC_SOURCE_PREFLIGHT_UID <<< "$scan"
    export BRIC_SOURCE_PREFLIGHT_FILES BRIC_SOURCE_PREFLIGHT_LOGICAL_BYTES BRIC_SOURCE_PREFLIGHT_ALLOCATED_BYTES BRIC_SOURCE_PREFLIGHT_EXCLUSION_COUNT BRIC_SOURCE_PREFLIGHT_UID
fi

# Force exclusions are NUL-delimited path/reason pairs created by the synchronous preflight. Load and
# log every one again inside the detached job so the durable per-job logfile contains the complete
# omission list, not only the command's preflight output.
if [ "$FORCE" -eq 1 ]; then
    [ -n "$FORCE_FILE" ] && [ -r "$FORCE_FILE" ] || die "force mode exclusion manifest missing/unreadable"
    while IFS= read -r -d '' ex && IFS= read -r -d '' reason; do
        n="$(bric_normalize_exclude_rel "$ex" || true)"
        [ -n "$n" ] || die "force exclusion manifest contains invalid relative path"
        FORCED_EXCLUDES+=("$n"); FORCED_REASONS+=("${reason:-unreadable}")
        printf '[WARN] FORCE omitted source path: %q reason=%s\n' "$n" "${reason:-unreadable}" >&2
        warn_log "FORCE omitted source path=$(printf '%q' "$n") reason=${reason:-unreadable}"
    done < "$FORCE_FILE"
    printf '[WARN] FORCE omission summary: %d path(s) excluded from this backup\n' "${#FORCED_EXCLUDES[@]}" >&2
    rm -f "$FORCE_FILE" 2>/dev/null || true
    unset BRIC_FORCE_EXCLUDE_FILE 2>/dev/null || true
fi
ALL_EXCLUDES=("${EXCLUDES[@]}" "${FORCED_EXCLUDES[@]}")

PARALLEL_WORKERS="${BRIC_STREAM_PARALLEL_WORKERS:-$(cfg stream_parallel_workers 2>/dev/null)}"
case "$PARALLEL_WORKERS" in ''|*[!0-9]*) PARALLEL_WORKERS=4;; esac
[ "$PARALLEL_WORKERS" -ge 1 ] && [ "$PARALLEL_WORKERS" -le 16 ] || die "invalid stream_parallel_workers=$PARALLEL_WORKERS (expected 1..16)"
TARGET="$(cfg segment_target_bytes)"; TARGET="${TARGET:-128000000000}"
# The parallel-specific worker target may reduce chunk size, but the long-standing segment target is
# always a hard upper bound. The 32B1 production default is 128 GB for both values; smaller site/test
# targets still clamp correctly. 0/auto remains available as target/workers.
WORKER_TARGET_OVERRIDE="${BRIC_STREAM_WORKER_CHUNK_BYTES:-$(cfg stream_worker_chunk_bytes 2>/dev/null)}"
WORKER_TARGET="$(stream_worker_chunk_target "$TARGET" "$PARALLEL_WORKERS" "$WORKER_TARGET_OVERRIDE" || true)"
[ -n "$WORKER_TARGET" ] || die "invalid stream_worker_chunk_bytes=$WORKER_TARGET_OVERRIDE (expected auto/0 or positive bytes)"
MAXINFLIGHT="$(cfg max_inflight_chunks)"; case "$MAXINFLIGHT" in ''|*[!0-9]*|0) MAXINFLIGHT=8;; esac

# Review 32A: capacity must fail before reservation, not hours/days into production. In parallel mode
# published chunks plus one in-progress .enc.part per worker form the bounded local staging window.
if [ "$PARALLEL_WORKERS" -gt 1 ]; then
    case "${BRIC_SOURCE_PREFLIGHT_LOGICAL_BYTES:-}" in
        ''|*[!0-9]*) die "parallel QNAP preflight requires a valid source logical-byte count";;
        *) qnap_parallel_preflight "$BRIC_SOURCE_PREFLIGHT_LOGICAL_BYTES" "$PARALLEL_WORKERS" "$WORKER_TARGET" "$MAXINFLIGHT";;
    esac
fi

# A parallel run reserves the preflight logical scope up front.  The per-run allocator/gate extends
# this safely later if tar/encryption framing crosses the selected tape-pair capacity.
if [ "$PARALLEL_WORKERS" -gt 1 ] && [ -z "${BRIC_STREAM_INITIAL_RESERVATION_BYTES:-}" ]; then
    case "${BRIC_SOURCE_PREFLIGHT_LOGICAL_BYTES:-}" in ''|*[!0-9]*|0) :;; *) export BRIC_STREAM_INITIAL_RESERVATION_BYTES="$BRIC_SOURCE_PREFLIGHT_LOGICAL_BYTES";; esac
fi

plan_args=(--project "$PROJECT" --source "$SOURCE" --source-change-policy "$SOURCE_CHANGE_POLICY")
for ex in "${EXCLUDES[@]}"; do plan_args+=(--exclude "$ex"); done
for ex in "${FORCED_EXCLUDES[@]}"; do plan_args+=(--forced-exclude "$ex"); done
RUN_ID="$($HERE/bric-stream-plan.sh "${plan_args[@]}")"
OWNER="$(sql "SELECT owner FROM runs WHERE run_id='$(sql_quote "$RUN_ID")';")"; RUNSTATE="$(run_state_dir "$RUN_ID")"; RUN_DIR="$(qnap_run_dir "$PROJECT" "$RUN_ID")"
TMP="$(mktemp -d "${BRIC_LOCAL_TMPDIR:-/tmp}/bric-stream.XXXXXX")"; COMPLETE=0
abort_stream(){
 local rc=$? status=""; trap - EXIT INT TERM
 if [ "$COMPLETE" -ne 1 ] && [ -n "${RUN_ID:-}" ]; then
   status="$(sql "SELECT status FROM runs WHERE run_id='$(sql_quote "$RUN_ID")';" 2>/dev/null || true)"
   case "$status" in CLOSED|DENIED|FAILED|CANCELLED) :;;
   *)
     msg="tar-driven stream interrupted or failed (rc=$rc)"
     sql "UPDATE runs SET status='FAILED',error='$(sql_quote "$msg")' WHERE run_id='$(sql_quote "$RUN_ID")' AND status NOT IN('CLOSED','DENIED','FAILED','CANCELLED');" 2>/dev/null || true
     run_status_event "$RUN_ID" "$PROJECT" FAILED "$msg" >/dev/null 2>&1 || true
     if [ -n "${RUN_DIR:-}" ]; then
       marker_set_signed "$RUN_DIR" run.ABORTED "run_id=$RUN_ID
project=$PROJECT
reason=$msg" >/dev/null 2>&1 || true
       if marker_wait "$RUN_DIR" run.ABORT_DONE "" "${BRIC_ABORT_ACK_TIMEOUT:-120}" >/dev/null 2>&1 \
          && marker_verify "$RUN_DIR" run.ABORT_DONE >/dev/null 2>&1; then
         bus_cleanup_run_dir "$PROJECT" "$RUN_ID" FAILED >/dev/null 2>&1 || true
       fi
     fi
     bric_notify BACKUP_FAILED "${OWNER:-$(bric_whoami)}" "$RUN_ID" "$msg" >/dev/null 2>&1 || true
     ;;
   esac
 fi
 rm -rf "${TMP:-}"; bric_log_process_end "$rc" || true; exit "$rc"
}
trap abort_stream EXIT; trap 'exit 130' INT; trap 'exit 143' TERM
producer_slot_acquire "$RUN_ID"
UKF="$(user_key_file "$OWNER")"; [ -s "$UKF" ] || die "user key missing for $OWNER"
derive_keys "$(cat "$UKF")"; printf '%s' "$ENC_KEY" > "$TMP/enc"; printf '%s' "$HMAC_KEY" > "$TMP/hmac"; chmod 600 "$TMP/enc" "$TMP/hmac"
TAR_BLOCKING_FACTOR="${BRIC_TAR_BLOCKING_FACTOR:-$(cfg tar_blocking_factor)}"
case "$TAR_BLOCKING_FACTOR" in ''|*[!0-9]*|0) TAR_BLOCKING_FACTOR=8192;; esac
PROGRESS_EVERY="${BRIC_STREAM_PROGRESS_EVERY:-5000}"
SPARSE_MIN_HOLE="${BRIC_SPARSE_MIN_HOLE_BYTES:-$(cfg sparse_min_hole_bytes)}"; case "$SPARSE_MIN_HOLE" in ''|*[!0-9]*) SPARSE_MIN_HOLE=67108864;; esac
SPARSE_MAX_ALLOC="${BRIC_SPARSE_MAX_ALLOCATED_PERCENT:-$(cfg sparse_max_allocated_percent)}"; case "$SPARSE_MAX_ALLOC" in ''|*[!0-9]*) SPARSE_MAX_ALLOC=75;; esac
[ "$SPARSE_MAX_ALLOC" -le 100 ] || SPARSE_MAX_ALLOC=75
SPARSE_BATCH_TARGET="${BRIC_SPARSE_BATCH_TARGET_BYTES:-$(cfg sparse_batch_target_bytes)}"; case "$SPARSE_BATCH_TARGET" in ''|*[!0-9]*|0) SPARSE_BATCH_TARGET=4294967296;; esac
if [ "$PARALLEL_WORKERS" -gt 1 ]; then
  log "parallel tar-stream archive started: source=$SOURCE workers=$PARALLEL_WORKERS worker_target=$WORKER_TARGET aggregate_target=$TARGET tar_blocking_factor=$TAR_BLOCKING_FACTOR record_bytes=$((TAR_BLOCKING_FACTOR*512)) sparse_min_hole=$SPARSE_MIN_HOLE sparse_max_data_percent=$SPARSE_MAX_ALLOC sparse_batch_target=$SPARSE_BATCH_TARGET source_change_policy=$SOURCE_CHANGE_POLICY exclusions=${#ALL_EXCLUDES[@]}"
  par_args=(
    --run "$RUN_ID" --project "$PROJECT" --owner "$OWNER" --source "$SOURCE"
    --target "$WORKER_TARGET" --workers "$PARALLEL_WORKERS" --runstate "$RUNSTATE" --run-dir "$RUN_DIR"
    --enc-pass-file "$TMP/enc" --hmac-key-file "$TMP/hmac"
    --tar-blocking-factor "$TAR_BLOCKING_FACTOR" --progress-every "$PROGRESS_EVERY"
    --sparse-min-hole "$SPARSE_MIN_HOLE" --sparse-max-allocated-percent "$SPARSE_MAX_ALLOC"
    --sparse-batch-target "$SPARSE_BATCH_TARGET" --source-change-policy "$SOURCE_CHANGE_POLICY"
  )
  for ex in "${ALL_EXCLUDES[@]}"; do par_args+=(--exclude "$ex"); done
  set +e
  "$HERE/bric-stream-parallel-produce.sh" "${par_args[@]}" >"$TMP/result"
  par_rc=$?
  set -e
  case "$par_rc" in
    0) :;;
    10) die "source changed during parallel archive; strict source consistency policy refused the run";;
    11) die "parallel GNU tar diagnostics are not safely classifiable; refusing a potentially incomplete archive";;
    *) die "parallel tar-stream producer failed (rc=$par_rc)";;
  esac
else
  log "tar-driven one-pass archive started: source=$SOURCE target=$TARGET tar_blocking_factor=$TAR_BLOCKING_FACTOR record_bytes=$((TAR_BLOCKING_FACTOR*512)) sparse_min_hole=$SPARSE_MIN_HOLE sparse_max_data_percent=$SPARSE_MAX_ALLOC sparse_batch_target=$SPARSE_BATCH_TARGET source_change_policy=$SOURCE_CHANGE_POLICY sparse_map=gnu-pax-0.1 exclusions=${#ALL_EXCLUDES[@]}"

  tar_args=(--create --file=- --format=pax --blocking-factor="$TAR_BLOCKING_FACTOR" --hard-dereference --acls --xattrs --xattrs-include=user.* --xattrs-include=system.nfs4_acl --sparse --sparse-version=0.1 --warning=all --quoting-style=escape)
  for ex in "${ALL_EXCLUDES[@]}"; do tar_args+=("--exclude=./$ex"); done
  tar_args+=(-- .)
  set +e
  ( cd "$SOURCE" && LC_ALL=C tar "${tar_args[@]}" ) 2>"$TMP/tar.err" |
    "$STREAM" --run "$RUN_ID" --project "$PROJECT" --owner "$OWNER" --source "$SOURCE" --target "$TARGET" \
      --runstate "$RUNSTATE" --run-dir "$RUN_DIR" --enc-pass-file "$TMP/enc" --hmac-key-file "$TMP/hmac" \
      --gate "$HERE/bric-stream-gate.sh" --publish "$HERE/bric-stream-publish.sh" --progress-every "$PROGRESS_EVERY" \
      --sparse-min-hole "$SPARSE_MIN_HOLE" --sparse-max-allocated-percent "$SPARSE_MAX_ALLOC" \
      --sparse-batch-target "$SPARSE_BATCH_TARGET" >"$TMP/result"
  ps=("${PIPESTATUS[@]}"); set -e
  # Chunker failures are always fatal.  If the chunker consumed the complete stream, classify GNU tar
  # separately: rc=1 is acceptable only under explicit record policy and only when EVERY diagnostic is
  # the locale-pinned "file changed as we read it" form. rc>=2 and mixed/unclassified warnings stay fatal.
  if [ "${ps[1]}" -ne 0 ]; then
    [ -s "$TMP/tar.err" ] && sed 's/^/tar: /' "$TMP/tar.err" >&2
    die "tar stream failed (tar rc=${ps[0]}, chunker rc=${ps[1]})"
  fi
  set +e
  "$HERE/bric-source-consistency.sh" --run "$RUN_ID" --policy "$SOURCE_CHANGE_POLICY" --tar-rc "${ps[0]}" --stderr "$TMP/tar.err"
  cons_rc=$?
  set -e
  case "$cons_rc" in
    0)
      [ ! -s "$TMP/tar.err" ] || sed 's/^/tar: /' "$TMP/tar.err" >&2
      if [ "${ps[0]}" -eq 1 ]; then
        changed_n="$(sql "SELECT source_changed_count FROM run_source_semantics WHERE run_id='$(sql_quote "$RUN_ID")';")"
        warn_log "source was non-quiescent: ${changed_n:-0} path(s) changed during read; continuing because source_change_policy=record"
      fi
      ;;
    10)
      [ ! -s "$TMP/tar.err" ] || sed 's/^/tar: /' "$TMP/tar.err" >&2
      die "source changed during archive; strict source consistency policy refused the run (tar rc=${ps[0]}, chunker rc=${ps[1]}). Quiesce/snapshot the source or explicitly use --source-change-policy record"
      ;;
    *)
      [ ! -s "$TMP/tar.err" ] || sed 's/^/tar: /' "$TMP/tar.err" >&2
      if grep -qiE 'Permission denied|Cannot open|Cannot stat' "$TMP/tar.err" 2>/dev/null; then
          die "source became unreadable after preflight (tar rc=${ps[0]}, chunker rc=${ps[1]}); archive aborted rather than silently omitting data"
      fi
      die "tar diagnostics are not safely classifiable (tar rc=${ps[0]}, chunker rc=${ps[1]}); refusing to hide a potentially incomplete archive"
      ;;
  esac
fi
N="$(sql "SELECT n_chunks FROM runs WHERE run_id='$(sql_quote "$RUN_ID")';")"; [ "${N:-0}" -gt 0 ] || die "stream produced no chunks"
log "tar stream complete: $N chunk(s); waiting for tape drain"
"$HERE/bric-finalize.sh" --run "$RUN_ID" >&2
"$HERE/bric-close.sh" --run "$RUN_ID" >&2
COMPLETE=1; rm -rf "$TMP"; trap - EXIT INT TERM; bric_log_process_end 0; printf '%s\n' "$RUN_ID"
