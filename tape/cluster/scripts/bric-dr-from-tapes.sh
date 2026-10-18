#!/bin/bash
# bric-dr-from-tapes: reconstruct a project using ONLY the tapes and the user key.
# No cluster, no tape_catalog.db, no QNAP, no central DB of any kind. This is the test that
# separates an archive from a backup.
#
# Each tape ends with a plaintext TOC (the last file written at close) mapping every file number to
# what it holds. From the TOCs we learn chunk -> (tape, file). One of the files is catalog_project.enc,
# encrypted with the USER key; decrypting it gives the file -> chunk map and the plaintext checksums.
# Then every file is read straight off tape, decrypted, reassembled and verified.
#
# Tape access goes through the same lib_tape_io abstraction the daemon uses, so DR runs against the
# SIM backend (a directory of tapes) or REAL LTO hardware (mtx/mt/dd) with no code change:
#   SIM : --tapelib DIR            (default; BRIC_TAPE_BACKEND=sim)
#   REAL: BRIC_TAPE_BACKEND=real BRIC_CHANGER=/dev/sch0 ... (no --tapelib)
set -euo pipefail
IFS=$'\n\t'
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
log() { printf '[DR] %s\n' "$*" >&2; }
die() { echo "[DR] ERROR: $*" >&2; exit 1; }

TAPELIB=""; PROJECT=""; UKF=""; MKF=""; DEST=""; FILE=""; REQUIRE_DEST_VERIFY=0; ALLOW_METADATA_DEGRADATION=0; METADATA_DEGRADED=0
while [ "$#" -gt 0 ]; do case "$1" in
    --tapelib) TAPELIB="${2:-}"; shift 2;; --project) PROJECT="${2:-}"; shift 2;;
    --user-key-file) UKF="${2:-}"; shift 2;;
    --master-key-file) MKF="${2:-}"; shift 2;;   # ADMIN break-glass: recover the owner key from escrow
    --dest) DEST="${2:-}"; shift 2;;
    --file) FILE="${2:-}"; shift 2;;             # recover only this relative path (default: whole project)
    --require-destination-verify) REQUIRE_DEST_VERIFY=1; shift;;
    --allow-metadata-degradation) ALLOW_METADATA_DEGRADATION=1; shift;;
    *) die "unknown option: $1";; esac; done
[ -n "$PROJECT" ] && [ -n "$DEST" ] || \
    die "usage: bric-dr-from-tapes --project NAME --dest DIR (--user-key-file FILE | --master-key-file FILE) [--file REL] [--require-destination-verify] [--allow-metadata-degradation] [--tapelib DIR]"
{ [ -n "$UKF" ] || [ -n "$MKF" ]; } || die "provide --user-key-file (owner) or --master-key-file (admin break-glass)"
[ -n "$UKF" ] && [ -n "$MKF" ] && die "use either --user-key-file or --master-key-file, not both"
[ -n "$TAPELIB" ] && export BRIC_TAPELIB="$TAPELIB"
. "$HERE/../../tape/scripts/lib_tape_io.sh"
. "$HERE/lib_restore_txn.sh"
META_HELPER="$HERE/../libexec/bric-file-metadata"; [ -x "$META_HELPER" ] || die "file-metadata helper missing/not executable: $META_HELPER"
# DR must remain runnable from tapes + key + this script bundle, even in a bare recovery host.
# Load the standalone logger when shipped, but never make data recovery depend on observability.
: "${BRIC_REQUIRE_LOGGING:=0}"
if [ -r "$HERE/lib_logging.sh" ]; then
    . "$HERE/lib_logging.sh"
fi
declare -F bric_log_process_start >/dev/null 2>&1 || bric_log_process_start(){ :; }
declare -F bric_log_process_end   >/dev/null 2>&1 || bric_log_process_end(){ :; }
bric_log_process_start "bric-dr-from-tapes" "$@"
for c in openssl sha256sum tar awk sqlite3 sync; do command -v "$c" >/dev/null 2>&1 || die "need $c"; done
sha256_file() {
    local line hash
    line="$(sha256sum -- "$1")" || return 1
    hash="${line%% *}"
    hash="${hash#\\}"
    printf '%s' "$hash"
}

# Review 32B5R2: destination verification has three outcomes, matching normal restore. A digest
# mismatch is a data-integrity failure. Failure to re-read a successfully authenticated/decrypted
# destination is not evidence of different bytes; report VERIFIED-STREAM instead.
dr_verify_file() { # logical label, destination path, expected sha256
    local label="$1" path="$2" want="$3" got
    DR_VERIFY_DESTINATION="${DR_VERIFY_DESTINATION:-0}"
    DR_VERIFY_STREAM="${DR_VERIFY_STREAM:-0}"
    DR_VERIFY_NODIGEST="${DR_VERIFY_NODIGEST:-0}"
    DR_VERIFY_MISMATCH="${DR_VERIFY_MISMATCH:-0}"
    if [ -z "$want" ]; then
        if got="$(sha256_file "$path" 2>/dev/null)"; then
            DR_VERIFY_NODIGEST=$((DR_VERIFY_NODIGEST+1))
            log "NO-DIGEST: $label (destination re-read succeeded; catalog has no plaintext digest)"
            return 0
        fi
        DR_VERIFY_STREAM=$((DR_VERIFY_STREAM+1))
        log "VERIFIED-STREAM: $label (destination could not be re-read; catalog has no plaintext digest)"
        return 0
    fi
    if got="$(sha256_file "$path" 2>/dev/null)"; then
        if [ "$got" = "$want" ]; then
            DR_VERIFY_DESTINATION=$((DR_VERIFY_DESTINATION+1))
            log "VERIFIED-DESTINATION: $label"
            return 0
        fi
        DR_VERIFY_MISMATCH=$((DR_VERIFY_MISMATCH+1))
        log "CHECKSUM-MISMATCH: $label"
        return 1
    fi
    DR_VERIFY_STREAM=$((DR_VERIFY_STREAM+1))
    log "VERIFIED-STREAM: $label (destination could not be re-read; authenticated/decrypted recovery completed successfully)"
    return 0
}

dr_log_verify_summary() {
    DR_VERIFY_DESTINATION="${DR_VERIFY_DESTINATION:-0}"
    DR_VERIFY_STREAM="${DR_VERIFY_STREAM:-0}"
    DR_VERIFY_NODIGEST="${DR_VERIFY_NODIGEST:-0}"
    DR_VERIFY_MISMATCH="${DR_VERIFY_MISMATCH:-0}"
    log "DR verification summary: VERIFIED-DESTINATION=$DR_VERIFY_DESTINATION VERIFIED-STREAM=$DR_VERIFY_STREAM NO-DIGEST=$DR_VERIFY_NODIGEST CHECKSUM-MISMATCH=$DR_VERIFY_MISMATCH"
    if [ "$DR_VERIFY_STREAM" -gt 0 ]; then
        log "$DR_VERIFY_STREAM object(s) VERIFIED-STREAM only (destination not independently re-read; authenticated/decrypted recovery is not proof of physical persistence)"
    fi
}

TMP="$(mktemp -d)"
_dr_exit(){
    local rc=$?
    trap - EXIT
    if [ "$rc" -ne 0 ] && [ "${RTXN_ACTIVE:-0}" = 1 ] && [ "${RTXN_PRESERVE:-0}" = 0 ]; then
        rtxn_abort || log "WARN restore metadata rollback incomplete; journal preserved at ${RTXN_DB:-unknown}"
    fi
    rm -rf "$TMP"
    bric_log_process_end "$rc"
    exit "$rc"
}
trap _dr_exit EXIT
if [ "$ALLOW_METADATA_DEGRADATION" -eq 1 ]; then
    if [ -e "$DEST" ]; then
        [ -d "$DEST" ] && [ ! -L "$DEST" ] || die "--allow-metadata-degradation requires a directory destination: $DEST"
        [ -z "$(find "$DEST" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ] || die "--allow-metadata-degradation requires an empty destination: $DEST"
    else
        mkdir -p "$DEST" || die "cannot create degraded DR destination: $DEST"
    fi
    export BRIC_RESTORE_ALLOW_METADATA_DEGRADATION=1
    METADATA_DEGRADED=1
    log "WARNING metadata degradation explicitly allowed: TAR_PART ACL/xattr fidelity will not be guaranteed"
fi
mkdir -p "$DEST"
rtxn_begin "$DEST" "dr:$PROJECT" || die "cannot initialize restore metadata transaction for $DEST"

dr_tar_restore_payload() { # destination-dir [member]
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
dq() { printf "%s" "$1" | sed "s/'/''/g"; }
# ENC_KEY/HMAC_KEY/PASS are derived AFTER the TOC scan. In admin mode the owner key is recovered
# from project-bound user_key_escrow.v1; legacy catalog_system.enc tapes remain supported.

# The TOC is the last file on the tape; scan the last few files for the magic line.
toc_text_of_tape() {  # vt -> prints TOC text or returns 1
    # Scan BACKWARDS from EOD all the way to file 1: the latest TOC "wins", but it can sit an
    # arbitrary number of files back (a later run appends chunks to BOTH tapes of the pair before
    # its own close; if disaster strikes mid-run, dozens of chunk blobs may follow the last TOC).
    # A fixed small window here silently made whole tapes — and thus whole projects — invisible
    # to DR. DR is rare: a full backward scan trades time for the core promise (tapes+key suffice).
    # Each candidate is SNIFFED on its first block only (tape_sniff_first_block): a non-TOC
    # candidate is a 128 GB chunk blob, and reading it whole per probe would turn a real-hardware
    # DR into days. Only the file recognised as a TOC is then read in full (tr strips blob NULs).
    local vt="$1" last n tmp="$TMP/toc" sniff="$TMP/toc.sniff"
    last="$(tape_last_file_number "$vt")"; [ "${last:-0}" -ge 1 ] 2>/dev/null || return 1
    n="$last"
    while [ "$n" -ge 1 ]; do
        if tape_sniff_first_block "$vt" "$n" "$sniff" 2>/dev/null \
           && [ "$(head -1 "$sniff" 2>/dev/null | tr -d '\0')" = "# BRIC tape TOC v1" ] \
           && tape_read_file "$vt" "$n" "$tmp" 2>/dev/null; then
            cat "$tmp"; return 0
        fi
        n=$((n - 1))
    done
    return 1
}

# 1) Read all TOCs; build chunk_location "run|chunk|role" -> "vt|file"; find the catalogs.
declare -A CHUNK_AT
CAT_VT=""; CAT_FN=""; CAT_SHA=""
ESC_VT=""; ESC_FN=""; ESC_SHA=""
SYS_VT=""; SYS_FN=""; SYS_SHA=""   # legacy Review <=30E
for vt in $(tape_list_volumetags); do
    toc="$(toc_text_of_tape "$vt")" || { log "no TOC on $vt (skipping)"; continue; }
    tproj="$(printf '%s\n' "$toc" | awk -F= '/^project=/{print $2; exit}')"
    [ "$tproj" = "$PROJECT" ] || continue
    log "reading TOC of $vt"
    while IFS='|' read -r file kind run chunk role fname sha; do
        case "$kind" in
            CHUNK)    CHUNK_AT["$run|$chunk|$role"]="$vt|$file";;
            ARTIFACT)
                [ "$fname" = catalog_project.enc ] && { CAT_VT="$vt"; CAT_FN="$file"; CAT_SHA="$sha"; }
                [ "$fname" = user_key_escrow.v1 ]  && { ESC_VT="$vt"; ESC_FN="$file"; ESC_SHA="$sha"; }
                [ "$fname" = catalog_system.enc ]  && { SYS_VT="$vt"; SYS_FN="$file"; SYS_SHA="$sha"; }
                ;;
        esac
    done < <(printf '%s\n' "$toc" | awk -F'|' '/^[0-9]+\|/ && NF>=2 {print}')
done
[ -n "$CAT_VT" ] || die "catalog_project.enc not found on any tape for project $PROJECT"

# 1b) Acquire the user key. New tapes carry a small project-bound escrow ciphertext; old tapes may
# carry a full catalog_system.enc. Both paths yield the same authenticated escrow string.
unwrap_escrow() { # escrow owner -> USER_KEY
    local escrow="$1" owner="$2" body ehmac ect mhk want
    case "$escrow" in
        v2:*)
            body="${escrow#v2:}"; ehmac="${body%%:*}"; ect="${body#*:}"
            mhk="$(printf '%s:escrow-auth' "$(cat "$MKF")" | sha256sum | awk '{print $1}')"
            want="$(printf '%s' "$ect" | openssl dgst -sha256 -hmac "$mhk" | awk '{print $NF}')"
            [ "$ehmac" = "$want" ] || die "escrow HMAC verification FAILED for '$owner' — wrapped key tampered/corrupt"
            USER_KEY="$(printf '%s' "$ect" | openssl enc -d -aes-256-cbc -pbkdf2 -iter 10000 -a -A -pass file:"$MKF")" \
                || die "failed to unwrap owner key from escrow (wrong master key?)"
            ;;
        *)
            USER_KEY="$(printf '%s' "$escrow" | openssl enc -d -aes-256-cbc -pbkdf2 -iter 10000 -a -pass file:"$MKF")" \
                || die "failed to unwrap legacy owner key escrow (wrong master key?)"
            ;;
    esac
}

ADMIN_OWNER=""
if [ -n "$MKF" ]; then
    [ -f "$MKF" ] || die "master key file not found: $MKF"
    if [ -n "$ESC_VT" ]; then
        tape_read_file "$ESC_VT" "$ESC_FN" "$TMP/escrow.v1"
        if [ -n "$ESC_SHA" ]; then
            got="$(sha256sum "$TMP/escrow.v1" | awk '{print $1}')"
            [ "$got" = "$ESC_SHA" ] || die "user_key_escrow.v1 sha256 mismatch vs TOC ($ESC_VT#$ESC_FN) — media corruption"
        fi
        [ "$(head -1 "$TMP/escrow.v1" 2>/dev/null)" = BRIC-USER-ESCROW-V1 ] || die "invalid user_key_escrow.v1 header"
        EPROJECT="$(awk -F= '/^project=/{print substr($0,9); exit}' "$TMP/escrow.v1")"
        ADMIN_OWNER="$(awk -F= '/^owner=/{print substr($0,7); exit}' "$TMP/escrow.v1")"
        EB64="$(awk -F= '/^escrow_b64=/{print substr($0,12); exit}' "$TMP/escrow.v1")"
        [ "$EPROJECT" = "$PROJECT" ] || die "escrow project binding mismatch: expected $PROJECT got '$EPROJECT'"
        [ -n "$ADMIN_OWNER" ] && [ -n "$EB64" ] || die "incomplete user_key_escrow.v1"
        ESCROW="$(printf '%s' "$EB64" | openssl base64 -d -A 2>/dev/null)" || die "cannot decode escrow artifact"
        [ -n "$ESCROW" ] || die "decoded escrow is empty"
        unwrap_escrow "$ESCROW" "$ADMIN_OWNER"
        log "ADMIN break-glass: recovered owner '$ADMIN_OWNER' key from project escrow via the master key"
    elif [ -n "$SYS_VT" ]; then
        # Legacy Review <=30E path.
        tape_read_file "$SYS_VT" "$SYS_FN" "$TMP/sys.enc"
        if [ -n "$SYS_SHA" ]; then
            got="$(sha256sum "$TMP/sys.enc" | awk '{print $1}')"
            [ "$got" = "$SYS_SHA" ] || die "catalog_system.enc sha256 mismatch vs TOC ($SYS_VT#$SYS_FN) — media corruption"
        fi
        openssl enc -d -aes-256-cbc -pbkdf2 -iter 10000 -pass file:"$MKF" -in "$TMP/sys.enc" -out "$TMP/sys.sql" \
            || die "cannot decrypt legacy catalog_system.enc (wrong master key?)"
        sqlite3 "$TMP/sysdb" < "$TMP/sys.sql" >/dev/null || die "cannot load legacy system catalog"
        ADMIN_OWNER="$(sqlite3 -batch "$TMP/sysdb" "SELECT owner FROM projects WHERE project_name='$(dq "$PROJECT")';")"
        [ -n "$ADMIN_OWNER" ] || die "project $PROJECT not present in legacy system catalog"
        ESCROW="$(sqlite3 -batch "$TMP/sysdb" "SELECT key_escrow FROM users WHERE username='$(dq "$ADMIN_OWNER")';")"
        [ -n "$ESCROW" ] || die "no key escrow for legacy owner '$ADMIN_OWNER'"
        unwrap_escrow "$ESCROW" "$ADMIN_OWNER"
        log "ADMIN break-glass: recovered owner '$ADMIN_OWNER' key from legacy system catalog"
    else
        die "neither user_key_escrow.v1 nor legacy catalog_system.enc is present — admin recovery unavailable"
    fi
else
    [ -f "$UKF" ] || die "user key file not found: $UKF"
    USER_KEY="$(cat "$UKF")"
fi
ENC_KEY=$(printf '%s:encryption'     "$USER_KEY" | sha256sum | awk '{print $1}')
HMAC_KEY=$(printf '%s:authentication' "$USER_KEY" | sha256sum | awk '{print $1}')
PASS="$TMP/pass"; printf '%s' "$ENC_KEY" > "$PASS"; chmod 600 "$PASS"
unset USER_KEY

# 2) Read + decrypt the project catalog (user key) and load it.
tape_read_file "$CAT_VT" "$CAT_FN" "$TMP/cat.enc"
# Integrity before decrypt (I6 anche per i cataloghi): sha256 from the plaintext TOC.
if [ -n "$CAT_SHA" ]; then
    got="$(sha256sum "$TMP/cat.enc" | awk '{print $1}')"
    [ "$got" = "$CAT_SHA" ] || die "catalog_project.enc sha256 mismatch vs TOC ($CAT_VT#$CAT_FN) — media corruption; try the other tape of the pair"
fi
openssl enc -d -aes-256-cbc -pbkdf2 -iter 10000 -pass file:"$PASS" -in "$TMP/cat.enc" -out "$TMP/cat.sql" \
    || die "cannot decrypt catalog_project.enc (wrong user key?)"
DRDB="$TMP/dr.db"; sqlite3 "$DRDB" < "$TMP/cat.sql" >/dev/null
# Review 34 is backward-compatible with old on-tape project catalogs: mode/ACL/xattr metadata did
# not exist there, but mtime did. Add nullable/default columns in the temporary DR database only.
if [ "$(sqlite3 -batch "$DRDB" "SELECT COUNT(*) FROM pragma_table_info('files') WHERE name='mode';")" -eq 0 ]; then sqlite3 -batch "$DRDB" "ALTER TABLE files ADD COLUMN mode INTEGER;"; fi
if [ "$(sqlite3 -batch "$DRDB" "SELECT COUNT(*) FROM pragma_table_info('files') WHERE name='metadata_b64';")" -eq 0 ]; then sqlite3 -batch "$DRDB" "ALTER TABLE files ADD COLUMN metadata_b64 TEXT NOT NULL DEFAULT '';"; fi
if [ -n "${ADMIN_OWNER:-}" ]; then
    CAT_OWNER="$(sqlite3 -batch "$DRDB" "SELECT owner FROM projects WHERE project_name='$(dq "$PROJECT")';")"
    [ "$CAT_OWNER" = "$ADMIN_OWNER" ] || die "escrow owner '$ADMIN_OWNER' does not match project catalog owner '$CAT_OWNER'"
fi
log "project catalog recovered from $CAT_VT#$CAT_FN"
q()  { sqlite3 -batch "$DRDB" "$1"; }
qc() { sqlite3 -batch -separator '|' "$DRDB" "$1"; }
# NUL/newline-safe query: .mode ascii uses 0x1f between fields and 0x1e between records, so paths
# containing newlines, pipes or other hostile bytes survive disaster recovery intact.
qa() { sqlite3 -batch "$DRDB" ".mode ascii" "$1"; }
# Read a chunk blob into $TMP/blob.enc and authenticate it (Encrypt-then-MAC) against the recovered
# catalog before it is ever decrypted. On HMAC failure, automatically fall back to the other copy:
# this is the whole point of DR — a corrupted PRIMARY tape must be transparently healed by BACKUP.
read_good_blob() {  # run chunk -> rc 0 and $TMP/blob.enc verified; rc 1 if no good copy
    local run="$1" chunk="$2" ph role loc got
    ph="$(q "SELECT payload_hmac FROM chunks WHERE run_id='$(dq "$run")' AND chunk_no=$chunk;")"
    for role in PRIMARY BACKUP; do
        loc="${CHUNK_AT[$run|$chunk|$role]:-}"; [ -n "$loc" ] || continue
        tape_read_file "${loc%%|*}" "${loc##*|}" "$TMP/blob.enc" 2>/dev/null || { log "read fail $run/$chunk $role"; continue; }
        if [ -z "$ph" ]; then log "WARN no payload_hmac for $run/$chunk in catalog — accepting $role unverified"; return 0; fi
        got="$(openssl dgst -sha256 -hmac "$HMAC_KEY" "$TMP/blob.enc" | awk '{print $NF}')"
        [ "$got" = "$ph" ] && return 0
        log "HMAC FAIL $run/$chunk on $role copy — trying next copy"
    done
    return 1
}

# Review 33 helpers: prepare existing ancestors before payload writes and treat directory entries in
# each TAR_PART as an APPLYING transaction until their archive-final metadata is captured and relaxed.
dr_prepare_chunk_paths() { # run chunk
    local run="$1" chunk="$2" rel et
    while IFS=$'\x1f' read -r -d $'\x1e' rel et; do
        [ -n "$rel" ] || continue
        rtxn_prepare_ancestors "$rel" || die "cannot prepare DR ancestors for $rel"
        if [ "$et" = D ]; then rtxn_mark_applying "$DEST/$rel" || die "cannot journal DR directory before extraction: $rel"; fi
    done < <(qa "SELECT rel_path,entry_type FROM files WHERE run_id='$(dq "$run")' AND chunk_no=$chunk ORDER BY (length(rel_path)-length(replace(rel_path,'/',''))) ASC,length(rel_path) ASC;")
}
dr_refresh_chunk_dirs() { # run chunk
    local run="$1" chunk="$2" rel
    while IFS= read -r -d $'\x1e' rel; do
        [ -n "$rel" ] || continue
        rtxn_refresh_relax "$DEST/$rel" || die "cannot capture/relax DR directory metadata: $rel"
    done < <(qa "SELECT rel_path FROM files WHERE run_id='$(dq "$run")' AND chunk_no=$chunk AND entry_type='D' ORDER BY (length(rel_path)-length(replace(rel_path,'/',''))) ASC,length(rel_path) ASC;")
}


dr_apply_large_metadata() { # run rel destination-rel
    local run="$1" rel="$2" target="$3" row mode_dec mt meta mode_oct
    [ "$(q "SELECT COUNT(*) FROM chunks WHERE run_id='$(dq "$run")' AND type='LARGE_FILE_CHUNK' AND big_rel_path='$(dq "$rel")';")" -gt 0 ] || return 0
    row="$(q "SELECT COALESCE(mode,'')||'|'||COALESCE(mtime,'')||'|'||COALESCE(metadata_b64,'') FROM files WHERE run_id='$(dq "$run")' AND rel_path='$(dq "$rel")';")"
    IFS='|' read -r mode_dec mt meta <<< "$row"
    mode_oct=""; [ -z "$mode_dec" ] || printf -v mode_oct '%04o' "$mode_dec"
    local mrc=0
    if [ "$ALLOW_METADATA_DEGRADATION" -eq 1 ]; then
        "$META_HELPER" apply "$DEST/$target" "$mode_oct" "$mt" "$meta" --allow-degradation || mrc=$?
        case "$mrc" in
            0) :;;
            4) METADATA_DEGRADED=1; log "WARNING METADATA-DEGRADED large file: $target";;
            *) return "$mrc";;
        esac
    else
        "$META_HELPER" apply "$DEST/$target" "$mode_oct" "$mt" "$meta" || return 1
    fi
    log "METADATA-RESTORED large file: $target${mode_dec:+ mode=$mode_oct}${mt:+ mtime=$mt}"
}

# 3) Rebuild every file of every run of the project, straight from tape.
rc=0; n_files=0; DR_VERIFY_DESTINATION=0; DR_VERIFY_STREAM=0; DR_VERIFY_NODIGEST=0; DR_VERIFY_MISMATCH=0

# --file MODE: recover only one relative path (latest run that holds it), then stop.
if [ -n "$FILE" ]; then
    run=""; BIG=0
    for r in $(q "SELECT run_id FROM runs WHERE project_name='$(dq "$PROJECT")' ORDER BY run_id DESC;"); do
        b="$(q "SELECT COUNT(*) FROM chunks WHERE run_id='$(dq "$r")' AND big_rel_path='$(dq "$FILE")';")"
        f="$(q "SELECT COUNT(*) FROM files  WHERE run_id='$(dq "$r")' AND rel_path='$(dq "$FILE")';")"
        if [ "${b:-0}" -gt 0 ] || [ "${f:-0}" -gt 0 ]; then run="$r"; BIG="${b:-0}"; break; fi
    done
    [ -n "$run" ] || die "file not found in project '$PROJECT': $FILE"
    if [ "$BIG" -gt 0 ]; then
        rtxn_prepare_ancestors "$FILE" || die "cannot prepare DR ancestors for $FILE"
        mkdir -p "$DEST/$(dirname "$FILE")"; : > "$DEST/$FILE"
        for chunk in $(q "SELECT chunk_no FROM chunks WHERE run_id='$(dq "$run")' AND big_rel_path='$(dq "$FILE")' ORDER BY chunk_index;"); do
            read_good_blob "$run" "$chunk" || die "unrecoverable piece of $FILE (no valid copy on tape)"
            openssl enc -d -aes-256-cbc -pbkdf2 -iter 10000 -pass file:"$PASS" -in "$TMP/blob.enc" >> "$DEST/$FILE"
        done
    else
        chunk="$(q "SELECT chunk_no FROM files WHERE run_id='$(dq "$run")' AND rel_path='$(dq "$FILE")';")"
        [ -n "$chunk" ] || die "no chunk maps file: $FILE"
        read_good_blob "$run" "$chunk" || die "unrecoverable chunk for $FILE (no valid copy on tape)"
        rtxn_prepare_ancestors "$FILE" || die "cannot prepare DR ancestors for $FILE"
        file_et="$(q "SELECT entry_type FROM files WHERE run_id='$(dq "$run")' AND rel_path='$(dq "$FILE")';")"
        if [ "$file_et" = D ]; then rtxn_mark_applying "$DEST/$FILE" || die "cannot journal selected DR directory: $FILE"; fi
        openssl enc -d -aes-256-cbc -pbkdf2 -iter 10000 -pass file:"$PASS" -in "$TMP/blob.enc" | dr_tar_restore_payload "$DEST" "$FILE"
        if [ "$file_et" = D ]; then rtxn_refresh_relax "$DEST/$FILE" || die "cannot capture selected DR directory metadata: $FILE"; fi
    fi
    rtxn_sync_destination "$DEST" || die "sync failed for DR destination: $DEST"
    want="$(q "SELECT sha256_plain FROM files WHERE run_id='$(dq "$run")' AND rel_path='$(dq "$FILE")';")"
    if ! dr_verify_file "$FILE" "$DEST/$FILE" "$want"; then
        dr_log_verify_summary
        die "recovery FAILED verification: $FILE"
    fi
    if [ "$BIG" -gt 0 ]; then dr_apply_large_metadata "$run" "$FILE" "$FILE" || die "cannot restore large-file metadata: $FILE"; rtxn_sync_destination "$DEST" || die "sync failed after DR file metadata"; fi
    dr_log_verify_summary
    if [ "$REQUIRE_DEST_VERIFY" -eq 1 ] && [ "$DR_VERIFY_STREAM" -gt 0 ]; then
        die "destination verification required but $DR_VERIFY_STREAM object(s) are VERIFIED-STREAM only"
    fi
    if ! rtxn_finalize; then RTXN_PRESERVE=1; die "DR metadata finalization failed; journal preserved at ${RTXN_DB:-unknown}"; fi
    if [ "$METADATA_DEGRADED" -eq 1 ]; then log "disaster recovery payload complete: 1 file recovered -> $DEST/$FILE; METADATA FIDELITY DEGRADED"; else log "disaster recovery complete: 1 file recovered -> $DEST/$FILE"; fi
    exit 0
fi

# Runs in run_id order (lexicographic == chronological: project__UTCstamp__counter), so when the
# same path exists in more runs the LATEST run deterministically wins — same semantics as --file.
# Within a run, ALL chunks are processed in chunk_no order, interleaving TAR_PART and
# LARGE_FILE_CHUNK exactly like bric-restore: the trailing metadata chunk (directory modes/mtimes,
# possibly RESTRICTIVE, e.g. read-only frozen datasets) must be extracted LAST, after every large
# file has been written into its directory — otherwise DR fails with EACCES for non-root users.
for run in $(q "SELECT DISTINCT run_id FROM runs WHERE project_name='$(dq "$PROJECT")' ORDER BY run_id;"); do
    while IFS=$'\x1f' read -r -d $'\x1e' chunk ctype cidx bigrel; do
        [ -n "$chunk" ] || continue
        if [ "$ctype" = TAR_PART ]; then
            read_good_blob "$run" "$chunk" || { log "MISSING/UNRECOVERABLE chunk $run/$chunk (no valid copy on tape)"; rc=1; continue; }
            dr_prepare_chunk_paths "$run" "$chunk"
            openssl enc -d -aes-256-cbc -pbkdf2 -iter 10000 -pass file:"$PASS" -in "$TMP/blob.enc" | dr_tar_restore_payload "$DEST"
            dr_refresh_chunk_dirs "$run" "$chunk"
        else
            [ -n "$bigrel" ] || continue
            rtxn_prepare_ancestors "$bigrel" || die "cannot prepare DR ancestors for $bigrel"
            mkdir -p "$DEST/$(dirname "$bigrel")"
            [ "$cidx" = 1 ] && : > "$DEST/$bigrel"     # first piece truncates (even on read failure: never append to stale content); the rest append in chunk_no order
            read_good_blob "$run" "$chunk" || { log "MISSING/UNRECOVERABLE piece $run/$chunk (no valid copy)"; rc=1; continue; }
            openssl enc -d -aes-256-cbc -pbkdf2 -iter 10000 -pass file:"$PASS" -in "$TMP/blob.enc" >> "$DEST/$bigrel"
        fi
    done < <(qa "SELECT chunk_no,type,COALESCE(chunk_index,''),COALESCE(big_rel_path,'') FROM chunks WHERE run_id='$(dq "$run")' ORDER BY chunk_no;")
    rtxn_sync_destination "$DEST" || die "sync failed for DR destination: $DEST"
    while IFS=$'\x1f' read -r -d $'\x1e' rel want; do
        [ -n "$rel" ] || continue; n_files=$((n_files+1))
        dr_verify_file "$rel" "$DEST/$rel" "$want" || rc=1
    done < <(qa "SELECT rel_path,COALESCE(sha256_plain,'') FROM files WHERE run_id='$(dq "$run")' AND entry_type NOT IN ('D','L');")
    if [ "$rc" -eq 0 ]; then
        while IFS= read -r rel; do [ -n "$rel" ] && { dr_apply_large_metadata "$run" "$rel" "$rel" || rc=1; }; done < <(q "SELECT DISTINCT big_rel_path FROM chunks WHERE run_id='$(dq "$run")' AND type='LARGE_FILE_CHUNK' AND big_rel_path IS NOT NULL AND big_rel_path<>'' ORDER BY big_rel_path;")
        [ "$rc" -ne 0 ] || rtxn_sync_destination "$DEST" || rc=1
    fi
done
dr_log_verify_summary
if [ "$REQUIRE_DEST_VERIFY" -eq 1 ] && [ "$DR_VERIFY_STREAM" -gt 0 ]; then rc=1; log "destination verification required but $DR_VERIFY_STREAM object(s) are VERIFIED-STREAM only"; fi
if ! rtxn_finalize; then RTXN_PRESERVE=1; die "DR metadata finalization failed; journal preserved at ${RTXN_DB:-unknown}"; fi
[ "$rc" -eq 0 ] && { if [ "$METADATA_DEGRADED" -eq 1 ]; then log "disaster recovery payload complete: $n_files file(s) recovered; verification completed -> $DEST; METADATA FIDELITY DEGRADED"; else log "disaster recovery complete: $n_files file(s) recovered; verification completed -> $DEST"; fi; } \
                || die "recovery FAILED verification"
