#!/bin/bash
# Commit one completed encrypted stream chunk to the cluster catalog and atomically publish READY.
set -euo pipefail
IFS=$'\n\t'
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"; . "$HERE/lib_common.sh"
enforce_bus_signing
RUN_ID=""; CNO=""; TYPE=""; SIZE=""; SHA=""; HMAC=""; MANIFEST=""; PLAIN="0"; FILES="0"
BIG=""; CIDX=""; TOT=""; OFFSET=""; FILE_FINAL=""; FSIZE=""; FMTIME=""; FMODE=""; FMETA=""; FSHA=""; FIRST=""
while [ "$#" -gt 0 ]; do case "$1" in
 --run) RUN_ID="${2:-}";shift 2;; --chunk) CNO="${2:-}";shift 2;; --type) TYPE="${2:-}";shift 2;;
 --size) SIZE="${2:-}";shift 2;; --sha) SHA="${2:-}";shift 2;; --hmac) HMAC="${2:-}";shift 2;; --manifest) MANIFEST="${2:-}";shift 2;;
 --plain-total) PLAIN="${2:-}";shift 2;; --files-total) FILES="${2:-}";shift 2;; --big-rel) BIG="${2:-}";shift 2;;
 --chunk-index) CIDX="${2:-}";shift 2;; --total-chunks) TOT="${2:-}";shift 2;; --offset) OFFSET="${2:-}";shift 2;;
 --file-finalize) FILE_FINAL="${2:-}";shift 2;; --file-size) FSIZE="${2:-}";shift 2;; --file-mtime) FMTIME="${2:-}";shift 2;; --file-mode) FMODE="${2:-}";shift 2;; --file-metadata-b64) FMETA="${2:-}";shift 2;; --file-sha) FSHA="${2:-}";shift 2;; --first-chunk) FIRST="${2:-}";shift 2;;
 *) die "unknown option: $1";; esac; done
[ -n "$RUN_ID" ] || die "--run required"
if [ -n "$FILE_FINAL" ]; then
  sqlite3 -batch -cmd '.timeout 60000' "$BRIC_DB" "BEGIN IMMEDIATE; INSERT INTO files(run_id,rel_path,size_bytes,mtime,mode,metadata_b64,sha256_plain,chunk_no,member_index,entry_type) VALUES('$(sql_quote "$RUN_ID")','$(sql_quote "$FILE_FINAL")',$FSIZE,$FMTIME,$((8#$FMODE)),'$(sql_quote "$FMETA")','$FSHA',$FIRST,0,'F'); COMMIT;"
  exit 0
fi
[ -n "$CNO" ] && [ -n "$TYPE" ] && [ -n "$SIZE" ] && [ -n "$MANIFEST" ] || die "chunk publish arguments incomplete"
IFS='|' read -r PROJECT OWNER <<EOF2
$(sqlc "SELECT project_name,owner FROM runs WHERE run_id='$(sql_quote "$RUN_ID")';")
EOF2
[ -n "$PROJECT" ] || die "run not found: $RUN_ID"
RUN_DIR="$(qnap_run_dir "$PROJECT" "$RUN_ID")"; BASE="$RUN_DIR/$(printf 'chunk_%04d' "$CNO")"; BLOB="$BASE.enc"
[ -s "$BLOB" ] || die "encrypted stream chunk missing: $BLOB"
CURSTATE="$(sql "SELECT state FROM chunks WHERE run_id='$(sql_quote "$RUN_ID")' AND chunk_no=$CNO;")"
case "$CURSTATE" in
  '') PRE_SQL="";;
  ALLOCATED) PRE_SQL="UPDATE chunks SET type='$(sql_quote "$TYPE")',size_bytes=$SIZE,payload_sha256='$SHA',payload_hmac='$HMAC',state='PRODUCED',qnap_path='$(sql_quote "$BLOB")',updated_at=datetime('now') WHERE run_id='$(sql_quote "$RUN_ID")' AND chunk_no=$CNO AND state='ALLOCATED';";;
  *) die "refusing to publish chunk $CNO over existing state '$CURSTATE'";;
esac
{
 printf 'PRAGMA foreign_keys=ON;\nBEGIN IMMEDIATE;\n'
 if [ -n "$PRE_SQL" ]; then
   printf '%s\n' "$PRE_SQL"
   if [ "$TYPE" = LARGE_FILE_CHUNK ]; then
     printf "UPDATE chunks SET big_rel_path='%s',chunk_index=%s,total_chunks=%s,offset_bytes=%s WHERE run_id='%s' AND chunk_no=%s;\n" "$(sql_quote "$BIG")" "$CIDX" "$TOT" "$OFFSET" "$(sql_quote "$RUN_ID")" "$CNO"
   fi
 else
   if [ "$TYPE" = LARGE_FILE_CHUNK ]; then
     printf "INSERT INTO chunks(run_id,chunk_no,type,size_bytes,payload_sha256,payload_hmac,state,qnap_path,big_rel_path,chunk_index,total_chunks,offset_bytes) VALUES('%s',%s,'%s',%s,'%s','%s','PRODUCED','%s','%s',%s,%s,%s);\n" "$(sql_quote "$RUN_ID")" "$CNO" "$TYPE" "$SIZE" "$SHA" "$HMAC" "$(sql_quote "$BLOB")" "$(sql_quote "$BIG")" "$CIDX" "$TOT" "$OFFSET"
   else
     printf "INSERT INTO chunks(run_id,chunk_no,type,size_bytes,payload_sha256,payload_hmac,state,qnap_path) VALUES('%s',%s,'%s',%s,'%s','%s','PRODUCED','%s');\n" "$(sql_quote "$RUN_ID")" "$CNO" "$TYPE" "$SIZE" "$SHA" "$HMAC" "$(sql_quote "$BLOB")"
   fi
 fi
 cat "$MANIFEST"
 # In parallel mode --plain-total/--files-total are worker-local counters.  Derive authoritative
 # run aggregates from catalog rows instead, which is also correct for the sequential producer.
 printf "UPDATE runs SET n_chunks=(SELECT COUNT(*) FROM chunks WHERE run_id='%s' AND state<>'ALLOCATED'), total_bytes=COALESCE((SELECT SUM(size_bytes) FROM files WHERE run_id='%s' AND entry_type='F'),0) WHERE run_id='%s';\nCOMMIT;\n" "$(sql_quote "$RUN_ID")" "$(sql_quote "$RUN_ID")" "$(sql_quote "$RUN_ID")"
} | sqlite3 -batch -cmd '.timeout 60000' "$BRIC_DB"
printf '%s  %s\n' "$SHA" "$(basename "$BLOB")" > "$BASE.enc.sha256"; printf '%s\n' "$HMAC" > "$BASE.enc.hmac"
marker_set_signed "$RUN_DIR" "$(printf 'chunk_%04d.meta' "$CNO")" "run_id=$RUN_ID
project=$PROJECT
owner=$OWNER
chunk_no=$CNO
type=$TYPE
size_bytes=$SIZE
payload_sha256=$SHA"
marker_set_signed "$RUN_DIR" "$(printf 'chunk_%04d.READY' "$CNO")" "sha256=$SHA
size_bytes=$SIZE"
sql "UPDATE chunks SET state='READY',updated_at=datetime('now') WHERE run_id='$(sql_quote "$RUN_ID")' AND chunk_no=$CNO;"
BRIC_LOG_BYTES="$SIZE" chunk_status_event "$RUN_ID" "$PROJECT" "$CNO" READY "tar-stream payload_sha256=$SHA"
log "stream chunk $CNO READY ($SIZE bytes)"
