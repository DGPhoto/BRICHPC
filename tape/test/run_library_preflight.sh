#!/bin/bash
# Library-device preflight test. Exercises bric-library-preflight against MOCKED mtx/mt/sg_* tools,
# covering the real failure modes seen on MSL3040-class hardware WITHOUT needing the hardware:
#   A) healthy library (2 drives same firmware, clean sense, complete pairs)      -> exit 0
#   B) changer stuck in "manual intervention required" (sense 0x02/04/03)         -> exit 2, explicit
#   C) drives on DIFFERENT firmware revisions (post part-swap classic)            -> exit 0 + WARN
#   D) an unrelated PRIMARY-parity tape with partner absent                       -> exit 0 + info
#   E) sg_turs "bad pass-through setup" tool artifact                             -> WARN, not FAIL
#   F) sim backend                                                                -> clean no-op exit 0
# On a machine with REAL devices (BRIC_TAPE_BACKEND=real preset in the environment), scenario G
# additionally runs the preflight against the actual hardware, read-only.
set -uo pipefail
export BRIC_CONFIG=none   # hermetic: never read /etc/bric/bric.conf inside tests
REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
ROOT="$(mktemp -d)"
echo "workroot=$ROOT"
fail=0; ok() { echo "  ok: $*"; }; bad() { echo "  FAIL: $*"; fail=1; }
trap '[ -n "${KEEP:-}" ] || rm -rf "$ROOT"' EXIT
chmod +x "$REPO/tape/bin/bric-library-preflight" 2>/dev/null || true

MOCK="$ROOT/mockbin"; mkdir -p "$MOCK" "$ROOT/dev"
export PATH="$MOCK:$PATH"
CH="$ROOT/dev/sg_changer"; D0="$ROOT/dev/nst0"; D1="$ROOT/dev/nst1"
touch "$CH" "$D0" "$D1"

# ---- scenario knobs consumed by the mocks ----
export MOCK_DIR="$ROOT/mockstate"; mkdir -p "$MOCK_DIR"

cat > "$MOCK/sg_inq" <<'M'
#!/bin/bash
dev="$1"
case "$dev" in
  *sg_changer) echo "Vendor identification: HPE     "; echo "Product identification: MSL G3 Series   "; echo "Product revision level: 9.30";;
  *nst0)       echo "Vendor identification: HPE     "; echo "Product identification: Ultrium 9-SCSI  "; echo "Product revision level: $(cat "$MOCK_DIR/fw0")";;
  *nst1)       echo "Vendor identification: HPE     "; echo "Product identification: Ultrium 9-SCSI  "; echo "Product revision level: $(cat "$MOCK_DIR/fw1")";;
esac
M
cat > "$MOCK/sg_turs" <<'M'
#!/bin/bash
if [ -f "$MOCK_DIR/turs_artifact" ]; then echo "bad pass-through setup" >&2; exit 1; fi
exit 0
M
cat > "$MOCK/sg_requests" <<'M'
#!/bin/bash
# last arg is the device
for d; do dev="$d"; done
if [[ "$dev" == *sg_changer ]] && [ -f "$MOCK_DIR/sense_manual" ]; then
  echo "Fixed format, current; Sense key: Not Ready"
  echo " Additional sense: Logical unit not ready, manual intervention required"
  echo "  asc=0x4 ascq=0x3"
else
  echo "Fixed format, current; Sense key: No Sense"
fi
M
cat > "$MOCK/mtx" <<'M'
#!/bin/bash
# mtx -f DEV status
cat "$MOCK_DIR/mtx_status"
M
cat > "$MOCK/mt" <<'M'
#!/bin/bash
dev=""; while [ "$#" -gt 0 ]; do [ "$1" = -f ] && { dev="$2"; shift 2; continue; }; shift; done
case "$dev" in *nst0) d=0;; *nst1) d=1;; *) d=9;; esac
# Optional fault: swap the Linux-node view to prove the preflight catches an element/device mismatch.
[ -f "$MOCK_DIR/swap_mapping" ] && { [ "$d" = 0 ] && d=1 || d=0; }
line="$(grep "^Data Transfer Element $d:" "$MOCK_DIR/mtx_status" | head -1)"
echo "SCSI 2 tape drive:"
if echo "$line" | grep -q ':Full'; then
  echo "General status bits on (41010000): BOT ONLINE IM_REP_EN"
else
  echo "General status bits on (00010000): DR_OPEN IM_REP_EN"
fi
M
chmod +x "$MOCK"/* 2>/dev/null || true

mk_status() {  # $1 = extra/replacement storage lines
cat > "$MOCK_DIR/mtx_status" <<EOF
  Storage Changer $CH:2 Drives, 40 Slots ( 5 Import/Export )
Data Transfer Element 0:Empty
Data Transfer Element 1:Empty
$1
EOF
}
HEALTHY_SLOTS='      Storage Element 1:Full :VolumeTag=000000L9
      Storage Element 2:Full :VolumeTag=000001L9
      Storage Element 3:Full :VolumeTag=000002L9
      Storage Element 4:Full :VolumeTag=000003L9
      Storage Element 5:Empty'

run_pf() {  # -> captures rc + output
    BRIC_TAPE_BACKEND=real BRIC_CHANGER="$CH" BRIC_DRIVE0="$D0" BRIC_DRIVE1="$D1" \
    BRIC_TAPE_DRIVES="0 1" BRIC_PARALLEL_DRIVES=2 BRIC_TAPE_DB="" \
        "$REPO/tape/bin/bric-library-preflight" > "$ROOT/pf.out" 2>&1
    PF_RC=$?
}

echo "=== A) healthy library ==="
echo S2SD > "$MOCK_DIR/fw0"; echo S2SD > "$MOCK_DIR/fw1"
rm -f "$MOCK_DIR/sense_manual" "$MOCK_DIR/turs_artifact"
mk_status "$HEALTHY_SLOTS"
run_pf
[ "$PF_RC" = 0 ] && ok "exit 0 on a healthy library" || { bad "healthy library rc=$PF_RC"; sed -n '1,40p' "$ROOT/pf.out"; }
grep -q "all drives on the same firmware revision" "$ROOT/pf.out" && ok "firmware coherence reported" || bad "no firmware coherence line"
grep -q "2 complete physical barcode pair(s) currently onsite" "$ROOT/pf.out" && ok "complete-pair inventory summary reported" || bad "pair summary missing"
grep -q "changer sense clean" "$ROOT/pf.out" && ok "sense clean reported" || bad "sense not checked"
grep -q "drive 0 ($D0): unit ready" "$ROOT/pf.out" && grep -q "drive 1 ($D1): unit ready" "$ROOT/pf.out" \
    && ok "sg_turs checked both labelled drive devices without word-splitting" \
    || { bad "per-drive sg_turs labels/devices wrong"; grep -A4 "test unit ready" "$ROOT/pf.out"; }
! grep -q "error opening file: drive" "$ROOT/pf.out" && ok "no phantom sg_turs target named 'drive'" || bad "phantom sg_turs target detected"

echo "=== B) changer blocked: manual intervention required (0x02/04/03) ==="
touch "$MOCK_DIR/sense_manual"
run_pf
[ "$PF_RC" = 2 ] && ok "exit 2 with robotics blocked" || bad "expected rc=2, got $PF_RC"
grep -q "manual intervention required" "$ROOT/pf.out" && grep -q "do NOT start the daemon" "$ROOT/pf.out" \
    && ok "explicit diagnosis + operator instruction" || bad "diagnosis not explicit"
rm -f "$MOCK_DIR/sense_manual"

echo "=== C) mixed drive firmware (S2S1 vs S2SD) ==="
echo S2SD > "$MOCK_DIR/fw0"; echo S2S1 > "$MOCK_DIR/fw1"
run_pf
[ "$PF_RC" = 0 ] && ok "mixed firmware is a WARNING, not a failure (one good drive can still work)" || bad "rc=$PF_RC on mixed firmware"
grep -q "DIFFERENT firmware revisions" "$ROOT/pf.out" && ok "firmware mismatch surfaced (drive0=S2SD drive1=S2S1)" || bad "mismatch not surfaced"
echo S2SD > "$MOCK_DIR/fw1"

echo "=== D) unrelated incomplete physical pair does NOT block generic preflight ==="
mk_status '      Storage Element 1:Full :VolumeTag=000000L9
      Storage Element 2:Full :VolumeTag=000001L9
      Storage Element 3:Full :VolumeTag=000002L9
      Storage Element 4:Empty'
run_pf
[ "$PF_RC" = 0 ] && ok "generic preflight ignores unrelated incomplete/offsite pairs" || bad "expected rc=0, got $PF_RC"
grep -q "000002L9->000003L9" "$ROOT/pf.out" && grep -q "ignored by generic preflight" "$ROOT/pf.out"     && ok "unpaired barcode is reported as informational only" || bad "project-scoped pairing explanation absent"
grep -q "reservation validates only complete onsite pairs needed for the current project" "$ROOT/pf.out"     && ok "project-scoped reservation rule is explicit" || bad "reservation scope explanation missing"
mk_status "$HEALTHY_SLOTS"

echo "=== D3) swapped changer-element/Linux-device mapping is rejected ==="
cat > "$MOCK_DIR/mtx_status" <<EOF
  Storage Changer $CH:2 Drives, 40 Slots ( 5 Import/Export )
Data Transfer Element 0:Full (Storage Element 7 Loaded):VolumeTag=000000L9
Data Transfer Element 1:Empty
      Storage Element 1:Full :VolumeTag=000001L9
      Storage Element 7:Empty
EOF
touch "$MOCK_DIR/swap_mapping"
run_pf
[ "$PF_RC" = 2 ] && ok "drive mapping mismatch exits 2" || bad "expected mapping rc=2, got $PF_RC"
grep -q "drive mapping mismatch" "$ROOT/pf.out" && ok "mapping diagnosis explicit" || bad "mapping mismatch not diagnosed"
rm -f "$MOCK_DIR/swap_mapping"
mk_status "$HEALTHY_SLOTS"

echo "=== E) sg_turs 'bad pass-through setup' artifact tolerated ==="
touch "$MOCK_DIR/turs_artifact"
run_pf
[ "$PF_RC" = 0 ] && ok "known sg3_utils artifact does not fail the preflight" || bad "artifact treated as failure (rc=$PF_RC)"
grep -q "known sg3_utils/driver artifact" "$ROOT/pf.out" && ok "artifact explained in the report" || bad "artifact not explained"
rm -f "$MOCK_DIR/turs_artifact"

echo "=== F) sim backend: clean no-op ==="
out="$(BRIC_TAPE_BACKEND=sim "$REPO/tape/bin/bric-library-preflight" 2>&1)"; rc=$?
[ "$rc" = 0 ] && echo "$out" | grep -q "REAL hardware only" && ok "sim backend exits 0 with a clear message" || bad "sim backend behaved unexpectedly (rc=$rc)"

# ---------------------------------------------------------------------------------------------
# H/I) per-operation hardware gate: a backup (reservation) and a restore invoked against a
# BLOCKED library must be refused BEFORE the operation begins, with the diagnosis propagated to
# the requester, and the daemon must survive. With healthy hardware the gate must pass through.
# ---------------------------------------------------------------------------------------------
echo "=== H) blocked changer: backup DENIED and restore refused at operation start ==="
export BRIC_HOME="$REPO/cluster" BRIC_QNAP="$ROOT/qnap/bric" BRIC_KEYS="$ROOT/keys"
export BRIC_TAPE_HOME="$REPO/tape" BRIC_TAPE_DB="$ROOT/t.db" BRIC_TAPE_SQL_INIT="$REPO/tape/sql/tape_init.sql"
export BRIC_TAPE_LOCK="$ROOT/tape.lock"
mkdir -p "$BRIC_QNAP/archive/hwproj/hwproj__20260718T000000Z__0001" "$BRIC_QNAP/restore/hwproj/hwproj__restore__req1" "$BRIC_KEYS"
sqlite3 "$BRIC_TAPE_DB" < "$BRIC_TAPE_SQL_INIT" >/dev/null
cat > "$BRIC_QNAP/archive/hwproj/hwproj__20260718T000000Z__0001/run.RESERVE_REQUEST" <<'MK'
run_id=hwproj__20260718T000000Z__0001
project=hwproj
owner=vsz652
requested_bytes=1000000
MK
cat > "$BRIC_QNAP/restore/hwproj/hwproj__restore__req1/request" <<'MK'
owner=vsz652
project=hwproj
run=hwproj__20260718T000000Z__0001
stage|hwproj__20260718T000000Z__0001|1
MK
touch "$MOCK_DIR/sense_manual"; mk_status "$HEALTHY_SLOTS"
BRIC_TAPE_BACKEND=real BRIC_CHANGER="$CH" BRIC_DRIVE0="$D0" BRIC_DRIVE1="$D1" BRIC_TAPE_DRIVES="0 1" \
    BRIC_TAPELIB="$ROOT/tapelib_unused" \
    "$REPO/tape/bin/bric-tape-daemon" --once > "$ROOT/dh.log" 2>&1
DRC=$?
[ "$DRC" = 0 ] && ok "daemon --once survived the blocked library (rc=0)" || { bad "daemon rc=$DRC on blocked library"; tail -4 "$ROOT/dh.log"; }
DEN="$BRIC_QNAP/archive/hwproj/hwproj__20260718T000000Z__0001/run.DENIED"
[ -f "$DEN" ] && grep -q "tape hardware not ready" "$DEN" && grep -qi "manual intervention" "$DEN" \
    && ok "backup DENIED before starting, with the hardware diagnosis in the marker" \
    || { bad "run.DENIED missing or without diagnosis"; ls "$(dirname "$DEN")"; }
STG="$BRIC_QNAP/restore/hwproj/hwproj__restore__req1/request.STAGED"
[ -f "$STG" ] && grep -q "refused: tape hardware not ready" "$STG" \
    && ok "restore refused before staging, with the hardware diagnosis in the marker" \
    || { bad "request.STAGED refusal missing"; ls "$(dirname "$STG")"; }

echo "=== I) healthy hardware: the gate passes through to normal logic ==="
rm -f "$MOCK_DIR/sense_manual" "$DEN" "$STG"
BRIC_TAPE_BACKEND=real BRIC_CHANGER="$CH" BRIC_DRIVE0="$D0" BRIC_DRIVE1="$D1" BRIC_TAPE_DRIVES="0 1" \
    BRIC_TAPELIB="$ROOT/tapelib_unused" \
    "$REPO/tape/bin/bric-tape-daemon" --once > "$ROOT/di.log" 2>&1 || bad "daemon --once failed on healthy mocks"
if [ -f "$DEN" ]; then
    grep -q "tape hardware not ready" "$DEN" && bad "gate wrongly triggered on healthy hardware" \
        || ok "gate passed; DENIED (if any) is for capacity, not hardware: $(grep '^reason=' "$DEN" | head -1)"
else
    ok "gate passed on healthy hardware (no hardware denial)"
fi
grep -q "hw quickcheck passed" "$ROOT/di.log" && ok "quickcheck logged as passed" || bad "quickcheck pass not logged"

echo "=== J) reservation is scoped to current project capacity, not global library completeness ==="
rm -rf "$BRIC_QNAP/archive"; mkdir -p "$BRIC_QNAP/archive/cap20/cap20__20260727T000000Z__0001"
rm -f "$BRIC_TAPE_DB"; sqlite3 "$BRIC_TAPE_DB" < "$BRIC_TAPE_SQL_INIT" >/dev/null
sqlite3 "$BRIC_TAPE_DB" "INSERT INTO tapes(volumetag,slot,role,pair_number,paired_volumetag,capacity_tb,used_tb,status,health) VALUES
('000000L9',1,'PRIMARY',1,'000001L9',18,0,'EMPTY','OK'),('000001L9',2,'BACKUP',1,'000000L9',18,0,'EMPTY','OK'),
('000002L9',3,'PRIMARY',2,'000003L9',18,0,'EMPTY','OK'),('000003L9',4,'BACKUP',2,'000002L9',18,0,'EMPTY','OK'),
('000004L9',5,'PRIMARY',3,'000005L9',18,0,'EMPTY','OK'),('000005L9',6,'BACKUP',3,'000004L9',18,0,'EMPTY','OK');"
cat > "$BRIC_QNAP/archive/cap20/cap20__20260727T000000Z__0001/run.RESERVE_REQUEST" <<'MK'
run_id=cap20__20260727T000000Z__0001
project=cap20
owner=vsz652
requested_bytes=20000000000000
MK
# Two complete onsite pairs plus one unrelated/incomplete pair. 20 TB requires exactly two LTO-9
# pairs at 17.7 TB usable per pair (18.0 - 0.3 headroom).
mk_status '      Storage Element 1:Full :VolumeTag=000000L9
      Storage Element 2:Full :VolumeTag=000001L9
      Storage Element 3:Full :VolumeTag=000002L9
      Storage Element 4:Full :VolumeTag=000003L9
      Storage Element 5:Full :VolumeTag=000004L9
      Storage Element 6:Full :VolumeTag=000080L9'
BRIC_TAPE_BACKEND=real BRIC_CHANGER="$CH" BRIC_DRIVE0="$D0" BRIC_DRIVE1="$D1" BRIC_TAPE_DRIVES="0 1"     BRIC_TAPELIB="$ROOT/tapelib_unused"     "$REPO/tape/bin/bric-tape-daemon" --once > "$ROOT/dj.log" 2>&1 || bad "daemon reservation pass failed"
RES="$BRIC_QNAP/archive/cap20/cap20__20260727T000000Z__0001/run.RESERVED"
[ -f "$RES" ] && grep -q '^pairs=2$' "$RES" && ok "20 TB reservation selected exactly two complete onsite pairs"     || { bad "20 TB reservation did not select exactly two pairs"; cat "$RES" 2>/dev/null || true; tail -20 "$ROOT/dj.log"; }
[ "$(sqlite3 "$BRIC_TAPE_DB" "SELECT COUNT(DISTINCT pair_number) FROM tapes WHERE project_name='cap20' AND status='RESERVED';")" = 2 ]     && ok "catalog reserved exactly two pairs for the project" || bad "catalog reserved the wrong pair count"
[ "$(sqlite3 "$BRIC_TAPE_DB" "SELECT COUNT(*) FROM tapes WHERE pair_number=3 AND status='EMPTY' AND project_name IS NULL;")" = 2 ]     && ok "unrelated incomplete/offsite pair was ignored and left untouched" || bad "unrelated pair was modified"

if [ "${BRIC_TAPE_BACKEND:-sim}" = real ] && [ -e "${BRIC_CHANGER:-/dev/null}" ] && [ "${BRIC_CHANGER:-}" != "$CH" ]; then
    echo "=== G) REAL hardware preflight (read-only) ==="
    ( PATH="${PATH#"$MOCK":}" "$REPO/tape/bin/bric-library-preflight" ) && ok "real-hardware preflight passed" || bad "real-hardware preflight reported failures (see above)"
fi

echo
[ "$fail" -eq 0 ] && echo "✓ LIBRARY PREFLIGHT CHECKS PASSED" || { echo "✗ LIBRARY PREFLIGHT FAILURES"; exit 1; }
