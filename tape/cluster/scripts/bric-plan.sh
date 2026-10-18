#!/bin/bash
# bric-plan: plan a run and obtain a tape RESERVATION before any byte is produced.
# Review 30L: one batched SQLite transaction for the complete file/chunk map.  The source walk uses
# GNU find metadata directly (no stat subprocess per file), so large trees no longer pay 2-3 sqlite3
# process launches per path. Progress is written to the private runstate directory while planning.
set -euo pipefail
IFS=$'\n\t'
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
. "$HERE/lib_common.sh"
bric_log_process_start "bric-plan" "$@"
require_cmds sqlite3 find awk sha256sum
 enforce_bus_signing   # refuse to run unsigned when config require_bus_signing=1

PROJECT=""; SOURCE=""; KIND="ARCHIVE"; OWNER=""; LOGICAL_ROOT=""; DECLARED_SOURCE=""
while [ "$#" -gt 0 ]; do case "$1" in
    --project) PROJECT="${2:-}"; shift 2;;
    --source)  SOURCE="${2:-}";  shift 2;;
    --as)      LOGICAL_ROOT="${2:-}"; shift 2;;
    --kind)    KIND="${2:-}";    shift 2;;
    --owner)   OWNER="${2:-}";   shift 2;;
    *) die "unknown option: $1";; esac; done
[ -n "$PROJECT" ] && [ -n "$SOURCE" ] || die "usage: bric-plan --project NAME --source DIR [--kind ARCHIVE|APPEND]"
[ -d "$SOURCE" ] || die "source not found: $SOURCE"
DECLARED_SOURCE="${BRIC_SOURCE_DECLARED:-$SOURCE}"
[ -n "$LOGICAL_ROOT" ] || LOGICAL_ROOT="${BRIC_LOGICAL_ROOT:-}"
[ -n "$LOGICAL_ROOT" ] || LOGICAL_ROOT="$(bric_default_logical_root "$DECLARED_SOURCE" || true)"
LOGICAL_ROOT="$(bric_validate_logical_root "$LOGICAL_ROOT" || true)"
[ -n "$LOGICAL_ROOT" ] || die "invalid logical root; use --as with one NFC path component (max 255 bytes, no slash/control/. or ..)"
SOURCE="$(readlink -f -- "$SOURCE")"
SOURCE_CANONICAL="$SOURCE"
[ -n "$OWNER" ] || OWNER="$(bric_whoami)"
valid_name "$PROJECT" || die "invalid project name '$PROJECT' (allowed: ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}\$)"
valid_name "$OWNER"   || die "invalid owner name '$OWNER'"

if [ "$(cfg require_user_escrow)" = "1" ]; then
    user_is_escrowed "$OWNER" || die "owner '$OWNER' has no key escrow; ask BRIC IT to run bric-setup-user --user $OWNER"
fi

bric_ensure_v34_cluster_schema

TARGET="$(cfg segment_target_bytes)"; TARGET="${TARGET:-128000000000}"
META_HELPER="$HERE/../libexec/bric-file-metadata"; [ -x "$META_HELPER" ] || die "file-metadata helper missing/not executable: $META_HELPER"

sql "INSERT INTO projects (project_name,owner) VALUES ('$(sql_quote "$PROJECT")','$(sql_quote "$OWNER")')
     ON CONFLICT(project_name) DO NOTHING;"
P_OWNER="$(sql "SELECT owner FROM projects WHERE project_name='$(sql_quote "$PROJECT")';")"
[ "$P_OWNER" = "$OWNER" ] || die "project '$PROJECT' belongs to '$P_OWNER', not '$OWNER'"
EXISTING="$(sql "SELECT COUNT(*) FROM runs WHERE project_name='$(sql_quote "$PROJECT")' AND status='CLOSED';")"
[ "$EXISTING" -gt 0 ] && KIND="APPEND"

RUN_ID="$(new_run_id "$PROJECT")"
SUBMITTER="$(bric_whoami)"
INSERTED="$(sqlite3 -batch -cmd '.timeout 60000' "$BRIC_DB" "
    BEGIN IMMEDIATE;
    INSERT INTO runs (run_id,project_name,kind,source_path,submitted_by,owner,status,source_canonical_path,logical_root)
    SELECT '$(sql_quote "$RUN_ID")','$(sql_quote "$PROJECT")','$KIND','$(sql_quote "$DECLARED_SOURCE")','$(sql_quote "$SUBMITTER")','$(sql_quote "$OWNER")','PLANNING','$(sql_quote "$SOURCE_CANONICAL")','$(sql_quote "$LOGICAL_ROOT")'
    WHERE NOT EXISTS (SELECT 1 FROM runs WHERE project_name='$(sql_quote "$PROJECT")'
                        AND status IN ('PLANNING','RESERVED','PRODUCING','DRAINING','CLOSING'))
      AND NOT EXISTS (SELECT 1 FROM runs WHERE project_name='$(sql_quote "$PROJECT")' AND logical_root='$(sql_quote "$LOGICAL_ROOT")'
                        AND status IN('CLOSED','PLANNING','RESERVED','PRODUCING','DRAINING','CLOSING')
                        AND (source_canonical_path IS NULL OR source_canonical_path='' OR source_canonical_path<>'$(sql_quote "$SOURCE_CANONICAL")'));
    SELECT changes();
    COMMIT;")"
if [ "$INSERTED" != 1 ]; then
    COLLISION="$(sql "SELECT COUNT(*) FROM runs WHERE project_name='$(sql_quote "$PROJECT")' AND logical_root='$(sql_quote "$LOGICAL_ROOT")' AND status IN('CLOSED','PLANNING','RESERVED','PRODUCING','DRAINING','CLOSING') AND (source_canonical_path IS NULL OR source_canonical_path='' OR source_canonical_path<>'$(sql_quote "$SOURCE_CANONICAL")');")"
    [ "${COLLISION:-0}" -eq 0 ] || die "logical root '$LOGICAL_ROOT' is already bound to another or unknown source in project '$PROJECT'; choose a different --as name"
    die "another run is already active for project '$PROJECT' (policy: one active run per project). Wait for it to finish, or check 'bric status --project $PROJECT'."
fi
run_status_event "$RUN_ID" "$PROJECT" PLANNING "kind=$KIND owner=$OWNER source=$DECLARED_SOURCE source_canonical=$SOURCE_CANONICAL logical_root=$LOGICAL_ROOT"
log "run $RUN_ID ($KIND) planning from $SOURCE"

RUNSTATE="$(run_state_dir "$RUN_ID")"; rm -rf "$RUNSTATE"; mkdir -p "$RUNSTATE"; chmod 700 "$RUNSTATE"
PLAN_SQL="$RUNSTATE/plan.sql"
PROGRESS="$RUNSTATE/progress"
umask 077

PLAN_COMPLETE=0
plan_exit() {
    local rc=$?
    trap - EXIT INT TERM
    if [ "$PLAN_COMPLETE" -ne 1 ]; then
        sqlite3 -batch -cmd '.timeout 60000' "$BRIC_DB" \
            "UPDATE runs SET status='FAILED', error=COALESCE(error,'planning interrupted or failed') WHERE run_id='$(sql_quote "$RUN_ID")' AND status='PLANNING';" \
            >/dev/null 2>&1 || true
        run_status_event "$RUN_ID" "$PROJECT" FAILED "planning interrupted or failed rc=$rc" >/dev/null 2>&1 || true
    fi
    bric_log_process_end "$rc" || true
    exit "$rc"
}
trap plan_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

progress_write() { # stage files bytes chunks
    local tmp="$PROGRESS.tmp.$$"
    printf 'stage=%s\nfiles=%s\nbytes=%s\nchunks=%s\nupdated=%s\n' \
        "$1" "$2" "$3" "$4" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$tmp"
    mv -f "$tmp" "$PROGRESS"
}
add_member_file() { printf '%s\0' "$2" >> "$1"; }
sql_emit() { printf '%s\n' "$*" >> "$PLAN_SQL"; }

printf '%s\n' 'PRAGMA foreign_keys=ON;' 'BEGIN IMMEDIATE;' > "$PLAN_SQL"
TOTAL=0; CHUNK=1; CUR=0; MEMBER=0; TAR_OPEN=0; NCHUNKS=0; NFILES=0; NMETA=0; MEMBER_FILE=""
PROGRESS_EVERY="${BRIC_PLAN_PROGRESS_EVERY:-5000}"
case "$PROGRESS_EVERY" in ''|*[!0-9]*|0) PROGRESS_EVERY=5000;; esac

start_tar_chunk() {
    [ "$TAR_OPEN" -eq 0 ] || return 0
    sql_emit "INSERT INTO chunks (run_id,chunk_no,type,size_bytes,state) VALUES ('$RUN_ID',$CHUNK,'TAR_PART',0,'PLANNED');"
    TAR_OPEN=1; NCHUNKS=$((NCHUNKS+1)); CUR=0; MEMBER=0
    MEMBER_FILE="$(chunk_member_list "$RUN_ID" "$CHUNK")"; : > "$MEMBER_FILE"
}
close_tar_chunk() {
    [ "$TAR_OPEN" -eq 1 ] || return 0
    sql_emit "UPDATE chunks SET size_bytes=$CUR WHERE run_id='$RUN_ID' AND chunk_no=$CHUNK;"
    TAR_OPEN=0
}

progress_write scanning 0 0 0
# Deliberately no global sort: chunk membership does not require lexical order, and avoiding sort plus
# one stat process per path makes planning scale with directory enumeration rather than process count.
while IFS= read -r -d '' rel \
   && IFS= read -r -d '' sz \
   && IFS= read -r -d '' mt_raw; do
    [ -n "$rel" ] || continue
    mt="${mt_raw%%.*}"; [ -n "$mt" ] || mt=0
    TOTAL=$((TOTAL + sz)); NFILES=$((NFILES+1)); qrel=${rel//\'/\'\'}

    if [ "$sz" -gt "$TARGET" ]; then
        if [ "$TAR_OPEN" -eq 1 ]; then close_tar_chunk; CHUNK=$((CHUNK+1)); fi
        meta_line="$("$META_HELPER" capture "$SOURCE/$rel")" || die "cannot capture metadata for large file: $rel"
        IFS=$'\t' read -r fmode fmtime fmeta <<< "$meta_line"
        [ -n "$fmode" ] && [ -n "$fmtime" ] || die "invalid metadata capture for large file: $rel"
        mt="$fmtime"; mode_dec=$((8#$fmode)); qmeta=${fmeta//\'/\'\'}
        nparts=$(( (sz + TARGET - 1) / TARGET )); idx=1; off=0
        while [ "$off" -lt "$sz" ]; do
            rem=$((sz - off)); clen=$TARGET; [ "$rem" -lt "$clen" ] && clen=$rem
            sql_emit "INSERT INTO chunks (run_id,chunk_no,type,size_bytes,state,big_rel_path,chunk_index,total_chunks,offset_bytes) VALUES ('$RUN_ID',$CHUNK,'LARGE_FILE_CHUNK',$clen,'PLANNED','$qrel',$idx,$nparts,$off);"
            NCHUNKS=$((NCHUNKS+1))
            if [ "$idx" -eq 1 ]; then
                sql_emit "INSERT INTO files (run_id,rel_path,size_bytes,mtime,sha256_plain,chunk_no,member_index,entry_type,mode,metadata_b64) VALUES ('$RUN_ID','$qrel',$sz,$mt,'',$CHUNK,0,'F',$mode_dec,'$qmeta');"
            fi
            CHUNK=$((CHUNK+1)); off=$((off+clen)); idx=$((idx+1))
        done
    else
        if [ "$TAR_OPEN" -eq 1 ] && [ $((CUR + sz)) -gt "$TARGET" ]; then
            close_tar_chunk; CHUNK=$((CHUNK+1))
        fi
        start_tar_chunk
        sql_emit "INSERT INTO files (run_id,rel_path,size_bytes,mtime,sha256_plain,chunk_no,member_index,entry_type) VALUES ('$RUN_ID','$qrel',$sz,$mt,'',$CHUNK,$MEMBER,'F');"
        add_member_file "$MEMBER_FILE" "$rel"
        CUR=$((CUR + sz)); MEMBER=$((MEMBER+1))
    fi

    if [ $((NFILES % PROGRESS_EVERY)) -eq 0 ]; then
        progress_write scanning "$NFILES" "$TOTAL" "$NCHUNKS"
        log "planning progress: $NFILES files, $(awk -v b="$TOTAL" 'BEGIN{printf "%.2f", b/1099511627776}') TiB, $NCHUNKS chunk(s)"
    fi
done < <(cd "$SOURCE" && find . -type f -printf '%P\0%s\0%T@\0')

if [ "$TAR_OPEN" -eq 1 ]; then close_tar_chunk; CHUNK=$((CHUNK+1)); fi

DIRS_TMP="$RUNSTATE/.dirs"; LINKS_TMP="$RUNSTATE/.links"
( cd "$SOURCE" && find . -mindepth 1 -type d -printf '%P\0' ) > "$DIRS_TMP"
( cd "$SOURCE" && find . -type l -printf '%P\0' ) > "$LINKS_TMP"
if [ -s "$DIRS_TMP" ] || [ -s "$LINKS_TMP" ]; then
    META="$CHUNK"
    MEMBER_FILE="$(chunk_member_list "$RUN_ID" "$META")"; : > "$MEMBER_FILE"
    sql_emit "INSERT INTO chunks (run_id,chunk_no,type,size_bytes,state) VALUES ('$RUN_ID',$META,'TAR_PART',0,'PLANNED');"
    NCHUNKS=$((NCHUNKS+1)); mi=0; nmeta=0
    while IFS= read -r -d '' d; do
        [ -n "$d" ] || continue
        qmeta=${d//\'/\'\'}
        sql_emit "INSERT OR IGNORE INTO files (run_id,rel_path,size_bytes,sha256_plain,chunk_no,member_index,entry_type) VALUES ('$RUN_ID','$qmeta',0,'',$META,$mi,'D');"
        add_member_file "$MEMBER_FILE" "$d"; mi=$((mi+1)); nmeta=$((nmeta+1)); NMETA=$((NMETA+1))
    done < "$DIRS_TMP"
    while IFS= read -r -d '' l; do
        [ -n "$l" ] || continue
        qmeta=${l//\'/\'\'}
        sql_emit "INSERT OR IGNORE INTO files (run_id,rel_path,size_bytes,sha256_plain,chunk_no,member_index,entry_type) VALUES ('$RUN_ID','$qmeta',0,'',$META,$mi,'L');"
        add_member_file "$MEMBER_FILE" "$l"; mi=$((mi+1)); nmeta=$((nmeta+1)); NMETA=$((NMETA+1))
    done < "$LINKS_TMP"
    log "metadata chunk $META: $nmeta tree entr(y/ies) (directories incl. empty + symlinks)"
fi
rm -f "$DIRS_TMP" "$LINKS_TMP"

NSPECIAL="$(cd "$SOURCE" && find . \( -type p -o -type s -o -type b -o -type c \) -printf 'x\n' 2>/dev/null | wc -l | tr -d ' ')"
[ "${NSPECIAL:-0}" -gt 0 ] && log "WARNING: skipped $NSPECIAL special file(s) (fifo/socket/device) — not archived"

[ "$NCHUNKS" -gt 0 ] || {
    sql "UPDATE runs SET status='FAILED',error='no files' WHERE run_id='$RUN_ID';"
    run_status_event "$RUN_ID" "$PROJECT" FAILED "no files"
    bric_notify BACKUP_FAILED "$OWNER" "$RUN_ID" "no files under $SOURCE"
    die "no files under $SOURCE"
}

sql_emit "UPDATE runs SET n_chunks=$NCHUNKS, total_bytes=$TOTAL WHERE run_id='$RUN_ID';"
sql_emit 'COMMIT;'
progress_write database "$NFILES" "$TOTAL" "$NCHUNKS"
log "committing planning map in one SQLite transaction: $NFILES regular files, $NMETA metadata entries, $NCHUNKS chunks"
sqlite3 -batch -cmd '.timeout 60000' "$BRIC_DB" < "$PLAN_SQL"
rm -f "$PLAN_SQL"
progress_write reservation "$NFILES" "$TOTAL" "$NCHUNKS"

NMEMB=$((NFILES + NMETA))
OVH_PCT="$(cfg reservation_overhead_pct)"; case "$OVH_PCT" in ''|*[!0-9]*) OVH_PCT=2;; esac
REQ_BYTES="$(awk -v t="$TOTAL" -v m="$NMEMB" -v c="$NCHUNKS" -v p="$OVH_PCT" 'BEGIN{printf "%.0f", (t + m*1024 + c*1056)*(1+p/100)}')"
REQ_TB="$(awk -v b="$REQ_BYTES" 'BEGIN{printf "%.6f", b/1000000000000}')"
log "planned $NCHUNKS chunk(s), $(awk -v b="$TOTAL" 'BEGIN{printf "%.2f", b/1099511627776}') TiB plaintext; reserving for $(awk -v b="$REQ_BYTES" 'BEGIN{printf "%.2f", b/1099511627776}') TiB (incl. ${OVH_PCT}% + framing)"

RUN_DIR="$(qnap_run_dir "$PROJECT" "$RUN_ID")"; mkdir -p "$RUN_DIR"
sql "INSERT INTO reservation (run_id,project_name,requested_tb,n_pairs,state) VALUES ('$RUN_ID','$(sql_quote "$PROJECT")',$REQ_TB,0,'REQUESTED');"
marker_set_signed "$RUN_DIR" "run.RESERVE_REQUEST" "run_id=$RUN_ID
project=$PROJECT
owner=$OWNER
requested_bytes=$REQ_BYTES
n_chunks=$NCHUNKS"
log "reservation requested; waiting for the tape server..."

ANS="$(marker_wait "$RUN_DIR" "run.RESERVED" "run.DENIED" "${BRIC_RESERVE_TIMEOUT:-600}")" || die "timed out waiting for tape reservation"
marker_verify "$RUN_DIR" "$ANS" || die "tape server response '$ANS' failed signature verification (forged?)"
[ "$(marker_field run_id "$RUN_DIR/$ANS")" = "$RUN_ID" ] || die "tape server response not bound to this run"
if [ "$ANS" = "run.DENIED" ]; then
    reason="$(marker_field reason "$RUN_DIR/run.DENIED")"; [ -n "$reason" ] || reason="$(marker_read "$RUN_DIR" run.DENIED)"
    sql "UPDATE runs SET status='DENIED',error='$(sql_quote "$reason")' WHERE run_id='$RUN_ID';"
    sql "UPDATE reservation SET state='DENIED' WHERE run_id='$RUN_ID';"
    audit DENIED "$RUN_ID" FAIL "$reason"
    bric_notify BACKUP_DENIED "$OWNER" "$RUN_ID" "$reason"
    bus_cleanup_run_dir "$PROJECT" "$RUN_ID" DENIED || warn_log "DENIED run recorded but QNAP bus cleanup was deferred: $RUN_DIR"
    die "tape reservation DENIED: $reason"
fi
NPAIRS="$(marker_read "$RUN_DIR" run.RESERVED | awk -F= '/^pairs=/{print $2}')"
sql "UPDATE runs SET status='RESERVED' WHERE run_id='$RUN_ID';"
run_status_event "$RUN_ID" "$PROJECT" RESERVED "tape reservation granted"
sql "UPDATE reservation SET state='GRANTED', n_pairs='${NPAIRS:-0}', granted_at=datetime('now'), heartbeat_at=datetime('now') WHERE run_id='$RUN_ID';"
audit RUN_RESERVED "$RUN_ID" OK "project=$PROJECT kind=$KIND chunks=$NCHUNKS pairs=${NPAIRS:-?}"
log "reservation GRANTED (pairs reserved: ${NPAIRS:-?})"
bric_notify BACKUP_START "$OWNER" "$RUN_ID" "project=$PROJECT kind=$KIND chunks=$NCHUNKS bytes=$TOTAL pairs=${NPAIRS:-?} source=$SOURCE"
progress_write reserved "$NFILES" "$TOTAL" "$NCHUNKS"
PLAN_COMPLETE=1
printf '%s\n' "$RUN_ID"
