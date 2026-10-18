#!/bin/bash
# Reserve initial project capacity for a tar-driven one-pass local backup. Review 31 records the
# pre-reservation source scan and every explicit exclusion before any tape write can occur.
set -euo pipefail
IFS=$'\n\t'
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
. "$HERE/lib_common.sh"
bric_log_process_start "bric-stream-plan" "$@"
require_cmds sqlite3 awk
enforce_bus_signing
PROJECT=""; SOURCE=""; OWNER=""; KIND="ARCHIVE"; SOURCE_CHANGE_POLICY="strict"; LOGICAL_ROOT=""; DECLARED_SOURCE=""
declare -a EXCLUDES=() EXCLUDE_REASONS=()
while [ "$#" -gt 0 ]; do case "$1" in
  --project) PROJECT="${2:-}"; shift 2;; --source) SOURCE="${2:-}"; shift 2;;
  --as) LOGICAL_ROOT="${2:-}"; shift 2;;
  --owner) OWNER="${2:-}"; shift 2;; --kind) KIND="${2:-}"; shift 2;;
  --source-change-policy) SOURCE_CHANGE_POLICY="${2:-}"; shift 2;;
  --exclude)
    [ "$#" -ge 2 ] || die "--exclude requires a relative path"
    ex="$(bric_normalize_exclude_rel "$2" || true)"; [ -n "$ex" ] || die "invalid exclusion '$2'"
    EXCLUDES+=("$ex"); EXCLUDE_REASONS+=("user-declared"); shift 2;;
  --forced-exclude)
    [ "$#" -ge 2 ] || die "--forced-exclude requires a relative path"
    ex="$(bric_normalize_exclude_rel "$2" || true)"; [ -n "$ex" ] || die "invalid forced exclusion '$2'"
    EXCLUDES+=("$ex"); EXCLUDE_REASONS+=("force-unreadable"); shift 2;;
  *) die "unknown option: $1";; esac; done
[ -n "$PROJECT" ] && [ -n "$SOURCE" ] || die "usage: bric-stream-plan --project NAME --source DIR [--exclude RELPATH ...] [--source-change-policy strict|record]"
case "$SOURCE_CHANGE_POLICY" in strict|record) :;; *) die "invalid source change policy '$SOURCE_CHANGE_POLICY'";; esac
[ -d "$SOURCE" ] || die "source not found: $SOURCE"
DECLARED_SOURCE="${BRIC_SOURCE_DECLARED:-$SOURCE}"
[ -n "$LOGICAL_ROOT" ] || LOGICAL_ROOT="${BRIC_LOGICAL_ROOT:-}"
[ -n "$LOGICAL_ROOT" ] || LOGICAL_ROOT="$(bric_default_logical_root "$DECLARED_SOURCE" || true)"
LOGICAL_ROOT="$(bric_validate_logical_root "$LOGICAL_ROOT" || true)"
[ -n "$LOGICAL_ROOT" ] || die "invalid logical root; use --as with one NFC path component (max 255 bytes, no slash/control/. or ..)"
SOURCE="$(readlink -f -- "$SOURCE")"
SOURCE_CANONICAL="$SOURCE"
[ -n "$OWNER" ] || OWNER="$(bric_whoami)"
valid_name "$PROJECT" || die "invalid project name '$PROJECT'"
valid_name "$OWNER" || die "invalid owner name '$OWNER'"
if [ "$(cfg require_user_escrow)" = 1 ]; then user_is_escrowed "$OWNER" || die "owner '$OWNER' has no key escrow"; fi

# Additive Review-32B5 schema is created lazily at the first new backup. Older catalogs remain readable.
bric_ensure_v34_cluster_schema

sql "INSERT INTO projects(project_name,owner) VALUES('$(sql_quote "$PROJECT")','$(sql_quote "$OWNER")') ON CONFLICT(project_name) DO NOTHING;"
P_OWNER="$(sql "SELECT owner FROM projects WHERE project_name='$(sql_quote "$PROJECT")';")"
[ "$P_OWNER" = "$OWNER" ] || die "project '$PROJECT' belongs to '$P_OWNER', not '$OWNER'"
EXISTING="$(sql "SELECT COUNT(*) FROM runs WHERE project_name='$(sql_quote "$PROJECT")' AND status='CLOSED';")"
[ "$EXISTING" -gt 0 ] && KIND=APPEND
RUN_ID="$(new_run_id "$PROJECT")"; SUBMITTER="$(bric_whoami)"

# Run creation + source-scope record are one transaction. If exclusions cannot be recorded, the run does
# not exist and therefore cannot reserve tape with an ambiguous scope.
SQLX=""
i=0
declare -A seen=()
for idx in "${!EXCLUDES[@]}"; do
    ex="${EXCLUDES[$idx]}"; reason="${EXCLUDE_REASONS[$idx]:-user-declared}"
    [ -z "${seen[$ex]:-}" ] || die "duplicate exclusion: $ex"
    seen[$ex]=1; i=$((i+1))
    SQLX+="INSERT INTO run_exclusions(run_id,ordinal,rel_path,reason) SELECT '$(sql_quote "$RUN_ID")',$i,'$(sql_quote "$ex")','$(sql_quote "$reason")' WHERE EXISTS(SELECT 1 FROM runs WHERE run_id='$(sql_quote "$RUN_ID")');"
done
SCAN_FILES="${BRIC_SOURCE_PREFLIGHT_FILES:-0}"
SCAN_LOGICAL="${BRIC_SOURCE_PREFLIGHT_LOGICAL_BYTES:-0}"
SCAN_ALLOC="${BRIC_SOURCE_PREFLIGHT_ALLOCATED_BYTES:-0}"
SCAN_EXCL="${BRIC_SOURCE_PREFLIGHT_EXCLUSION_COUNT:-${#EXCLUDES[@]}}"
SCAN_UID="${BRIC_SOURCE_PREFLIGHT_UID:-$(id -u)}"
for v in SCAN_FILES SCAN_LOGICAL SCAN_ALLOC SCAN_EXCL SCAN_UID; do
    case "${!v}" in ''|*[!0-9]*) printf -v "$v" '%s' 0;; esac
done
INSERTED="$(sqlite3 -batch -cmd '.timeout 60000' "$BRIC_DB" "
BEGIN IMMEDIATE;
INSERT INTO runs(run_id,project_name,kind,source_path,submitted_by,owner,status,source_canonical_path,logical_root)
SELECT '$(sql_quote "$RUN_ID")','$(sql_quote "$PROJECT")','$KIND','$(sql_quote "$DECLARED_SOURCE")','$(sql_quote "$SUBMITTER")','$(sql_quote "$OWNER")','PLANNING','$(sql_quote "$SOURCE_CANONICAL")','$(sql_quote "$LOGICAL_ROOT")'
WHERE NOT EXISTS(SELECT 1 FROM runs WHERE project_name='$(sql_quote "$PROJECT")' AND status IN('PLANNING','RESERVED','PRODUCING','DRAINING','CLOSING'))
  AND NOT EXISTS(SELECT 1 FROM runs WHERE project_name='$(sql_quote "$PROJECT")' AND logical_root='$(sql_quote "$LOGICAL_ROOT")'
                 AND status IN('CLOSED','PLANNING','RESERVED','PRODUCING','DRAINING','CLOSING')
                 AND (source_canonical_path IS NULL OR source_canonical_path='' OR source_canonical_path<>'$(sql_quote "$SOURCE_CANONICAL")'));
SELECT changes();
$SQLX
INSERT OR REPLACE INTO run_source_scan(run_id,regular_files,logical_bytes,allocated_bytes,exclusion_count,scanner_uid)
SELECT '$(sql_quote "$RUN_ID")',$SCAN_FILES,$SCAN_LOGICAL,$SCAN_ALLOC,$SCAN_EXCL,$SCAN_UID
WHERE EXISTS(SELECT 1 FROM runs WHERE run_id='$(sql_quote "$RUN_ID")');
INSERT OR REPLACE INTO run_source_semantics(run_id,sparse_map_method,allocation_topology,restore_allocation_effect,source_change_policy,source_consistency,source_changed_count)
SELECT '$(sql_quote "$RUN_ID")','gnu-pax-0.1-map','not-guaranteed','zero-ranges-may-restore-as-holes','$(sql_quote "$SOURCE_CHANGE_POLICY")','pending',0
WHERE EXISTS(SELECT 1 FROM runs WHERE run_id='$(sql_quote "$RUN_ID")');
COMMIT;")"
if [ "$(printf '%s\n' "$INSERTED" | head -1)" != 1 ]; then
    COLLISION="$(sql "SELECT COUNT(*) FROM runs WHERE project_name='$(sql_quote "$PROJECT")' AND logical_root='$(sql_quote "$LOGICAL_ROOT")' AND status IN('CLOSED','PLANNING','RESERVED','PRODUCING','DRAINING','CLOSING') AND (source_canonical_path IS NULL OR source_canonical_path='' OR source_canonical_path<>'$(sql_quote "$SOURCE_CANONICAL")');")"
    [ "${COLLISION:-0}" -eq 0 ] || die "logical root '$LOGICAL_ROOT' is already bound to another or unknown source in project '$PROJECT'; choose a different --as name"
    die "another run is already active for project '$PROJECT'"
fi

RUNSTATE="$(run_state_dir "$RUN_ID")"; rm -rf "$RUNSTATE"; mkdir -p "$RUNSTATE"; chmod 700 "$RUNSTATE"
printf 'stage=reservation\nfiles=0\nbytes=0\nchunks=0\nupdated=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$RUNSTATE/progress"
run_status_event "$RUN_ID" "$PROJECT" PLANNING "logical_root=$LOGICAL_ROOT source_declared=$DECLARED_SOURCE source_canonical=$SOURCE_CANONICAL; source_preflight_files=$SCAN_FILES logical_bytes=$SCAN_LOGICAL storage_accounted_bytes=$SCAN_ALLOC exclusions=${#EXCLUDES[@]} source_change_policy=$SOURCE_CHANGE_POLICY sparse_map=gnu-pax-0.1"

TARGET="$(cfg segment_target_bytes)"; TARGET="${TARGET:-128000000000}"
INITIAL="${BRIC_STREAM_INITIAL_RESERVATION_BYTES:-$((TARGET + TARGET/10))}"
case "$INITIAL" in ''|*[!0-9]*|0) INITIAL=$((TARGET + TARGET/10));; esac
RUN_DIR="$(qnap_run_dir "$PROJECT" "$RUN_ID")"; mkdir -p "$RUN_DIR"
sql "INSERT INTO reservation(run_id,project_name,requested_tb,n_pairs,state) VALUES('$(sql_quote "$RUN_ID")','$(sql_quote "$PROJECT")',$(awk -v b="$INITIAL" 'BEGIN{printf "%.6f",b/1000000000000}'),0,'REQUESTED');"
marker_set_signed "$RUN_DIR" run.RESERVE_REQUEST "run_id=$RUN_ID
project=$PROJECT
owner=$OWNER
requested_bytes=$INITIAL
n_chunks=streaming"
log "stream reservation requested for initial $INITIAL bytes; waiting for tape server"
ANS="$(marker_wait "$RUN_DIR" run.RESERVED run.DENIED "${BRIC_RESERVE_TIMEOUT:-600}")" || die "timed out waiting for tape reservation"
marker_verify "$RUN_DIR" "$ANS" || die "tape reservation response failed signature verification"
[ "$(marker_field run_id "$RUN_DIR/$ANS")" = "$RUN_ID" ] || die "reservation response not bound to this run"
if [ "$ANS" = run.DENIED ]; then
  reason="$(marker_field reason "$RUN_DIR/run.DENIED")"; [ -n "$reason" ] || reason="$(marker_read "$RUN_DIR" run.DENIED)"
  sql "UPDATE runs SET status='DENIED',error='$(sql_quote "$reason")' WHERE run_id='$(sql_quote "$RUN_ID")'; UPDATE reservation SET state='DENIED' WHERE run_id='$(sql_quote "$RUN_ID")';"
  run_status_event "$RUN_ID" "$PROJECT" DENIED "$reason"
  audit DENIED "$RUN_ID" FAIL "$reason"
  bric_notify BACKUP_DENIED "$OWNER" "$RUN_ID" "$reason"
  bus_cleanup_run_dir "$PROJECT" "$RUN_ID" DENIED || warn_log "DENIED run recorded but QNAP bus cleanup was deferred: $RUN_DIR"
  die "tape reservation DENIED: $reason"
fi
NPAIRS="$(marker_field pairs "$RUN_DIR/run.RESERVED")"; CAP="$(marker_field capacity_bytes "$RUN_DIR/run.RESERVED")"
case "$CAP" in ''|*[!0-9]*) die "tape server did not return numeric capacity_bytes (upgrade tape side to Review 30M+)";; esac
printf '%s\n' "$CAP" > "$RUNSTATE/reserved_capacity"; chmod 600 "$RUNSTATE/reserved_capacity"
sql "UPDATE runs SET status='RESERVED' WHERE run_id='$(sql_quote "$RUN_ID")'; UPDATE reservation SET state='GRANTED',n_pairs='${NPAIRS:-0}',granted_at=datetime('now'),heartbeat_at=datetime('now') WHERE run_id='$(sql_quote "$RUN_ID")';"
run_status_event "$RUN_ID" "$PROJECT" RESERVED "initial stream capacity=$CAP"
audit RUN_RESERVED "$RUN_ID" OK "project=$PROJECT kind=$KIND streaming=1 pairs=${NPAIRS:-?} capacity_bytes=$CAP exclusions=${#EXCLUDES[@]} source_change_policy=$SOURCE_CHANGE_POLICY"
log "initial stream reservation GRANTED: pairs=${NPAIRS:-?}, logical capacity=$CAP bytes"
bric_notify BACKUP_START "$OWNER" "$RUN_ID" "project=$PROJECT kind=$KIND mode=tar-stream initial_pairs=${NPAIRS:-?} initial_capacity_bytes=$CAP source=$DECLARED_SOURCE logical_root=$LOGICAL_ROOT exclusions=${#EXCLUDES[@]}"
printf '%s\n' "$RUN_ID"
