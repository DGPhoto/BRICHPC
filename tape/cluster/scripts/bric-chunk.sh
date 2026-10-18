#!/bin/bash
# bric-chunk: produce ONE chunk (one SLURM array task). Streams tar|openssl straight to the QNAP
# (no plaintext intermediate) and publishes a READY marker for the tape server to drain.
set -euo pipefail
IFS=$'\n\t'
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
. "$HERE/lib_common.sh"
META_HELPER="$HERE/../libexec/bric-file-metadata"; [ -x "$META_HELPER" ] || die "file-metadata helper missing/not executable: $META_HELPER"
bric_log_process_start "bric-chunk" "$@"
require_cmds sqlite3 tar openssl sha256sum awk dd stat mktemp
enforce_bus_signing   # refuse to run unsigned when config require_bus_signing=1

RUN_ID=""; CHUNK_NO=""
while [ "$#" -gt 0 ]; do case "$1" in
    --run) RUN_ID="${2:-}"; shift 2;;
    --chunk) CHUNK_NO="${2:-}"; shift 2;;
    *) die "unknown option: $1";; esac; done
[ -n "$RUN_ID" ] && [ -n "$CHUNK_NO" ] || die "usage: bric-chunk --run RUN_ID --chunk N"

IFS='|' read -r PROJECT OWNER SOURCE <<EOF
$(sqlc "SELECT project_name,owner,source_path FROM runs WHERE run_id='$(sql_quote "$RUN_ID")';")
EOF
[ -n "$PROJECT" ] || die "run not found: $RUN_ID"
# NUL/newline-safe: big_rel_path may contain newlines or pipes, so read the row in ascii mode
# (fields 0x1f, record 0x1e) instead of a pipe-split single line that would truncate the path.
IFS=$'\x1f' read -r -d $'\x1e' TYPE SIZE BIGREL CIDX TOT OFFSET < <(sqla "SELECT type,size_bytes,COALESCE(big_rel_path,''),COALESCE(chunk_index,''),COALESCE(total_chunks,''),COALESCE(offset_bytes,'') FROM chunks WHERE run_id='$(sql_quote "$RUN_ID")' AND chunk_no=$CHUNK_NO;") || true
[ -n "$TYPE" ] || die "chunk not found: $RUN_ID/$CHUNK_NO"

# Derive the owner's keys (key lives in the owner's home on the cluster; never leaves it).
UKF="$(user_key_file "$OWNER")"; [ -f "$UKF" ] || die "user key not found for $OWNER: $UKF"
derive_keys "$(cat "$UKF")"
TMP="$(mktemp -d)"
_chunk_exit(){ local rc=$?; trap - EXIT; rm -rf "$TMP"; bric_log_process_end "$rc"; exit "$rc"; }
trap _chunk_exit EXIT
ENCPASS="$TMP/enc"; printf '%s' "$ENC_KEY" > "$ENCPASS"; chmod 600 "$ENCPASS"

RUN_DIR="$(qnap_run_dir "$PROJECT" "$RUN_ID")"; mkdir -p "$RUN_DIR"
BASE="$RUN_DIR/$(printf 'chunk_%04d' "$CHUNK_NO")"
BLOB="$BASE.enc"

READYF="$RUN_DIR/$(printf 'chunk_%04d.READY' "$CHUNK_NO")"
# Idempotency for SLURM requeue (node failure / preemption re-runs the same array task). If this chunk
# already completed, or is already staged on the QNAP, do nothing — never re-stage/re-emit a READY that
# would make the tape server write a duplicate segment to the append-only tape.
CUR="$(sql "SELECT state FROM chunks WHERE run_id='$(sql_quote "$RUN_ID")' AND chunk_no=$CHUNK_NO;")"
case "$CUR" in
    DONE) log "chunk $CHUNK_NO already DONE — nothing to do (requeue-safe)"; exit 0;;
    READY|PRODUCED) [ -f "$BLOB" ] && [ -f "$READYF" ] && { log "chunk $CHUNK_NO already staged — nothing to do"; exit 0; };;
esac

sql "UPDATE chunks SET state='PRODUCING', updated_at=datetime('now') WHERE run_id='$(sql_quote "$RUN_ID")' AND chunk_no=$CHUNK_NO;"
chunk_status_event "$RUN_ID" "$PROJECT" "$CHUNK_NO" PRODUCING "type=$TYPE"

# Real sliding window, measured against blobs ACTUALLY on the QNAP. SLURM's `--array=...%N` only
# throttles how many tasks RUN at once; a task can finish (publish READY) and let SLURM start the next
# while the tape server is still draining, so by itself it does NOT bound how many blobs sit on the
# bus. The tape daemon removes each chunk_*.enc the instant both tape copies are VERIFIED, so the live
# bus usage is exactly the chunk_*.enc files present (the cluster catalog's chunks.state only reaches
# DONE later, in bric-finalize, so it is NOT a valid in-flight signal during production). Block before
# writing this chunk's blob until this run has < max_inflight_chunks blobs staged AND total bytes on
# the bus are under qnap_budget_bytes. A permanently stuck tape correctly stalls production instead of
# overflowing the QNAP. (This chunk's .enc does not exist yet, so it is not self-counted.)
MAXINFLIGHT="$(cfg max_inflight_chunks)"; case "$MAXINFLIGHT" in ''|*[!0-9]*) MAXINFLIGHT=8;; esac; [ "$MAXINFLIGHT" -lt 1 ] && MAXINFLIGHT=1
QBUDGET="$(cfg qnap_budget_bytes)"; case "$QBUDGET" in ''|*[!0-9]*) QBUDGET=0;; esac
WPOLL="${BRIC_POLL:-5}"; case "$WPOLL" in ''|*[!0-9]*) WPOLL=5;; esac; [ "$WPOLL" -lt 1 ] && WPOLL=1
PROBE_MAX="$(qnap_probe_failure_limit)"
probe_failures=0
# Count this run's staged blobs with a Bash glob rather than find(1). The tape daemon can remove
# a blob concurrently after verification; a disappearing directory entry must not turn a healthy
# producer into a pipefail/SIGPIPE abort.
shopt -s nullglob
while :; do
    _staged_files=("$RUN_DIR"/chunk_*.enc)
    staged="${#_staged_files[@]}"
    unset _staged_files
    reason=""
    [ "$staged" -ge "$MAXINFLIGHT" ] && reason="window full ($staged/$MAXINFLIGHT staged)"
    if [ -z "$reason" ] && [ "$QBUDGET" -gt 0 ]; then
        if inflight="$(qnap_inflight_bytes)"; then
            probe_failures=0
            inflight="${inflight:-0}"
            [ "$inflight" -ge "$QBUDGET" ] && reason="QNAP at budget ($inflight/$QBUDGET bytes)"
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
    [ -z "$reason" ] && break
    log "sliding window: $reason — waiting for tape to drain before staging chunk $CHUNK_NO…"
    sleep "$WPOLL"
done

# --- Source quiescence guard -----------------------------------------------------------------
# LARGE offsets are FIXED at planning; plaintext shas are computed at production; different pieces
# of one large file can be produced by different array tasks at different times. A source mutating
# in between lands on tape as a silent MIX of versions, detected only at restore — possibly years
# later. So: re-stat every regular member against the size+mtime recorded by bric-plan, both BEFORE
# producing and again AFTER tar/dd (closing the remaining race to seconds), and ABORT on any drift.
quiescence_abort() {
    sql "UPDATE chunks SET state='ERROR', error='$(sql_quote "quiescence violation: $1")', updated_at=datetime('now') WHERE run_id='$(sql_quote "$RUN_ID")' AND chunk_no=$CHUNK_NO;"
    chunk_status_event "$RUN_ID" "$PROJECT" "$CHUNK_NO" ERROR "quiescence violation: $1"
    bric_notify CHUNK_ERROR "$OWNER" "$RUN_ID" "chunk $CHUNK_NO: quiescence violation: $1"
    die "quiescence violation on chunk $CHUNK_NO: $1 — the source MUST NOT change between bric-plan and the end of production (archive from a snapshot/frozen data)"
}
check_member_quiescent() {   # rel -> return 0 if unchanged vs plan; abort otherwise
    local rel="$1" row want_sz want_mt want_mode want_meta cur_sz cur_mt meta_line cur_mode cur_meta
    row="$(sqlc "SELECT size_bytes,COALESCE(mtime,''),COALESCE(mode,''),COALESCE(metadata_b64,'') FROM files WHERE run_id='$(sql_quote "$RUN_ID")' AND rel_path='$(sql_quote "$rel")' AND entry_type='F';")"
    [ -n "$row" ] || return 0                     # dir/symlink member (META chunk): no data to drift
    IFS='|' read -r want_sz want_mt want_mode want_meta <<< "$row"
    [ -f "$SOURCE/$rel" ] && [ ! -L "$SOURCE/$rel" ] || quiescence_abort "'$rel' vanished or was replaced by a non-regular file since planning"
    IFS='|' read -r cur_sz cur_mt <<<"$(stat -c'%s|%Y' "$SOURCE/$rel")"
    [ "$cur_sz" = "$want_sz" ] || quiescence_abort "'$rel' size changed since planning ($want_sz -> $cur_sz bytes)"
    [ -z "$want_mt" ] || [ "$cur_mt" = "$want_mt" ] || quiescence_abort "'$rel' mtime changed since planning ($want_mt -> $cur_mt)"
    if [ -n "$want_mode" ]; then
        meta_line="$("$META_HELPER" capture "$SOURCE/$rel")" || quiescence_abort "'$rel' metadata cannot be captured"
        IFS=$'\t' read -r cur_mode cur_mt cur_meta <<< "$meta_line"
        [ "$((8#$cur_mode))" = "$want_mode" ] || quiescence_abort "'$rel' mode changed since planning"
        [ "$cur_meta" = "$want_meta" ] || quiescence_abort "'$rel' ACL/xattr metadata changed since planning"
    fi
    return 0
}
check_chunk_quiescent() {    # verifies every regular member of THIS chunk against the plan
    if [ "$TYPE" = "TAR_PART" ]; then
        local rel
        while IFS= read -r -d '' rel; do
            [ -n "$rel" ] || continue
            check_member_quiescent "$rel"
        done < "$LIST"
    else
        check_member_quiescent "$BIGREL"
    fi
}

# Per-file/whole-file PLAINTEXT sha bookkeeping (done once, idempotent).
if [ "$TYPE" = "TAR_PART" ]; then
    LIST="$(chunk_member_list "$RUN_ID" "$CHUNK_NO")"
    [ -f "$LIST" ] || die "member list missing for $RUN_ID/$CHUNK_NO: $LIST (was the run planned by this version?)"
    check_chunk_quiescent
    while IFS= read -r -d '' rel; do
        [ -n "$rel" ] || continue
        if [ -f "$SOURCE/$rel" ] && [ ! -L "$SOURCE/$rel" ]; then
            h="$(sha256_file "$SOURCE/$rel")"
            sql "UPDATE files SET sha256_plain='$h' WHERE run_id='$(sql_quote "$RUN_ID")' AND rel_path='$(sql_quote "$rel")';"
        fi
    done < "$LIST"
elif [ "$CIDX" = "1" ]; then
    check_chunk_quiescent
    h="$(sha256_file "$SOURCE/$BIGREL")"
    sql "UPDATE files SET sha256_plain='$h' WHERE run_id='$(sql_quote "$RUN_ID")' AND rel_path='$(sql_quote "$BIGREL")';"
else
    check_chunk_quiescent   # every LARGE piece re-stats the whole file (cheap; pieces run at different times)
fi

# Stream tar|openssl (or dd|openssl) straight to the QNAP, with bounded retries for TRANSIENT I/O
# failures (NFS/Isilon hiccups). --no-recursion + --null keep hostile file names safe.
produce_once() {
    : > "$TMP/err"; rm -f "$BLOB.part"
    if [ "$TYPE" = "TAR_PART" ]; then
        local -a tar_args=(-c --format=pax --acls --xattrs --xattrs-include=user.* --xattrs-include=system.nfs4_acl --no-recursion --null -T "$LIST")
        # Planner emits ordinary files and directory/link metadata in separate TAR_PART chunks.
        # Strip setuid/setgid/sticky only from regular-file chunks; preserve directory sticky bits.
        local nonfiles files_in_chunk
        nonfiles="$(sql "SELECT count(*) FROM files WHERE run_id='$(sql_quote "$RUN_ID")' AND chunk_no=$CHUNK_NO AND entry_type!='F';")"
        files_in_chunk="$(sql "SELECT count(*) FROM files WHERE run_id='$(sql_quote "$RUN_ID")' AND chunk_no=$CHUNK_NO AND entry_type='F';")"
        if [ "${files_in_chunk:-0}" -gt 0 ] && [ "${nonfiles:-0}" -eq 0 ]; then
            tar_args+=(--mode=u-s,g-s,o-t)
        fi
        ( cd "$SOURCE" && tar "${tar_args[@]}" 2>>"$TMP/err" \
            | openssl enc -aes-256-cbc -pbkdf2 -iter 10000 -salt -pass file:"$ENCPASS" > "$BLOB.part" 2>>"$TMP/err" )
    else
        dd if="$SOURCE/$BIGREL" bs=1048576 iflag=skip_bytes,count_bytes skip="$OFFSET" count="$SIZE" status=none 2>>"$TMP/err" \
            | openssl enc -aes-256-cbc -pbkdf2 -iter 10000 -salt -pass file:"$ENCPASS" > "$BLOB.part" 2>>"$TMP/err"
    fi
}
RETRIES="${BRIC_CHUNK_RETRIES:-3}"; case "$RETRIES" in ''|*[!0-9]*) RETRIES=3;; esac; [ "$RETRIES" -lt 1 ] && RETRIES=1
attempt=1
while :; do
    if produce_once && [ -s "$BLOB.part" ]; then break; fi
    if [ "$attempt" -ge "$RETRIES" ]; then
        sql "UPDATE chunks SET state='ERROR',error='$(sql_quote "produce failed after $attempt attempt(s): $(cat "$TMP/err")")' WHERE run_id='$(sql_quote "$RUN_ID")' AND chunk_no=$CHUNK_NO;"
        BRIC_LOG_ATTEMPT="$attempt" chunk_status_event "$RUN_ID" "$PROJECT" "$CHUNK_NO" ERROR "produce failed: $(cat "$TMP/err")"
        bric_notify CHUNK_ERROR "$OWNER" "$RUN_ID" "chunk $CHUNK_NO: produce failed after $attempt attempt(s): $(cat "$TMP/err" | head -c 200)"
        die "produce failed for chunk $CHUNK_NO after $attempt attempt(s): $(cat "$TMP/err")"
    fi
    log "chunk $CHUNK_NO produce attempt $attempt failed (transient?), retrying: $(cat "$TMP/err")"
    attempt=$((attempt+1)); sleep "$((attempt*2))"
done
mv -f "$BLOB.part" "$BLOB"
# Post-production quiescence re-check: the blob is staged but NOT yet published. If the source
# drifted DURING tar/dd, refuse to publish a READY for a mixed-version blob.
check_chunk_quiescent
PSHA="$(sha256sum "$BLOB" | awk '{print $1}')"
PHMAC="$(openssl dgst -sha256 -hmac "$HMAC_KEY" "$BLOB" | awk '{print $NF}')"
PSIZE="$(stat -c%s "$BLOB")"
printf '%s  %s\n' "$PSHA" "$(basename "$BLOB")" > "$BASE.enc.sha256"
printf '%s\n' "$PHMAC" > "$BASE.enc.hmac"
# Minimal meta for the tape server (NO per-file names/checksums leak to the world-readable QNAP).
marker_set_signed "$RUN_DIR" "$(printf 'chunk_%04d.meta' "$CHUNK_NO")" "run_id=$RUN_ID
project=$PROJECT
owner=$OWNER
chunk_no=$CHUNK_NO
type=$TYPE
size_bytes=$PSIZE
payload_sha256=$PSHA"

sql "UPDATE chunks SET state='PRODUCED', size_bytes=$PSIZE, payload_sha256='$PSHA', payload_hmac='$PHMAC', qnap_path='$(sql_quote "$BLOB")', updated_at=datetime('now')
     WHERE run_id='$(sql_quote "$RUN_ID")' AND chunk_no=$CHUNK_NO;"
# Publish READY (atomic, signed). The tape server verifies the signature, then claims it by renaming.
marker_set_signed "$RUN_DIR" "$(printf 'chunk_%04d.READY' "$CHUNK_NO")" "sha256=$PSHA
size_bytes=$PSIZE"
sql "UPDATE chunks SET state='READY' WHERE run_id='$(sql_quote "$RUN_ID")' AND chunk_no=$CHUNK_NO;"
BRIC_LOG_BYTES="$PSIZE" chunk_status_event "$RUN_ID" "$PROJECT" "$CHUNK_NO" READY "payload_sha256=$PSHA"
log "chunk $CHUNK_NO READY ($PSIZE bytes, sha ${PSHA:0:12}…)"
