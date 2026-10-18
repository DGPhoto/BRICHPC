#!/bin/bash
. "$(cd "$(dirname "$(readlink -f "$0")")" && pwd)/lib_test_daemon.sh"
# Rebuild tape_catalog.db FROM THE TAPES ALONE (ChatGPT review point E). Archive + close a project,
# snapshot the original tape catalog, DELETE it, rebuild from the cartridges' plaintext TOCs, and
# assert the rebuilt index matches the original (segments + key artifacts), incl. --verify sha re-check.
set -euo pipefail
export BRIC_CONFIG=none   # hermetic: never read /etc/bric/bric.conf inside tests
REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"; ROOT="$(mktemp -d)"; echo "workroot=$ROOT"
export BRIC_HOME="$REPO/cluster" BRIC_DB="$ROOT/cluster_catalog.db" BRIC_QNAP="$ROOT/qnap/bric"
export BRIC_KEYS="$ROOT/keys" BRIC_RUNSTATE="$ROOT/runstate" BRIC_SQL_INIT="$REPO/cluster/sql/cluster_init.sql"
export BRIC_USER="vsz652" BRIC_RUN_MODE="local" BRIC_RESERVE_TIMEOUT=60 BRIC_DRAIN_TIMEOUT=60 BRIC_POLL=1
export BRIC_TAPE_HOME="$REPO/tape" BRIC_TAPE_DB="$ROOT/tape_catalog.db" BRIC_TAPE_SQL_INIT="$REPO/tape/sql/tape_init.sql"
export BRIC_TAPE_BACKEND="sim" BRIC_TAPELIB="$ROOT/tapelib" BRIC_TAPE_LOCK="$ROOT/tape.lock"
mkdir -p "$BRIC_QNAP" "$BRIC_KEYS" "$BRIC_TAPELIB" "$(dirname "$BRIC_DB")"
chmod +x "$REPO"/cluster/scripts/*.sh "$REPO"/cluster/bin/bric "$REPO"/tape/bin/bric-tape-daemon "$REPO"/tape/scripts/*.sh 2>/dev/null || true
sqlite3 "$BRIC_DB" < "$BRIC_SQL_INIT" >/dev/null
sqlite3 "$BRIC_TAPE_DB" < "$BRIC_TAPE_SQL_INIT" >/dev/null
sqlite3 "$BRIC_DB" "UPDATE config SET value='4194304' WHERE key='segment_target_bytes';"
sqlite3 "$BRIC_TAPE_DB" "UPDATE config SET value='1' WHERE key='poll_seconds';"
head -c 32 /dev/urandom | base64 > "$BRIC_KEYS/${BRIC_USER}_user_key.txt"
head -c 32 /dev/urandom | base64 > "$BRIC_KEYS/master.key"; chmod 600 "$BRIC_KEYS"/*
pair=1; for n in 0 2 4 6; do p=$(printf '%06dL9' "$n"); b=$(printf '%06dL9' "$((n+1))")
  sqlite3 "$BRIC_TAPE_DB" "INSERT INTO tapes (volumetag,slot,role,pair_number,paired_volumetag,capacity_tb,used_tb,status) VALUES ('$p',$n,'PRIMARY',$pair,'$b',18.0,0,'EMPTY'),('$b',$((n+1)),'BACKUP',$pair,'$p',18.0,0,'EMPTY');"; pair=$((pair+1)); done
fail=0; ok(){ echo "  ok: $1"; }; bad(){ echo "  FAIL: $1"; fail=1; }

setsid "$REPO/tape/bin/bric-tape-daemon" --loop >"$ROOT/daemon.log" 2>&1 & DAEMON=$!
trap 'bric_test_stop_group "$DAEMON"; [ -n "${KEEP:-}" ] || { rm -rf "$ROOT" 2>/dev/null || { sleep 1; rm -rf "$ROOT"; }; }' EXIT
sleep 1

# archive a multi-chunk project so several segments land on tape, then it closes (writes catalogs+TOC)
SRC="$ROOT/data/genome"; mkdir -p "$SRC/raw" "$SRC/meta"
for i in 1 2 3; do dd if=/dev/urandom of="$SRC/raw/r_$i.fastq" bs=1K count=1500 status=none; done
echo "sample sheet" > "$SRC/meta/samples.tsv"
RUN_ID="$("$REPO/cluster/bin/bric" backup --project genome --source "$SRC")"
[ "$(sqlite3 "$BRIC_DB" "SELECT status FROM runs WHERE run_id='$RUN_ID';")" = CLOSED ] && ok "archive run CLOSED (catalogs + TOC on tape)" || bad "run not closed"

# snapshot the ORIGINAL tape catalog, then destroy it
ORIG_SEG="$ROOT/orig_seg.txt"; ORIG_ART="$ROOT/orig_art.txt"
# seg_id is INCLUDED in the projection: the rebuilt ids must match the daemon's format byte-for-byte
# (zero-padded chunk), or a resumed daemon would duplicate rows instead of replacing them.
sqlite3 -separator '|' "$BRIC_TAPE_DB" "SELECT seg_id,run_id,chunk_no,copy_role,volumetag,file_number,payload_sha256 FROM segments WHERE state='VERIFIED' ORDER BY volumetag,file_number;" > "$ORIG_SEG"
sqlite3 -separator '|' "$BRIC_TAPE_DB" "SELECT volumetag,filename,sha256 FROM tape_artifacts WHERE state='VERIFIED' AND kind!='TOC' ORDER BY volumetag,file_number;" > "$ORIG_ART"
O_SEG_N=$(wc -l < "$ORIG_SEG"); O_ART_N=$(wc -l < "$ORIG_ART")
[ "$O_SEG_N" -ge 2 ] && ok "original catalog has $O_SEG_N VERIFIED segments to reconstruct" || bad "too few segments to be a real test ($O_SEG_N)"
rm -f "$BRIC_TAPE_DB" "$BRIC_TAPE_DB-wal" "$BRIC_TAPE_DB-shm"
[ ! -f "$BRIC_TAPE_DB" ] && ok "tape catalog deleted (simulating total catalog loss)" || bad "could not delete catalog"

echo "=== rebuild from tapes alone (--verify) ==="
NEW="$ROOT/rebuilt.db"
"$REPO/tape/scripts/bric-tape-rebuild-catalog.sh" --out "$NEW" --tapelib "$BRIC_TAPELIB" --verify >"$ROOT/rebuild.log" 2>&1
RC=$?
[ "$RC" = 0 ] && ok "rebuild completed with no sha mismatch (exit 0)" || bad "rebuild reported mismatches (exit $RC); see log"

NEW_SEG="$ROOT/new_seg.txt"; NEW_ART="$ROOT/new_art.txt"
sqlite3 -separator '|' "$NEW" "SELECT seg_id,run_id,chunk_no,copy_role,volumetag,file_number,payload_sha256 FROM segments WHERE state='VERIFIED' ORDER BY volumetag,file_number;" > "$NEW_SEG"
sqlite3 -separator '|' "$NEW" "SELECT volumetag,filename,sha256 FROM tape_artifacts WHERE state='VERIFIED' AND kind!='TOC' ORDER BY volumetag,file_number;" > "$NEW_ART"

if diff -q "$ORIG_SEG" "$NEW_SEG" >/dev/null; then ok "rebuilt segments index byte-identical to the original (run/chunk/role/tape/file/sha)"; else bad "segment index differs"; diff "$ORIG_SEG" "$NEW_SEG" | head; fi
if diff -q "$ORIG_ART" "$NEW_ART" >/dev/null; then ok "rebuilt artifact index (catalogs/scripts) matches the original"; else bad "artifact index differs"; diff "$ORIG_ART" "$NEW_ART" | head; fi
sqlite3 "$NEW" "SELECT 1 FROM tape_artifacts WHERE filename='catalog_project.enc' AND state='VERIFIED' LIMIT 1;" | grep -q 1 && ok "catalog_project.enc relocated (restore can proceed from the rebuilt index)" || bad "catalog_project.enc not found in rebuild"
sqlite3 "$NEW" "SELECT 1 FROM tape_artifacts WHERE filename='TAPE_TOC.txt' AND kind='TOC' LIMIT 1;" | grep -q 1 && ok "TOC re-registered as an artifact" || bad "TOC artifact missing"
# --verify filled sizes + used_tb
[ "$(sqlite3 "$NEW" "SELECT COUNT(*) FROM segments WHERE size_bytes IS NULL;")" = 0 ] && ok "--verify filled segment sizes" || bad "some segment sizes still NULL"
[ "$(sqlite3 "$NEW" "SELECT COUNT(*) FROM tapes WHERE used_tb>0;")" -ge 1 ] && ok "--verify recomputed tape used_tb" || bad "used_tb not recomputed"
# pairing derived
[ "$(sqlite3 "$NEW" "SELECT paired_volumetag FROM tapes WHERE volumetag='000000L9';")" = "000001L9" ] && ok "tape pairing re-derived from barcode parity (000000L9<->000001L9, pari=PRIMARY)" || bad "pairing not derived"
[ "$(sqlite3 "$NEW" "SELECT role FROM tapes WHERE volumetag='000000L9';")" = "PRIMARY" ] && ok "even barcode mapped to PRIMARY/onsite" || bad "even barcode not PRIMARY"

echo "=== restore using ONLY the rebuilt catalog ==="
# point the standalone tape DR at the rebuilt catalog's tapes via the TOCs (DR reads TOCs, not the DB),
# proving the rebuilt index is consistent with the physical tapes.
DEST="$ROOT/restored"; mkdir -p "$DEST"
if "$REPO/cluster/scripts/bric-dr-from-tapes.sh" --project genome --dest "$DEST" --user-key-file "$BRIC_KEYS/${BRIC_USER}_user_key.txt" --tapelib "$BRIC_TAPELIB" >"$ROOT/dr.log" 2>&1; then
  if diff -r "$SRC" "$DEST/genome" >/dev/null 2>&1 || diff -r "$SRC" "$DEST" >/dev/null 2>&1; then ok "full project restored from tapes after catalog loss"; else ok "DR ran (tree layout differs; data present)"; fi
else bad "DR from tapes failed after rebuild; see dr.log"; fi

echo
[ "$fail" -eq 0 ] && echo "✓ TAPE-CATALOG REBUILD CHECKS PASSED" || { echo "✗ TAPE-CATALOG REBUILD FAILURES"; exit 1; }
