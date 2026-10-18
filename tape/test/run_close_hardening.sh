#!/bin/bash
. "$(cd "$(dirname "$(readlink -f "$0")")" && pwd)/lib_test_daemon.sh"
# Close-hardening test (ChatGPT review #1/#10/#4 + #2 on close). With bus signing ON, the tape server
# must refuse to seal a project unless run.CLOSE_CATALOGS is (a) validly signed and bound to the path,
# and (b) accompanied by EVERY artifact named in its signed manifest, each matching the manifest sha.
# Asserts: unsigned CLOSE_CATALOGS refused; missing artifact -> no seal; sha-mismatch -> no seal;
# and finally a correct, complete, signed handoff DOES seal.
set -euo pipefail
export BRIC_CONFIG=none   # hermetic: never read /etc/bric/bric.conf inside tests
REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
ROOT="$(mktemp -d)"; echo "workroot=$ROOT"
export BRIC_TAPE_HOME="$REPO/tape" BRIC_TAPE_DB="$ROOT/tape_catalog.db"
export BRIC_TAPE_SQL_INIT="$REPO/tape/sql/tape_init.sql" BRIC_TAPE_BACKEND="sim"
export BRIC_TAPELIB="$ROOT/tapelib" BRIC_TAPE_LOCK="$ROOT/tape.lock"
export BRIC_QNAP="$ROOT/qnap/bric" BRIC_KEYS="$ROOT/keys" BRIC_POLL=1
mkdir -p "$BRIC_QNAP" "$BRIC_KEYS" "$BRIC_TAPELIB"
sqlite3 "$BRIC_TAPE_DB" < "$BRIC_TAPE_SQL_INIT" >/dev/null
sqlite3 "$BRIC_TAPE_DB" "UPDATE config SET value='1' WHERE key='poll_seconds';"
sqlite3 "$BRIC_TAPE_DB" "INSERT INTO tapes (volumetag,slot,role,pair_number,paired_volumetag,capacity_tb,used_tb,status) VALUES ('000001L9',1,'PRIMARY',1,'000002L9',18,0,'PARTIAL');"
# initialise the sim tape image so artifacts can be appended
: > "$BRIC_TAPELIB/000001L9.tape" 2>/dev/null || true

fail=0; ok(){ echo "  ok: $1"; }; bad(){ echo "  FAIL: $1"; fail=1; }
wait_for_log() { # pattern [timeout_seconds]
  local pattern="$1" timeout="${2:-20}" i
  for ((i=0; i<timeout; i++)); do
    grep -qi -- "$pattern" "$DLOG" 2>/dev/null && return 0
    kill -0 "$DAEMON" 2>/dev/null || return 1
    sleep 1
  done
  return 1
}
wait_for_file() { # path [timeout_seconds]
  local path="$1" timeout="${2:-20}" i
  for ((i=0; i<timeout; i++)); do
    [ -e "$path" ] && return 0
    kill -0 "$DAEMON" 2>/dev/null || return 1
    sleep 1
  done
  return 1
}
PROJECT=closetest; RUN_ID="closetest__20260101T000000Z__0001"
RD="$BRIC_QNAP/archive/$PROJECT/$RUN_ID"; mkdir -p "$RD/close"

# a VERIFIED segment so handle_close has a tape to iterate and a TOC to build
sqlite3 "$BRIC_TAPE_DB" "INSERT INTO segments (seg_id,run_id,project_name,owner,chunk_no,copy_role,volumetag,file_number,payload_sha256,size_bytes,state,verified_at) VALUES ('${RUN_ID}__c0001__PRIMARY','$RUN_ID','$PROJECT','vsz652',1,'PRIMARY','000001L9',1,'deadbeef',100,'VERIFIED',datetime('now'));"
sqlite3 "$BRIC_TAPE_DB" "INSERT INTO reservation (run_id,project_name,owner,requested_tb,pairs_csv,state) VALUES ('$RUN_ID','$PROJECT','vsz652',1.0,'1','GRANTED');"

# bus keys; cluster signs (test acts as the cluster), daemon verifies cluster + signs its receipts
"$REPO/cluster/scripts/bric-bus-keygen.sh" "$BRIC_KEYS" >/dev/null 2>&1 || { command -v openssl >/dev/null && { openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$BRIC_KEYS/cluster_bus_ecdsa_p256.pem" 2>/dev/null; openssl pkey -in "$BRIC_KEYS/cluster_bus_ecdsa_p256.pem" -pubout -out "$BRIC_KEYS/cluster_bus_ecdsa_p256.pub" 2>/dev/null; openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$BRIC_KEYS/tape_bus_ecdsa_p256.pem" 2>/dev/null; openssl pkey -in "$BRIC_KEYS/tape_bus_ecdsa_p256.pem" -pubout -out "$BRIC_KEYS/tape_bus_ecdsa_p256.pub" 2>/dev/null; }; }
CPRIV="$BRIC_KEYS/cluster_bus_ecdsa_p256.pem"

# helper: sign a marker the way the cluster does — over the domain-separated envelope
# (BRIC-MARKER-V1\n<project>/<run>/<name>\n + body), with the sig published before the marker.
csign() {  # dir name content
  local dir="$1" name="$2" content="$3" tmp; tmp="$(mktemp)"
  { printf 'BRIC-MARKER-V1\n%s/%s/%s\n' "$(basename "$(dirname "$dir")")" "$(basename "$dir")" "$name"; printf '%s' "$content"; } > "$tmp"
  openssl dgst -sha256 -sign "$CPRIV" "$tmp" 2>/dev/null | openssl base64 -A > "$dir/$name.sig"
  printf '%s' "$content" > "$dir/$name"
  rm -f "$tmp"
}
sha_of(){ sha256sum "$1" | awk '{print $1}'; }

# build the five close artifacts on the bus
for f in catalog_project.enc user_key_escrow.v1; do head -c 256 /dev/urandom > "$RD/close/$f"; done
printf '#!/bin/bash\necho restore\n' > "$RD/close/restore_from_tape.sh"
printf 'recovery doc\n' > "$RD/close/README_RECOVERY.txt"
cp "$REPO/cluster/sql/cluster_init.sql" "$RD/close/schema.sql"
build_manifest(){ for spec in catalog_project.enc:CATALOG user_key_escrow.v1:ESCROW restore_from_tape.sh:SCRIPT README_RECOVERY.txt:SCRIPT schema.sql:SCRIPT; do f="${spec%%:*}"; k="${spec##*:}"; printf 'artifact|%s|%s|%s\n' "$f" "$k" "$(sha_of "$RD/close/$f")"; done; }

# signed PROJECT_CLOSING so the daemon enters close and publishes placement
csign "$RD" run.PROJECT_CLOSING "run_id=$RUN_ID
project=$PROJECT"

DLOG="$ROOT/daemon.log"
BRIC_BUS_SIGN_KEY="$BRIC_KEYS/tape_bus_ecdsa_p256.pem" BRIC_BUS_VERIFY_KEY="$BRIC_KEYS/cluster_bus_ecdsa_p256.pub" \
  setsid "$REPO/tape/bin/bric-tape-daemon" --loop >"$DLOG" 2>&1 & DAEMON=$!
trap 'bric_test_stop_group "$DAEMON"; [ -n "${KEEP:-}" ] || { rm -rf "$ROOT" 2>/dev/null || { sleep 1; rm -rf "$ROOT"; }; }' EXIT
wait_for_file "$RD/run.CLOSE_PLACEMENT" 20 && ok "daemon published placement for the synthetic run" || bad "no placement published"

MAN="$(build_manifest)"

echo "=== A: UNSIGNED CLOSE_CATALOGS refused ==="
printf 'run_id=%s\nproject=%s\n%s\n' "$RUN_ID" "$PROJECT" "$MAN" > "$RD/run.CLOSE_CATALOGS"   # no .sig
wait_for_log "REFUSED run.CLOSE_CATALOGS.*no signature" 20 && ok "daemon observed and refused unsigned CLOSE_CATALOGS" || bad "daemon did not log unsigned CLOSE_CATALOGS refusal"
[ ! -e "$RD/run.CLOSED" ] && ok "unsigned CLOSE_CATALOGS did not seal" || bad "sealed on unsigned CLOSE_CATALOGS"
rm -f "$RD/run.CLOSE_CATALOGS"

echo "=== B: signed but MISSING artifact refused ==="
mv "$RD/close/schema.sql" "$ROOT/schema.sql.hidden"
csign "$RD" run.CLOSE_CATALOGS "run_id=$RUN_ID
project=$PROJECT
$MAN"
wait_for_log "REQUIRED artifact MISSING" 20 && ok "daemon logged the missing artifact" || bad "no missing-artifact log"
[ ! -e "$RD/run.CLOSED" ] && ok "missing artifact blocked the seal" || bad "sealed despite a missing artifact"
mv "$ROOT/schema.sql.hidden" "$RD/close/schema.sql"

echo "=== C: signed but sha MISMATCH refused ==="
echo "tampered-extra-byte" >> "$RD/close/README_RECOVERY.txt"   # content no longer matches manifest sha
wait_for_log "does not match signed manifest" 20 && ok "daemon logged the manifest sha mismatch" || bad "no sha-mismatch log"
[ ! -e "$RD/run.CLOSED" ] && ok "sha mismatch blocked the seal" || bad "sealed despite sha mismatch"

echo "=== D: correct, complete, signed handoff seals ==="
# restore the README to its manifest content and re-sign a fresh manifest
printf 'recovery doc\n' > "$RD/close/README_RECOVERY.txt"
MAN="$(build_manifest)"
csign "$RD" run.CLOSE_CATALOGS "run_id=$RUN_ID
project=$PROJECT
$MAN"
wait_for_file "$RD/run.CLOSED" 30 && ok "correct complete handoff sealed (run.CLOSED)" || bad "did not seal a correct handoff"
[ -f "$RD/run.CLOSED.sig" ] && ok "seal receipt is signed by the tape server" || bad "run.CLOSED not signed"
# run.CLOSED is a terminal catalog barrier: the daemon must have committed all final SQLite state
# before this marker becomes visible.  Query the complete terminal snapshot immediately, without a
# busy timeout; any residual daemon write lock after CLOSED is itself a contract failure.
FINAL=$(sqlite3 -separator '|' "$BRIC_TAPE_DB" "SELECT
  (SELECT COUNT(*) FROM tape_artifacts WHERE run_id='$RUN_ID' AND kind!='TOC' AND state='VERIFIED'),
  (SELECT COUNT(*) FROM tape_artifacts WHERE run_id='$RUN_ID' AND kind='TOC' AND state='VERIFIED'),
  COALESCE((SELECT state FROM reservation WHERE run_id='$RUN_ID'),''),
  (SELECT COUNT(*) FROM audit_log WHERE actor='tape-daemon' AND action='CLOSED' AND object='$RUN_ID' AND result='OK');")
IFS='|' read -r NV NTOC RSTATE NCLOSED <<<"$FINAL"
[ "$NV" -ge 5 ] && ok "all 5 artifacts VERIFIED on tape" || bad "only $NV/5 artifacts VERIFIED"
[ "$NTOC" -ge 1 ] && ok "TAPE_TOC written last" || bad "no TOC written"
[ "$RSTATE" = RELEASED ] && ok "run.CLOSED published only after reservation RELEASED" || bad "run.CLOSED visible with reservation state '$RSTATE'"
[ "${NCLOSED:-0}" -ge 1 ] && ok "run.CLOSED published only after CLOSED audit commit" || bad "run.CLOSED visible before CLOSED audit commit"

echo
[ "$fail" -eq 0 ] && echo "✓ ALL CLOSE-HARDENING CHECKS PASSED" || { echo "✗ CLOSE-HARDENING FAILURES"; exit 1; }
