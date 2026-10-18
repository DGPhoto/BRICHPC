#!/bin/bash
# bric-restore: restore a whole run or a single file FROM TAPE via the reverse bus.
# The cluster (which alone holds the file->chunk map and the keys) asks the tape server to stage
# the needed chunk blobs back onto the QNAP, then decrypts, places and verifies them.
set -euo pipefail
IFS=$'\n\t'
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
. "$HERE/lib_common.sh"
. "$HERE/lib_restore_txn.sh"
META_HELPER="$HERE/../libexec/bric-file-metadata"; [ -x "$META_HELPER" ] || die "file-metadata helper missing/not executable: $META_HELPER"
bric_log_process_start "bric-restore" "$@"
require_cmds sqlite3 openssl tar sha256sum awk stat sync
enforce_bus_signing   # refuse to run unsigned when config require_bus_signing=1

PROJECT=""; DEST=""; FILE=""; RUN_ID=""; REQUIRE_DEST_VERIFY=0; ALLOW_METADATA_DEGRADATION=0; METADATA_DEGRADED=0
while [ "$#" -gt 0 ]; do case "$1" in
    --project) PROJECT="${2:-}"; shift 2;; --dest) DEST="${2:-}"; shift 2;;
    --file) FILE="${2:-}"; shift 2;; --run) RUN_ID="${2:-}"; shift 2;;
    --require-destination-verify) REQUIRE_DEST_VERIFY=1; shift;;
    --allow-metadata-degradation) ALLOW_METADATA_DEGRADATION=1; shift;;
    *) die "unknown option: $1";; esac; done
[ -n "$PROJECT" ] && [ -n "$DEST" ] || die "usage: bric restore --project NAME --dest DIR [--file REL] [--run RUN_ID] [--require-destination-verify] [--allow-metadata-degradation]"

OWNER="$(sql "SELECT owner FROM projects WHERE project_name='$(sql_quote "$PROJECT")';")"
[ -n "$OWNER" ] || die "unknown project: $PROJECT"

# Review 32B5 upgrades/backfills only catalog metadata; no payload or on-tape data is rewritten.
bric_ensure_v34_cluster_schema
REQUESTED_FILE="$FILE"
RESTORE_REL="$FILE"       # destination-relative path for a selected object
RESTORE_PREFIX=""          # logical root used only as extraction destination prefix

validate_restore_path() { # relative path, no traversal/empty components
    local p="$1" seg oldifs
    [ -n "$p" ] || return 1
    case "$p" in /*) return 1;; esac
    oldifs="$IFS"; IFS='/'; read -r -a _bric_restore_parts <<< "$p"; IFS="$oldifs"
    for seg in "${_bric_restore_parts[@]}"; do
        [ -n "$seg" ] && [ "$seg" != "." ] && [ "$seg" != ".." ] || return 1
    done
    return 0
}
[ -z "$FILE" ] || validate_restore_path "$FILE" || die "unsafe --file path: $FILE"

# Explicit --run remains an immutable run view and accepts the historical bare run-relative path.
# A namespaced path ROOT/REL is stripped to the physical catalog/TAR member REL and restored below ROOT/.
if [ -n "$RUN_ID" ]; then
    RUN_STATE="$(sql "SELECT status FROM runs WHERE run_id='$(sql_quote "$RUN_ID")' AND project_name='$(sql_quote "$PROJECT")';")"
    [ -n "$RUN_STATE" ] || die "run '$RUN_ID' does not belong to project '$PROJECT'"
    [ "$RUN_STATE" = CLOSED ] || die "run '$RUN_ID' is $RUN_STATE; restore requires a CLOSED run"
    if [ -n "$FILE" ]; then
        RUN_ROOT="$(sql "SELECT COALESCE(logical_root,'') FROM runs WHERE run_id='$(sql_quote "$RUN_ID")';")"
        if [ -n "$RUN_ROOT" ] && [[ "$FILE" == "$RUN_ROOT/"* ]]; then
            FILE="${FILE#"$RUN_ROOT/"}"
            [ -n "$FILE" ] || die "--file must name an object below logical root '$RUN_ROOT'"
            RESTORE_PREFIX="$RUN_ROOT"; RESTORE_REL="$RUN_ROOT/$FILE"
        else
            FIRST="${FILE%%/*}"
            if [[ "$FILE" == */* ]] && [ -n "$RUN_ROOT" ] && [ "$FIRST" != "$RUN_ROOT" ] \
               && [ "$(sql "SELECT COUNT(*) FROM runs WHERE project_name='$(sql_quote "$PROJECT")' AND status='CLOSED' AND logical_root='$(sql_quote "$FIRST")';")" -gt 0 ]; then
                die "logical root '$FIRST' does not match run '$RUN_ID' (root '$RUN_ROOT')"
            fi
            RESTORE_REL="$FILE"  # legacy --run behavior: restore directly below DEST
        fi
        PRESENT="$(sql "SELECT COUNT(*) FROM files WHERE run_id='$(sql_quote "$RUN_ID")' AND rel_path='$(sql_quote "$FILE")';")"
        BIG_PRESENT="$(sql "SELECT COUNT(*) FROM chunks WHERE run_id='$(sql_quote "$RUN_ID")' AND big_rel_path='$(sql_quote "$FILE")';")"
        [ "$PRESENT" -gt 0 ] || [ "$BIG_PRESENT" -gt 0 ] || die "file not in run: $REQUESTED_FILE"
    fi
else
    if [ -n "$FILE" ]; then
        # Prefer the 32B5 logical namespace ROOT/REL. If that does not match, retain an unambiguous
        # legacy bare-path lookup for compatibility; ambiguous bare paths are rejected.
        FOUND_RUN=""; ROOT=""; REL=""
        if [[ "$FILE" == */* ]]; then
            ROOT="${FILE%%/*}"; REL="${FILE#*/}"
            FOUND_RUN="$(sql "SELECT r.run_id FROM runs r JOIN files f ON f.run_id=r.run_id
                WHERE r.project_name='$(sql_quote "$PROJECT")' AND r.status='CLOSED'
                  AND r.logical_root='$(sql_quote "$ROOT")' AND f.rel_path='$(sql_quote "$REL")'
                ORDER BY COALESCE(r.closed_at,r.requested_at,'') DESC,COALESCE(r.requested_at,'') DESC,r.run_id DESC LIMIT 1;")"
        fi
        if [ -n "$FOUND_RUN" ]; then
            RUN_ID="$FOUND_RUN"; FILE="$REL"; RESTORE_PREFIX="$ROOT"; RESTORE_REL="$ROOT/$REL"
        else
            ROOT_COUNT="$(sql "SELECT COUNT(DISTINCT COALESCE(NULLIF(r.logical_root,''),'legacy-'||r.run_id))
                FROM runs r JOIN files f ON f.run_id=r.run_id
                WHERE r.project_name='$(sql_quote "$PROJECT")' AND r.status='CLOSED' AND f.rel_path='$(sql_quote "$FILE")';")"
            [ "$ROOT_COUNT" -gt 0 ] || die "file not found in any closed run: $REQUESTED_FILE"
            [ "$ROOT_COUNT" -eq 1 ] || die "legacy bare path is ambiguous across $ROOT_COUNT logical roots: $REQUESTED_FILE; use LOGICAL_ROOT/RELATIVE_PATH"
            RUN_ID="$(sql "SELECT r.run_id FROM runs r JOIN files f ON f.run_id=r.run_id
                WHERE r.project_name='$(sql_quote "$PROJECT")' AND r.status='CLOSED' AND f.rel_path='$(sql_quote "$FILE")'
                ORDER BY COALESCE(r.closed_at,r.requested_at,'') DESC,COALESCE(r.requested_at,'') DESC,r.run_id DESC LIMIT 1;")"
            ROOT="$(sql "SELECT COALESCE(NULLIF(logical_root,''),'legacy-'||run_id) FROM runs WHERE run_id='$(sql_quote "$RUN_ID")';")"
            RESTORE_PREFIX="$ROOT"; RESTORE_REL="$ROOT/$FILE"
        fi
    else
        RUN_ID="$(sql "SELECT run_id FROM runs WHERE project_name='$(sql_quote "$PROJECT")' AND status='CLOSED' ORDER BY COALESCE(closed_at,requested_at,'') DESC,requested_at DESC,run_id DESC LIMIT 1;")"
        [ -n "$RUN_ID" ] || die "no closed run for project: $PROJECT"
    fi
fi

# Defense in depth against path traversal: the ciphertext is HMAC-verified before decrypt and GNU tar
# strips leading '/' and refuses '..' members by default, but we also explicitly refuse up front if the
# cluster catalog lists any entry whose rel_path escapes DEST (absolute or containing a '..' component).
# Notify + failure trap: RESTORE_START now that owner and run are resolved; any nonzero exit after
# this point (every `die` in this script) produces one RESTORE_FAILED with the same identifiers.
# The trap is cleared on the success path before RESTORE_DONE is sent.
bric_notify RESTORE_START "$OWNER" "$RUN_ID" "project=$PROJECT dest=$DEST${REQUESTED_FILE:+ file=$REQUESTED_FILE}"
# Never place a passphrase on the shared reverse bus.  Keep all secret-bearing scratch on local
# cluster storage and clean it on every exit path.
LOCAL_TMP_ROOT="${BRIC_LOCAL_TMPDIR:-/tmp}"
[ -d "$LOCAL_TMP_ROOT" ] && [ -w "$LOCAL_TMP_ROOT" ] || die "local temp root is not writable: $LOCAL_TMP_ROOT"
LOCAL_TMP="$(mktemp -d "$LOCAL_TMP_ROOT/bric-restore.XXXXXX")"
RDIR=""
_restore_exit() {
    local rc=$?
    trap - EXIT
    # A normal timeout/error must not leave the tape server staging terabytes for a client that has
    # already declared the job failed. Publish a signed cancellation; the daemon stops at the next
    # chunk boundary (never interrupts a tape file mid-stream) and discards staged ciphertext.
    if [ "$rc" -ne 0 ] && [ -n "${RDIR:-}" ] && [ -d "$RDIR" ] && [ ! -e "$RDIR/request.STAGED" ]; then
        ( marker_set_signed "$RDIR" request.CANCELLED "run=$RUN_ID
project=$PROJECT
reason=cluster restore exited rc=$rc
cancelled_epoch=$(date +%s)" ) >/dev/null 2>&1 || true
    fi
    if [ "$rc" -ne 0 ] && [ "${RTXN_ACTIVE:-0}" = 1 ] && [ "${RTXN_PRESERVE:-0}" = 0 ]; then
        rtxn_abort || warn_log "restore metadata rollback incomplete; journal preserved at ${RTXN_DB:-unknown}"
    fi
    rm -rf "$LOCAL_TMP"
    if [ "$rc" -ne 0 ]; then
        bric_notify RESTORE_FAILED "$OWNER" "$RUN_ID" "restore did not complete (see operator log on $(hostname)); dest=$DEST${REQUESTED_FILE:+ file=$REQUESTED_FILE}"
    fi
    bric_log_process_end "$rc"
    exit "$rc"
}
trap _restore_exit EXIT

BADPATH="$(sql "SELECT COUNT(*) FROM files WHERE run_id='$(sql_quote "$RUN_ID")' AND (rel_path LIKE '/%' OR rel_path LIKE '%../%' OR rel_path LIKE '../%' OR rel_path LIKE '%/..' OR rel_path='..');")"
[ "${BADPATH:-0}" = 0 ] || die "refusing restore: $BADPATH catalog entr(y/ies) have unsafe paths (absolute or '..') for run $RUN_ID"

# Which chunks do we need?
declare -a NEED_CHUNKS=()
if [ -n "$FILE" ]; then
    BIGPARTS="$(sql "SELECT COUNT(*) FROM chunks WHERE run_id='$(sql_quote "$RUN_ID")' AND big_rel_path='$(sql_quote "$FILE")';")"
    if [ "$BIGPARTS" -gt 0 ]; then
        while read -r c; do NEED_CHUNKS+=("$c"); done < <(sql "SELECT chunk_no FROM chunks WHERE run_id='$(sql_quote "$RUN_ID")' AND big_rel_path='$(sql_quote "$FILE")' ORDER BY chunk_index;")
    else
        c="$(sql "SELECT chunk_no FROM files WHERE run_id='$(sql_quote "$RUN_ID")' AND rel_path='$(sql_quote "$FILE")';")"
        [ -n "$c" ] || die "file not in run: $FILE"
        NEED_CHUNKS+=("$c")
    fi
else
    while read -r c; do NEED_CHUNKS+=("$c"); done < <(sql "SELECT chunk_no FROM chunks WHERE run_id='$(sql_quote "$RUN_ID")' ORDER BY chunk_no;")
fi
[ "${#NEED_CHUNKS[@]}" -gt 0 ] || die "nothing to restore"

# Review 34R2rc3 B3 recovery path. Metadata-degraded restores are intentionally restricted to a
# fresh/empty destination: journal fallback may skip ACL/xattr reapplication, which is safe for a new
# recovery tree but must never be used to mutate pre-existing destination content. This check happens
# before the tape request so an unsafe request cannot start robotics/staging.
if [ "$ALLOW_METADATA_DEGRADATION" -eq 1 ]; then
    if [ -e "$DEST" ]; then
        [ -d "$DEST" ] && [ ! -L "$DEST" ] || die "--allow-metadata-degradation requires a directory destination: $DEST"
        [ -z "$(find "$DEST" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ] || die "--allow-metadata-degradation requires an empty destination: $DEST"
    else
        mkdir -p "$DEST" || die "cannot create degraded-restore destination: $DEST"
    fi
    export BRIC_RESTORE_ALLOW_METADATA_DEGRADATION=1
    if [ "$(sql "SELECT COUNT(*) FROM chunks WHERE run_id='$(sql_quote "$RUN_ID")' AND chunk_no IN ($(IFS=,; echo "${NEED_CHUNKS[*]}")) AND type='TAR_PART';")" -gt 0 ]; then
        METADATA_DEGRADED=1
        warn_log "metadata degradation explicitly allowed: TAR_PART payload will restore with --no-xattrs --no-acls; ACL/xattr fidelity is NOT guaranteed"
    fi
fi

# Ask the tape server for a progressive restore. New tape daemons use READY/CONSUMED backpressure
# (one staged chunk at a time); older daemons ignore the protocol line and remain compatible.
REQ_ID="$(printf '%s__restore__%s__%s' "$PROJECT" "$(date -u +%Y%m%dT%H%M%SZ)" "$$")"
RDIR="$(qnap_restore_dir "$PROJECT" "$REQ_ID")"; mkdir -p "$RDIR"
REQ_BODY="$({ printf 'owner=%s\nproject=%s\nrun=%s\nprotocol=restore-progressive-v1\n' "$OWNER" "$PROJECT" "$RUN_ID"
  for c in "${NEED_CHUNKS[@]}"; do printf 'stage|%s|%s\n' "$RUN_ID" "$c"; done; })"
marker_set_signed "$RDIR" request "$REQ_BODY"
log "restore $REQ_ID: requested ${#NEED_CHUNKS[@]} chunk(s) from tape; progressive staging enabled"

# Secret-bearing state remains local to the cluster host.
UKF="$(user_key_file "$OWNER")"; [ -f "$UKF" ] || die "user key not found for $OWNER"
derive_keys "$(cat "$UKF")"
PASS="$LOCAL_TMP/.pass"; printf '%s' "$ENC_KEY" > "$PASS"; chmod 600 "$PASS"
mkdir -p "$DEST"
rtxn_begin "$DEST" "restore:$PROJECT:$RUN_ID" || die "cannot initialize restore metadata transaction for $DEST"

# Backward compatibility: BRIC_RESTORE_TIMEOUT, when explicitly set by an older config/test, is used
# for both queue and inactivity waits. New defaults distinguish queueing from a stalled active read:
# a request may legitimately wait behind another restore for many hours, but once signed progress
# starts, 30 minutes without a heartbeat is considered a stall.
RESTORE_QUEUE_TIMEOUT="${BRIC_RESTORE_QUEUE_TIMEOUT:-${BRIC_RESTORE_TIMEOUT:-86400}}"
RESTORE_INACTIVITY_TIMEOUT="${BRIC_RESTORE_INACTIVITY_TIMEOUT:-${BRIC_RESTORE_TIMEOUT:-1800}}"
case "$RESTORE_QUEUE_TIMEOUT" in ''|*[!0-9]*|0) die "invalid restore queue timeout: $RESTORE_QUEUE_TIMEOUT";; esac
case "$RESTORE_INACTIVITY_TIMEOUT" in ''|*[!0-9]*|0) die "invalid restore inactivity timeout: $RESTORE_INACTIVITY_TIMEOUT";; esac

_progress_log() { # progress marker body path
    local f="$1" state pci pct cur curtot done total vt fn overall pp
    state="$(marker_field state "$f")"; pci="$(marker_field chunk_index "$f")"; pct="$(marker_field chunks_total "$f")"
    cur="$(marker_field bytes_current "$f")"; curtot="$(marker_field bytes_current_total "$f")"
    done="$(marker_field bytes_done "$f")"; total="$(marker_field bytes_total "$f")"
    vt="$(marker_field volumetag "$f")"; fn="$(marker_field file "$f")"
    case "$cur" in ''|*[!0-9]*) cur=0;; esac; case "$done" in ''|*[!0-9]*) done=0;; esac
    case "$total" in ''|*[!0-9]*) total=0;; esac; case "$curtot" in ''|*[!0-9]*) curtot=0;; esac
    overall=$((done+cur))
    pp="$(awk -v n="$overall" -v d="$total" 'BEGIN{if(d>0)printf "%.1f",100*n/d;else printf "0.0"}')"
    log "restore progress: state=${state:-unknown} chunk=${pci:-0}/${pct:-?} current=$(awk -v b="$cur" 'BEGIN{printf "%.2f",b/1000000000}')/$(awk -v b="$curtot" 'BEGIN{printf "%.2f",b/1000000000}') GB overall=$(awk -v b="$overall" 'BEGIN{printf "%.2f",b/1000000000}')/$(awk -v b="$total" 'BEGIN{printf "%.2f",b/1000000000}') GB (${pp}%)${vt:+ tape=$vt}${fn:+#$fn}"
}

# Wait for one chunk receipt. A signed request.PROGRESS update resets the inactivity timer. Before the
# first progress marker appears we use the longer queue timeout, avoiding the 31E7 false-failure mode.
wait_restore_chunk() { # CB INDEX TOTAL
    local cb="$1" idx="$2" total_chunks="$3" start now last_activity token="" ntok active=0 limit body pe last_progress_epoch=0
    start="$(date +%s)"; last_activity="$start"
    while :; do
        if marker_exists "$RDIR" "staged_$cb.READY"; then
            marker_verify "$RDIR" "staged_$cb.READY" || die "staging receipt failed signature verification for $cb"
            return 0
        fi
        if marker_exists "$RDIR" "staged_$cb.ERROR"; then
            marker_verify "$RDIR" "staged_$cb.ERROR" || die "staging error marker failed signature verification for $cb"
            body="$(marker_read "$RDIR" "staged_$cb.ERROR" 2>/dev/null || true)"
            die "tape server could not stage $cb: ${body:-unknown error}"
        fi
        if marker_exists "$RDIR" request.STAGED; then
            marker_verify "$RDIR" request.STAGED || die "staging response failed signature verification (forged?)"
            body="$(marker_read "$RDIR" request.STAGED 2>/dev/null || true)"
            case "$body" in
                refused:*) die "tape server refused the restore — ${body#refused: }";;
                cancelled*) die "tape server cancelled staging — $body";;
                failed:*) die "tape server failed staging — ${body#failed: }";;
                *) die "tape server ended request before $cb became READY: ${body:-empty response}";;
            esac
        fi
        if marker_exists "$RDIR" request.PROGRESS; then
            ntok="$(stat -c '%Y:%s' "$RDIR/request.PROGRESS" 2>/dev/null || true)"
            if [ -n "$ntok" ] && [ "$ntok" != "$token" ]; then
                # request.PROGRESS is intentionally mutable. Its detached signature and body are two
                # atomic renames, not one atomic pair, so a reader can briefly observe a new body/old
                # signature during refresh. Invalid/torn progress is therefore ignored and retried;
                # it never extends the timeout. `updated_epoch` must also increase, preventing replay
                # of an older valid progress body within the same signed marker location.
                if marker_verify "$RDIR" request.PROGRESS; then
                    pe="$(marker_field updated_epoch "$RDIR/request.PROGRESS")"
                    case "$pe" in ''|*[!0-9]*) pe=0;; esac
                    if [ "$pe" -gt "$last_progress_epoch" ]; then
                        last_progress_epoch="$pe"; token="$ntok"; active=1; last_activity="$(date +%s)"; _progress_log "$RDIR/request.PROGRESS"
                    fi
                fi
            fi
        fi
        now="$(date +%s)"
        if [ "$active" -eq 1 ]; then limit="$RESTORE_INACTIVITY_TIMEOUT"; else limit="$RESTORE_QUEUE_TIMEOUT"; fi
        [ $((now-last_activity)) -lt "$limit" ] || die "restore stalled waiting for chunk $idx/$total_chunks ($cb): no signed progress for ${limit}s"
        sleep "${BRIC_POLL:-2}"
    done
}

wait_restore_terminal() {
    local last_activity now token="" ntok body pe last_progress_epoch=0
    last_activity="$(date +%s)"
    while :; do
        if marker_exists "$RDIR" request.STAGED; then
            marker_verify "$RDIR" request.STAGED || die "staging response failed signature verification (forged?)"
            body="$(marker_read "$RDIR" request.STAGED 2>/dev/null || true)"
            case "$body" in refused:*) die "tape server refused the restore — ${body#refused: }";; cancelled*) die "tape server cancelled staging — $body";; failed:*) die "tape server failed staging — ${body#failed: }";; esac
            return 0
        fi
        if marker_exists "$RDIR" request.PROGRESS; then
            ntok="$(stat -c '%Y:%s' "$RDIR/request.PROGRESS" 2>/dev/null || true)"
            if [ -n "$ntok" ] && [ "$ntok" != "$token" ]; then
                if marker_verify "$RDIR" request.PROGRESS; then
                    pe="$(marker_field updated_epoch "$RDIR/request.PROGRESS")"
                    case "$pe" in ''|*[!0-9]*) pe=0;; esac
                    if [ "$pe" -gt "$last_progress_epoch" ]; then
                        last_progress_epoch="$pe"; token="$ntok"; last_activity="$(date +%s)"; _progress_log "$RDIR/request.PROGRESS"
                    fi
                fi
            fi
        fi
        now="$(date +%s)"
        [ $((now-last_activity)) -lt "$RESTORE_INACTIVITY_TIMEOUT" ] || die "restore stalled during final media release: no signed progress for ${RESTORE_INACTIVITY_TIMEOUT}s"
        sleep "${BRIC_POLL:-2}"
    done
}

verify_blob_hmac() {
    local blob="$1" want="$2" got
    [ -n "$want" ] || die "no payload_hmac in catalog for $(basename "$blob") — refusing blind decrypt"
    [ -f "$blob" ] || die "staged blob missing after signed READY receipt: $blob"
    got="$(openssl dgst -sha256 -hmac "$HMAC_KEY" "$blob" | awk '{print $NF}')"
    [ "$got" = "$want" ] || die "HMAC mismatch on $(basename "$blob") — integrity/authenticity check FAILED"
}

# Review 33: directory metadata is transactional. Before each payload write, existing ancestors are
# snapshotted and temporarily made traversable. Directory entries that tar may modify are marked
# APPLYING before extraction; after a successful tar they are snapshotted again (now representing
# archive-final metadata), relaxed for subsequent chunks, and only finalized after sync+verification.
prepare_full_chunk_paths() { # chunk_no
    local c="$1" rel et
    while IFS=$'\x1f' read -r -d $'\x1e' rel et; do
        [ -n "$rel" ] || continue
        rtxn_prepare_ancestors "$rel" || die "cannot prepare restore ancestors for $rel"
        if [ "$et" = D ]; then rtxn_mark_applying "$DEST/$rel" || die "cannot journal directory before extraction: $rel"; fi
    done < <(sqla "SELECT rel_path,entry_type FROM files WHERE run_id='$(sql_quote "$RUN_ID")' AND chunk_no=$c ORDER BY (length(rel_path)-length(replace(rel_path,'/',''))) ASC,length(rel_path) ASC;")
}
refresh_full_chunk_dirs() { # chunk_no
    local c="$1" rel
    while IFS= read -r -d $'\x1e' rel; do
        [ -n "$rel" ] || continue
        rtxn_refresh_relax "$DEST/$rel" || die "cannot capture/relax restored directory metadata: $rel"
    done < <(sqla "SELECT rel_path FROM files WHERE run_id='$(sql_quote "$RUN_ID")' AND chunk_no=$c AND entry_type='D' ORDER BY (length(rel_path)-length(replace(rel_path,'/',''))) ASC,length(rel_path) ASC;")
}

# Large-file single restore appends pieces in chunk_index order; initialize once before consuming.
if [ -n "$FILE" ] && [ "${BIGPARTS:-0}" -gt 0 ]; then
    rtxn_prepare_ancestors "$RESTORE_REL" || die "cannot prepare restore ancestors for $RESTORE_REL"
    mkdir -p "$DEST/$(dirname "$RESTORE_REL")"; : > "$DEST/$RESTORE_REL"
fi

tar_restore_payload() { # destination-dir [member]
    local out="$1" member="${2:-}"
    local -a args=(-C "$out" -xp --no-same-owner --delay-directory-restore)
    if [ "$ALLOW_METADATA_DEGRADATION" -eq 1 ]; then
        args+=(--no-xattrs --no-acls)
    else
        args+=(--acls --xattrs --xattrs-include=user.* --xattrs-include=system.nfs4_acl)
    fi
    args+=(-f -)
    [ -z "$member" ] || args+=(-- "$member")
    tar "${args[@]}"
}

idx=0
for c in "${NEED_CHUNKS[@]}"; do
    idx=$((idx+1))
    cb="${RUN_ID}__c$(printf '%04d' "$c")"
    log "restore: waiting for chunk $idx/${#NEED_CHUNKS[@]} ($cb)"
    wait_restore_chunk "$cb" "$idx" "${#NEED_CHUNKS[@]}"
    BLOB="$RDIR/staged_$cb.enc"
    ph="$(sql "SELECT payload_hmac FROM chunks WHERE run_id='$(sql_quote "$RUN_ID")' AND chunk_no=$c;")"
    verify_blob_hmac "$BLOB" "$ph"

    TYPE="$(sql "SELECT type FROM chunks WHERE run_id='$(sql_quote "$RUN_ID")' AND chunk_no=$c;")"
    if [ -n "$FILE" ] && [ "${BIGPARTS:-0}" -gt 0 ]; then
        rtxn_prepare_ancestors "$RESTORE_REL" || die "cannot prepare restore ancestors for $RESTORE_REL"
        openssl enc -d -aes-256-cbc -pbkdf2 -iter 10000 -pass file:"$PASS" -in "$BLOB" >> "$DEST/$RESTORE_REL"
    elif [ "$TYPE" = TAR_PART ]; then
        if [ -n "$FILE" ]; then
            rtxn_prepare_ancestors "$RESTORE_REL" || die "cannot prepare restore ancestors for $RESTORE_REL"
            file_et="$(sql "SELECT entry_type FROM files WHERE run_id='$(sql_quote "$RUN_ID")' AND rel_path='$(sql_quote "$FILE")';")"
            if [ "$file_et" = D ]; then rtxn_mark_applying "$DEST/$RESTORE_REL" || die "cannot journal selected directory: $RESTORE_REL"; fi
            if [ -n "$RESTORE_PREFIX" ]; then
                mkdir -p "$DEST/$RESTORE_PREFIX"
                openssl enc -d -aes-256-cbc -pbkdf2 -iter 10000 -pass file:"$PASS" -in "$BLOB" | tar_restore_payload "$DEST/$RESTORE_PREFIX" "$FILE"
            else
                openssl enc -d -aes-256-cbc -pbkdf2 -iter 10000 -pass file:"$PASS" -in "$BLOB" | tar_restore_payload "$DEST" "$FILE"
            fi
            if [ "$file_et" = D ]; then rtxn_refresh_relax "$DEST/$RESTORE_REL" || die "cannot capture selected directory metadata: $RESTORE_REL"; fi
        else
            prepare_full_chunk_paths "$c"
            openssl enc -d -aes-256-cbc -pbkdf2 -iter 10000 -pass file:"$PASS" -in "$BLOB" | tar_restore_payload "$DEST"
            refresh_full_chunk_dirs "$c"
        fi
    else
        BR="$(sql "SELECT big_rel_path FROM chunks WHERE run_id='$(sql_quote "$RUN_ID")' AND chunk_no=$c;")"
        rtxn_prepare_ancestors "$BR" || die "cannot prepare restore ancestors for $BR"
        mkdir -p "$DEST/$(dirname "$BR")"
        [ "$(sql "SELECT chunk_index FROM chunks WHERE run_id='$(sql_quote "$RUN_ID")' AND chunk_no=$c;")" = "1" ] && : > "$DEST/$BR"
        openssl enc -d -aes-256-cbc -pbkdf2 -iter 10000 -pass file:"$PASS" -in "$BLOB" >> "$DEST/$BR"
    fi

    # Publish the authenticated consumer acknowledgement before removing the ciphertext. New tape
    # daemons use it as backpressure; old daemons simply ignore it. Either way the reverse bus no
    # longer accumulates all requested chunks.
    marker_set_signed "$RDIR" "staged_$cb.CONSUMED" "run=$RUN_ID
chunk=$c
chunk_index=$idx
consumed_epoch=$(date +%s)"
    rm -f "$BLOB"
    log "restore: consumed and released chunk $idx/${#NEED_CHUNKS[@]} ($cb)"
done

# All data is already restored at this point. Wait only for the tape daemon's final robotics barrier.
wait_restore_terminal
rm -f "$PASS"

# Force payload writeback while restrictive directories are still temporarily traversable.
# This does not claim hardware persistence beyond the filesystem's sync semantics; it closes the
# ordinary writeback window before destination verification and metadata finalization.
rtxn_sync_destination "$DEST" || die "sync failed for restore destination: $DEST"

# Verify destination objects. A successful authenticated/decrypted extraction establishes the
# stream guarantee. Failure to re-open a mode-000 destination is therefore VERIFIED-STREAM, not a
# checksum mismatch; only a successfully calculated unequal digest is CHECKSUM-MISMATCH.
VERIFY_DEST=0; VERIFY_STREAM=0; VERIFY_NODIGEST=0; VERIFY_TYPE=0; VERIFY_MISMATCH=0; VERIFY_MISSING=0
verify_one() { # physical catalog rel, destination rel
    local rel="$1" target="$2" want got etype
    etype="$(sql "SELECT entry_type FROM files WHERE run_id='$(sql_quote "$RUN_ID")' AND rel_path='$(sql_quote "$rel")';")"
    case "$etype" in
        D)
            if [ -d "$DEST/$target" ]; then VERIFY_TYPE=$((VERIFY_TYPE+1)); log "TYPE-VERIFIED directory: $target"; return 0; fi
            VERIFY_MISSING=$((VERIFY_MISSING+1)); log "MISSING directory after restore: $target"; return 1;;
        L)
            if [ -L "$DEST/$target" ]; then VERIFY_TYPE=$((VERIFY_TYPE+1)); log "TYPE-VERIFIED symlink: $target"; return 0; fi
            VERIFY_MISSING=$((VERIFY_MISSING+1)); log "MISSING/WRONG-TYPE symlink after restore: $target"; return 1;;
    esac
    if [ ! -f "$DEST/$target" ]; then
        VERIFY_MISSING=$((VERIFY_MISSING+1)); log "MISSING/WRONG-TYPE regular file after restore: $target"; return 1
    fi
    want="$(sql "SELECT sha256_plain FROM files WHERE run_id='$(sql_quote "$RUN_ID")' AND rel_path='$(sql_quote "$rel")';")"
    if [ -z "$want" ]; then
        if got="$(sha256_file "$DEST/$target" 2>/dev/null)"; then
            VERIFY_NODIGEST=$((VERIFY_NODIGEST+1)); log "NO-DIGEST: $target (destination re-read succeeded; catalog has no plaintext digest)"; return 0
        fi
        VERIFY_STREAM=$((VERIFY_STREAM+1)); log "VERIFIED-STREAM: $target (destination could not be re-read; catalog has no plaintext digest)"; return 0
    fi
    if got="$(sha256_file "$DEST/$target" 2>/dev/null)"; then
        if [ "$got" = "$want" ]; then
            VERIFY_DEST=$((VERIFY_DEST+1)); log "VERIFIED-DESTINATION: $target"; return 0
        fi
        VERIFY_MISMATCH=$((VERIFY_MISMATCH+1)); log "CHECKSUM-MISMATCH: $target"; return 1
    fi
    VERIFY_STREAM=$((VERIFY_STREAM+1))
    log "VERIFIED-STREAM: $target (destination could not be re-read; authenticated/decrypted extraction completed successfully)"
    return 0
}
rc=0
if [ -n "$FILE" ]; then
    verify_one "$FILE" "$RESTORE_REL" || rc=1
else
    while IFS= read -r -d $'\x1e' rel; do [ -n "$rel" ] && { verify_one "$rel" "$rel" || rc=1; }; done < <(sqla "SELECT rel_path FROM files WHERE run_id='$(sql_quote "$RUN_ID")';")
fi
log "restore verification summary: VERIFIED-DESTINATION=$VERIFY_DEST VERIFIED-STREAM=$VERIFY_STREAM NO-DIGEST=$VERIFY_NODIGEST TYPE-VERIFIED=$VERIFY_TYPE CHECKSUM-MISMATCH=$VERIFY_MISMATCH MISSING=$VERIFY_MISSING"
if [ "$REQUIRE_DEST_VERIFY" -eq 1 ] && [ "$VERIFY_STREAM" -gt 0 ]; then
    log "destination verification required but $VERIFY_STREAM object(s) are VERIFIED-STREAM only"
    rc=1
fi

apply_large_metadata() { # catalog rel, destination rel
    local rel="$1" target="$2" row mode_dec mt meta mode_oct
    [ "$(sql "SELECT COUNT(*) FROM chunks WHERE run_id='$(sql_quote "$RUN_ID")' AND type='LARGE_FILE_CHUNK' AND big_rel_path='$(sql_quote "$rel")';")" -gt 0 ] || return 0
    row="$(sqlc "SELECT COALESCE(mode,''),COALESCE(mtime,''),COALESCE(metadata_b64,'') FROM files WHERE run_id='$(sql_quote "$RUN_ID")' AND rel_path='$(sql_quote "$rel")';")"
    IFS='|' read -r mode_dec mt meta <<< "$row"
    mode_oct=""; [ -z "$mode_dec" ] || printf -v mode_oct '%04o' "$mode_dec"
    local mrc=0
    if [ "$ALLOW_METADATA_DEGRADATION" -eq 1 ]; then
        "$META_HELPER" apply "$DEST/$target" "$mode_oct" "$mt" "$meta" --allow-degradation || mrc=$?
        case "$mrc" in
            0) :;;
            4) METADATA_DEGRADED=1; warn_log "METADATA-DEGRADED large file: $target (one or more unsupported ACL/xattr operations skipped)";;
            *) return "$mrc";;
        esac
    else
        "$META_HELPER" apply "$DEST/$target" "$mode_oct" "$mt" "$meta" || return 1
    fi
    log "METADATA-RESTORED large file: $target${mode_dec:+ mode=$mode_oct}${mt:+ mtime=$mt}"
}

# Review 34: LARGE_FILE_CHUNK bypasses TAR headers. Apply catalogued file metadata only AFTER
# payload verification, while directory ancestors are still temporarily traversable. Legacy rows
# have mode=NULL/metadata_b64='' and therefore recover only the already-catalogued mtime.
if [ "$rc" -eq 0 ]; then
    if [ -n "$FILE" ]; then
        if [ "${BIGPARTS:-0}" -gt 0 ]; then apply_large_metadata "$FILE" "$RESTORE_REL" || rc=1; fi
    else
        while IFS= read -r -d $'\x1e' _br; do [ -n "$_br" ] && { apply_large_metadata "$_br" "$_br" || rc=1; }; done < <(sqla "SELECT DISTINCT big_rel_path FROM chunks WHERE run_id='$(sql_quote "$RUN_ID")' AND type='LARGE_FILE_CHUNK' AND big_rel_path IS NOT NULL AND big_rel_path<>'';")
    fi
    [ "$rc" -ne 0 ] || rtxn_sync_destination "$DEST" || rc=1
fi
if ! rtxn_finalize; then
    RTXN_PRESERVE=1
    log "restore metadata finalization FAILED; journal preserved at ${RTXN_DB:-unknown}"
    rc=1
fi

# Free the staged blobs and prune the empty project directory (QNAP is a transient bus).
bus_cleanup_restore_dir "$RDIR" || warn_log "restore succeeded but QNAP reverse-bus cleanup was deferred: $RDIR"
RESTORE_RESULT=FAIL
if [ "$rc" -eq 0 ]; then [ "$METADATA_DEGRADED" -eq 1 ] && RESTORE_RESULT=DEGRADED || RESTORE_RESULT=OK; fi
audit RESTORE_DONE "$RUN_ID" "$RESTORE_RESULT" "dest=$DEST${REQUESTED_FILE:+ file=$REQUESTED_FILE} verified_destination=$VERIFY_DEST verified_stream=$VERIFY_STREAM no_digest=$VERIFY_NODIGEST type_verified=$VERIFY_TYPE checksum_mismatch=$VERIFY_MISMATCH missing=$VERIFY_MISSING metadata_fidelity=$([ "$METADATA_DEGRADED" -eq 1 ] && echo DEGRADED || echo EXACT_OR_UNCHANGED)"
if [ "$rc" -eq 0 ]; then
    rm -rf "$LOCAL_TMP"
    bric_notify RESTORE_DONE "$OWNER" "$RUN_ID" "project=$PROJECT dest=$DEST${REQUESTED_FILE:+ file=$REQUESTED_FILE}: complete; result=$RESTORE_RESULT metadata_fidelity=$([ "$METADATA_DEGRADED" -eq 1 ] && echo DEGRADED || echo EXACT_OR_UNCHANGED); destination_sha256=$VERIFY_DEST stream_only=$VERIFY_STREAM no_digest=$VERIFY_NODIGEST type_verified=$VERIFY_TYPE"
    if [ "$VERIFY_STREAM" -gt 0 ]; then
        log "restore complete -> $DEST; $VERIFY_STREAM object(s) VERIFIED-STREAM only (destination not independently re-read; tar/decrypt success is not proof of physical persistence)"
    else
        if [ "$METADATA_DEGRADED" -eq 1 ]; then log "restore payload complete and destination-verified -> $DEST; METADATA FIDELITY DEGRADED by explicit operator request"; else log "restore complete and destination-verified -> $DEST"; fi
    fi
    bric_log_process_end 0
    trap - EXIT
else
    rm -rf "$LOCAL_TMP"
    bric_notify RESTORE_FAILED "$OWNER" "$RUN_ID" "restore completed WITH verification errors; dest=$DEST${REQUESTED_FILE:+ file=$REQUESTED_FILE}"
    die "restore completed WITH verification errors -> $DEST"
fi
