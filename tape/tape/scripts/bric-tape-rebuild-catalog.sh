#!/bin/bash
# bric-tape-rebuild-catalog: reconstruct a tape_catalog.db FROM THE TAPES ALONE.
#
# The real long-term disaster: the tape server is gone and its SQLite catalog with it, but the LTO
# cartridges survive. Every tape ends with a plaintext "# BRIC tape TOC v1" (the last file written at
# close), which indexes every VERIFIED file on that tape: for each chunk its (file_number, run_id,
# chunk_no, copy_role, payload_sha256), and for each close artifact its (file_number, filename, sha256).
# We read the latest TOC of every cartridge and rebuild the tapes / segments / tape_artifacts rows.
#
# What CAN be rebuilt from the plaintext TOCs: which segment/artifact sits on which tape at which file
# number, its sha256, role, chunk number, and the run/project (the TOC header binds the project; tape
# exclusivity = one project per tape). What CANNOT: the owner and the per-file size — both live only
# inside the ENCRYPTED catalog_project.enc (owner) / are physical (size). owner is left '' and size is
# filled only by --verify (which reads each file back). reservation rows are transient and not rebuilt.
#
#   bric-tape-rebuild-catalog.sh --out NEW.db [--tapelib DIR] [--verify]
#     --verify : read every indexed file off tape, check its sha256 against the TOC, and fill
#                segments.size_bytes + tapes.used_tb. Slower (reads all data) but authoritative.
set -euo pipefail
IFS=$'\n\t'
umask 077
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
. "$HERE/lib_common.sh"
. "$HERE/lib_tape_io.sh"
bric_log_process_start "tape-rebuild-catalog" "$@"
require_cmds sqlite3 awk sha256sum grep

OUT=""; VERIFY=no; PRIMARY_PARITY_NAME="${BRIC_PRIMARY_PARITY:-even}"
while [ "$#" -gt 0 ]; do case "$1" in
    --out) OUT="${2:-}"; shift 2;;
    --tapelib) BRIC_TAPELIB="${2:-}"; export BRIC_TAPELIB; shift 2;;
    --verify) VERIFY=yes; shift;;
    --primary-parity) PRIMARY_PARITY_NAME="${2:-}"; shift 2;;
    -h|--help) sed -n '2,16p' "$0"; exit 0;;
    *) die "unknown option: $1";; esac; done
[ -n "$OUT" ] || die "usage: bric-tape-rebuild-catalog --out NEW.db [--tapelib DIR] [--verify] [--primary-parity even|odd]"
[ -e "$OUT" ] && die "refusing to overwrite existing file: $OUT (point --out at a fresh path)"
case "$PRIMARY_PARITY_NAME" in even) PRIMARY_PARITY=0;; odd) PRIMARY_PARITY=1;; *) die "--primary-parity must be even|odd";; esac

TMP="$(mktemp -d)"
_rebuild_exit(){ local rc=$?; trap - EXIT; rm -rf "$TMP"; bric_log_process_end "$rc"; exit "$rc"; }
trap _rebuild_exit EXIT
sqlite3 "$OUT" < "$BRIC_TAPE_SQL_INIT" >/dev/null || die "failed to initialise schema in $OUT"
rdb() { sqlite3 -batch -cmd '.timeout 60000' "$OUT" "$1"; }   # write into the REBUILT catalog

# Read the latest TOC of a tape: echoes its tape file number and leaves the TOC text in $TMP/latest_toc.
read_latest_toc() {  # vt -> echoes FILE_NUMBER (text in $TMP/latest_toc), or rc 1 if none found
    # Backward scan from EOD to file 1 (no fixed window): an in-flight/aborted later run can have
    # appended many chunk blobs after the last TOC on BOTH tapes; a small window made such tapes
    # invisible to the rebuild. Candidates are sniffed on their FIRST BLOCK only
    # (tape_sniff_first_block): on real hardware a full read of a non-TOC probe is a 128 GB blob.
    local vt="$1" last n t="$TMP/latest_toc" sniff="$TMP/latest_toc.sniff"
    last="$(tape_last_file_number "$vt")"; [ "${last:-0}" -ge 1 ] 2>/dev/null || return 1
    n="$last"
    while [ "$n" -ge 1 ]; do
        if tape_sniff_first_block "$vt" "$n" "$sniff" 2>/dev/null \
           && [ "$(head -1 "$sniff" 2>/dev/null | tr -d '\0')" = "# BRIC tape TOC v1" ] \
           && tape_read_file "$vt" "$n" "$t" 2>/dev/null; then
            echo "$n"; return 0
        fi
        n=$((n-1))
    done
    return 1
}

# Derive pair number / sibling barcode from the numeric part of the volumetag. Convention: BACKUP is
# always PRIMARY+1; which parity is PRIMARY is set by --primary-parity (default even = pari onsite).
# This is the fallback for role on an EMPTY tape and for pairing; on written tapes the role comes from
# the TOC's copy_role. Real pairing should still be re-validated against the library inventory.
vt_num()  { printf '%s' "$1" | grep -o '[0-9]\+' | head -1; }
vt_is_primary() { local n; n="$(vt_num "$1")"; [ -n "$n" ] && [ $(( 10#$n % 2 )) -eq "$PRIMARY_PARITY" ]; }
pair_of() {  # (primary_num - PRIMARY_PARITY)/2 + 1, where PRIMARY_PARITY is the first primary index
    local n p; n="$(vt_num "$1")"; [ -n "$n" ] || { echo 0; return; }
    if vt_is_primary "$1"; then p=$(( 10#$n )); else p=$(( 10#$n - 1 )); fi
    echo $(( (p - PRIMARY_PARITY)/2 + 1 ))
}
sibling_of() {  # keep the same prefix/width/suffix; PRIMARY -> +1 (BACKUP=PRIMARY+1), BACKUP -> -1
    local vt="$1" n w pre suf step sib
    n="$(vt_num "$vt")"; [ -n "$n" ] || { echo ""; return; }
    pre="${vt%%"$n"*}"; suf="${vt#*"$n"}"; w="${#n}"
    if vt_is_primary "$vt"; then step=1; else step=-1; fi
    sib=$(( 10#$n + step )); printf '%s%0*d%s' "$pre" "$w" "$sib" "$suf"
}
kind_of() {  # infer artifact kind from filename
    case "$1" in catalog_*.enc) echo CATALOG;; TAPE_TOC.txt) echo TOC;; *.sh|README*|*RECOVERY*) echo SCRIPT;; *) echo SCRIPT;; esac
}

N_TAPES=0; N_SEG=0; N_ART=0; N_MISMATCH=0; N_NOTOC=0
for vt in $(tape_list_volumetags); do
    [ -n "$vt" ] || continue
    TOC_FN="$(read_latest_toc "$vt")" || { log "no TOC on $vt — skipping (blank/foreign/partial tape)"; N_NOTOC=$((N_NOTOC+1)); continue; }
    toc="$(cat "$TMP/latest_toc")"
    project="$(printf '%s\n' "$toc" | awk -F= '/^project=/{print $2; exit}')"
    valid_name "$project" || { log "TOC on $vt has a non-conforming project '$project' — skipping"; continue; }

    # First pass: role of the tape = the copy_role of its chunks (a tape is all-PRIMARY or all-BACKUP).
    role="$(printf '%s\n' "$toc" | awk -F'|' '/^[0-9]+\|CHUNK\|/{print $5; exit}')"
    case "$role" in PRIMARY|BACKUP) ;; *) role="$(vt_is_primary "$vt" && echo PRIMARY || echo BACKUP)";; esac
    pair="$(pair_of "$vt")"; sib="$(sibling_of "$vt")"

    used_bytes=0; tape_sql=""
    # Re-insert the rows. The TOC body lists every VERIFIED chunk and non-TOC artifact, one safe line each.
    while IFS='|' read -r file kind run chunk crole fname sha; do
        [ -n "$file" ] || continue
        size="NULL"
        if [ "$VERIFY" = yes ]; then
            if tape_read_file "$vt" "$file" "$TMP/f" 2>/dev/null; then
                a="$(sha256sum "$TMP/f" | awk '{print $1}')"
                if [ -n "$sha" ] && [ "$a" != "$sha" ]; then log "MISMATCH $vt file $file: TOC=$sha read=$a"; N_MISMATCH=$((N_MISMATCH+1)); fi
                s="$(stat -c%s "$TMP/f" 2>/dev/null || wc -c < "$TMP/f")"; size="$s"; used_bytes=$((used_bytes + s))
            else
                log "READ FAIL $vt file $file (indexed in TOC but unreadable)"; N_MISMATCH=$((N_MISMATCH+1))
            fi
        fi
        if [ "$kind" = CHUNK ]; then
            # seg_id MUST match the daemon's format exactly (chunk zero-padded to 4): a divergent id
            # on a rebuilt catalog would let a later INSERT OR REPLACE create a DUPLICATE row for the
            # same physical segment instead of replacing it (double TOC entries, double accounting).
            local_seg="${run}__c$(printf '%04d' "$chunk")__${crole}"
            tape_sql="$tape_sql
INSERT OR REPLACE INTO segments (seg_id,run_id,project_name,owner,chunk_no,copy_role,volumetag,file_number,payload_sha256,size_bytes,state,verified_at)
VALUES ('$(sql_quote "$local_seg")','$(sql_quote "$run")','$(sql_quote "$project")','',$chunk,'$(sql_quote "$crole")','$(sql_quote "$vt")',$file,'$(sql_quote "$sha")',$size,'VERIFIED',datetime('now'));"
            N_SEG=$((N_SEG+1))
        elif [ "$kind" = ARTIFACT ]; then
            aid="${run}__close__${vt}__${fname}"
            tape_sql="$tape_sql
INSERT OR REPLACE INTO tape_artifacts (artifact_id,run_id,project_name,volumetag,filename,kind,file_number,sha256,state,verified_at)
VALUES ('$(sql_quote "$aid")','$(sql_quote "$run")','$(sql_quote "$project")','$(sql_quote "$vt")','$(sql_quote "$fname")','$(kind_of "$fname")',$file,'$(sql_quote "$sha")','VERIFIED',datetime('now'));"
            N_ART=$((N_ART+1))
        fi
    done < <(printf '%s\n' "$toc" | awk -F'|' '/^[0-9]+\|(CHUNK|ARTIFACT)\|/{print}')

    # Re-register the TOC itself as a (TOC-kind) artifact at the file number we read it from.
    if [ -n "$TOC_FN" ]; then
        run_hdr="$(printf '%s\n' "$toc" | awk -F= '/^run_id=/{print $2; exit}')"
        tsha="$(printf '%s\n' "$toc" | sha256sum | awk '{print $1}')"   # note: re-hash of read text
        tape_sql="$tape_sql
INSERT OR REPLACE INTO tape_artifacts (artifact_id,run_id,project_name,volumetag,filename,kind,file_number,sha256,state,verified_at)
VALUES ('$(sql_quote "${run_hdr}__close__${vt}__TAPE_TOC.txt")','$(sql_quote "$run_hdr")','$(sql_quote "$project")','$(sql_quote "$vt")','TAPE_TOC.txt','TOC',$TOC_FN,'$(sql_quote "$tsha")','VERIFIED',datetime('now'));"
    fi

    used_tb="$([ "$VERIFY" = yes ] && awk -v b="$used_bytes" 'BEGIN{printf "%.9f", b/1000000000000}' || echo 0)"
    # Status: with --verify we know used_tb, so recompute FULL/PARTIAL with the same rule the daemon
    # uses (capacity - headroom - used < chunk_target). Without --verify used_tb is 0 and the tape is
    # left PARTIAL: the daemon would treat it as nearly empty, so resuming WRITES on a rebuilt catalog
    # without --verify risks physical overfill — hence the note printed at the end.
    tstatus="PARTIAL"
    if [ "$VERIFY" = yes ]; then
        h="$(rdb "SELECT value FROM config WHERE key='tape_headroom_tb';")"; h="${h:-0.30}"
        tgt="$(rdb "SELECT value FROM config WHERE key='chunk_target_bytes';")"; tgt="${tgt:-128000000000}"
        cap="${BRIC_TAPE_CAPACITY_TB:-18.0}"
        full="$(awk -v c="$cap" -v h="$h" -v u="$used_tb" -v t="$tgt" 'BEGIN{print ((c-h-u)*1000000000000 < t) ? 1 : 0}')"
        [ "$full" = 1 ] && tstatus="FULL"
    fi
    rdb "BEGIN IMMEDIATE;
INSERT OR REPLACE INTO tapes (volumetag,role,pair_number,paired_volumetag,project_name,used_tb,status,last_scan)
VALUES ('$(sql_quote "$vt")','$role',$pair,'$(sql_quote "$sib")','$(sql_quote "$project")',$used_tb,'$tstatus',datetime('now'));
$tape_sql
COMMIT;"
    N_TAPES=$((N_TAPES+1))
    log "rebuilt $vt (role=$role pair=$pair project=$project) from its TOC"
done

cat <<EOF

✓ Tape catalog rebuilt from tapes alone -> $OUT
  tapes:           $N_TAPES   (skipped, no TOC: $N_NOTOC)
  segments:        $N_SEG
  tape_artifacts:  $N_ART
  verify:          $([ "$VERIFY" = yes ] && echo "ON (sha re-checked, sizes filled); mismatches: $N_MISMATCH" || echo "off (run with --verify to re-check sha + fill sizes/used_tb)")

Notes:
  - segments.owner is '' (owner lives encrypted in catalog_project.enc, not in the plaintext TOC).
  - tape pairing (pair_number/paired_volumetag) is derived from the barcode numbering; re-validate it
    against the physical library inventory (mtx status) before resuming writes.
  - reservation rows are transient and intentionally not rebuilt; new runs reserve fresh.
EOF
[ "$VERIFY" = yes ] && [ "$N_MISMATCH" -gt 0 ] && exit 3
exit 0
