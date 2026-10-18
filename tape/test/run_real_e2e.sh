#!/bin/bash
. "$(cd "$(dirname "$(readlink -f "$0")")" && pwd)/lib_test_daemon.sh"
# Full archive + disaster recovery driven through the REAL lib_tape_io path (mtx/mt/dd), with the
# changer/drive mocked so it runs without hardware. Proves the daemon's write+verify, the idempotent
# close (catalogs + TOC), and the DR tool all work through the real command sequence.
set -euo pipefail
export BRIC_CONFIG=none   # hermetic: never read /etc/bric/bric.conf inside tests
REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
ROOT="$(mktemp -d)"; echo "workroot=$ROOT"
LIB="$ROOT/lib"; BIN="$ROOT/bin"; mkdir -p "$LIB/slots" "$LIB/tapes" "$BIN"

# ---- changer/drive/dd mocks (single drive element 0) ----
cat > "$BIN/mtx" <<'M'
#!/bin/bash
ST="$BRIC_MOCK_LIB"; shift 2; case "$1" in
  status) if [ -s "$ST/drive0.vt" ]; then echo "Data Transfer Element 0:Full (Storage Element $(cat "$ST/drive0.slot") Loaded):VolumeTag = $(cat "$ST/drive0.vt")"; else echo "Data Transfer Element 0:Empty"; fi
    for s in "$ST"/slots/*; do [ -s "$s" ] || continue; echo "      Storage Element $(basename "$s"):Full :VolumeTag=$(cat "$s")"; done ;;
  load)   cat "$ST/slots/$2" > "$ST/drive0.vt"; echo "$2" > "$ST/drive0.slot"; rm -f "$ST/slots/$2" ;;
  unload) cat "$ST/drive0.vt" > "$ST/slots/$2"; rm -f "$ST/drive0.vt" "$ST/drive0.slot" ;;
esac
M
cat > "$BIN/mt" <<'M'
#!/bin/bash
dev="$2"; op="$3"; arg="${4:-}"; st="$dev.pos"; vt="$(cat "$BRIC_MOCK_LIB/drive0.vt" 2>/dev/null || true)"
eod(){ cat "$BRIC_MOCK_LIB/tapes/$vt/.eod" 2>/dev/null || echo 0; }; p(){ cat "$st" 2>/dev/null || echo 0; }
case "$op" in
  setblk) : ;;
  weof) n=$(( $(eod)+1 )); mkdir -p "$BRIC_MOCK_LIB/tapes/$vt"; echo "$n" > "$BRIC_MOCK_LIB/tapes/$vt/.eod"; echo "$n" > "$st" ;;
  rewind) echo 0 > "$st" ;;
  eod) eod > "$st" ;;
  fsf) echo $(( $(p)+arg )) > "$st" ;;
  bsfm)
    # Real LTO-9 semantics validated on both production drives: from EOD after file N,
    # bsfm 2 leaves the next read at file N and mt status reports file number N-1.
    # Force the first call to fail so this independent E2E proves the absolute fallback
    # at catalog file #1 (rewind only, no fsf) before later reads exercise the fast path.
    if [ -n "${BRIC_MOCK_BSFM_FAIL_ONCE:-}" ] && [ -e "$BRIC_MOCK_BSFM_FAIL_ONCE" ]; then
      rm -f "$BRIC_MOCK_BSFM_FAIL_ONCE"
      exit 1
    fi
    n=$(( $(p)-1 )); [ "$n" -ge 0 ] || n=0; echo "$n" > "$st" ;;
  status) echo "file number=$(p), block number=0." ;;
esac
M
cat > "$BIN/dd" <<'M'
#!/bin/bash
IN="";OUT="";for a in "$@";do case "$a" in if=*) IN="${a#if=}";; of=*) OUT="${a#of=}";; esac;done
DEV="$BRIC_DRIVE0"; vt="$(cat "$BRIC_MOCK_LIB/drive0.vt" 2>/dev/null || true)"; d="$BRIC_MOCK_LIB/tapes/$vt"; pos="$(cat "$DEV.pos" 2>/dev/null || echo 0)"
if [ "$OUT" = "$DEV" ]; then mkdir -p "$d"; eod="$(cat "$d/.eod" 2>/dev/null || echo 0)"; n=$((eod+1)); cp -f "$IN" "$d/$(printf 'f_%06d' "$n")"; echo "$n">"$d/.eod"; echo "$n">"$DEV.pos"
elif [ "$IN" = "$DEV" ]; then src="$d/$(printf 'f_%06d' "$((pos+1))")"; if [ -n "$OUT" ]; then cp -f "$src" "$OUT"; else cat "$src"; fi
else exec /usr/bin/dd "$@"; fi
M
chmod +x "$BIN"/* 2>/dev/null || true

export PATH="$BIN:$PATH" BRIC_MOCK_LIB="$LIB"
touch "$ROOT/bsfm-fail-once"; export BRIC_MOCK_BSFM_FAIL_ONCE="$ROOT/bsfm-fail-once"
export BRIC_HOME="$REPO/cluster" BRIC_DB="$ROOT/c.db" BRIC_QNAP="$ROOT/qnap/bric" BRIC_KEYS="$ROOT/keys" BRIC_SQL_INIT="$REPO/cluster/sql/cluster_init.sql"
# The REAL-backend mock intentionally serializes PRIMARY and BACKUP through one drive and performs
# write + immediate readback + eject/load for every chunk. Seven chunks normally consume around
# 120 seconds of drain time on an unloaded host, so a 120s timeout is a race against normal success
# and became flaky under full-suite load. Keep the fixture bounded, but give it deterministic headroom.
export BRIC_USER=vsz652 BRIC_RUN_MODE=local BRIC_RESERVE_TIMEOUT=60 BRIC_DRAIN_TIMEOUT=300 BRIC_CLOSE_TIMEOUT=120 BRIC_POLL=1
export BRIC_TAPE_HOME="$REPO/tape" BRIC_TAPE_DB="$ROOT/t.db" BRIC_TAPE_SQL_INIT="$REPO/tape/sql/tape_init.sql"
export BRIC_TAPE_BACKEND=real BRIC_CHANGER="$LIB/sch0" BRIC_DRIVE0="$LIB/nst0" BRIC_TAPE_DRIVES="0" BRIC_CHANGER_LOCK="$LIB/changer.lock" BRIC_TAPE_LOCK="$LIB/tape.lock"
# The per-operation hardware gate (tape_hw_quickcheck) legitimately requires the device nodes to
# exist and mtx status to answer: create the mock nodes so the gate is EXERCISED, not bypassed.
touch "$LIB/sch0" "$LIB/nst0"

mkdir -p "$BRIC_QNAP" "$BRIC_KEYS"; chmod +x "$REPO"/cluster/scripts/*.sh "$REPO"/cluster/bin/bric "$REPO"/tape/bin/bric-tape-daemon
sqlite3 "$BRIC_DB" < "$BRIC_SQL_INIT" >/dev/null; sqlite3 "$BRIC_TAPE_DB" < "$BRIC_TAPE_SQL_INIT" >/dev/null
sqlite3 "$BRIC_DB" "UPDATE config SET value='4194304' WHERE key='segment_target_bytes';"
sqlite3 "$BRIC_TAPE_DB" "UPDATE config SET value='1' WHERE key='poll_seconds';"
head -c 32 /dev/urandom|base64>"$BRIC_KEYS/vsz652_user_key.txt"; head -c 32 /dev/urandom|base64>"$BRIC_KEYS/master.key"
cp "$BRIC_KEYS/vsz652_user_key.txt" "$ROOT/userkey.txt"
# register one pair; mirror the slots into the mock library
sqlite3 "$BRIC_TAPE_DB" "INSERT INTO tapes(volumetag,slot,role,pair_number,paired_volumetag,capacity_tb,used_tb,status) VALUES('000001L9',1,'PRIMARY',1,'000002L9',18,0,'EMPTY'),('000002L9',2,'BACKUP',1,'000001L9',18,0,'EMPTY');"
echo 000001L9 > "$LIB/slots/1"; echo 000002L9 > "$LIB/slots/2"

SRC="$ROOT/data/proj"; mkdir -p "$SRC/raw"; for i in 1 2 3; do dd if=/dev/urandom of="$SRC/raw/s_$i.dat" bs=1M count=1 status=none; done
dd if=/dev/urandom of="$SRC/raw/huge.bam" bs=1M count=9 status=none   # > 4 MiB -> split

trap 'bric_test_stop_group "$DAEMON"; [ -n "${KEEP:-}" ] || { rm -rf "$ROOT" 2>/dev/null || { sleep 1; rm -rf "$ROOT"; }; }' EXIT
setsid "$REPO/tape/bin/bric-tape-daemon" --loop & DAEMON=$!; sleep 1
echo "=== archive through the REAL backend (mtx/mt/dd) ==="
RUN="$("$REPO/cluster/bin/bric" backup --project proj --source "$SRC" 2>/dev/null)"
[ ! -e "$ROOT/bsfm-fail-once" ] || { echo "FAIL: forced first bsfm failure was not exercised" >&2; exit 1; }
bric_test_stop_group "$DAEMON"

fail=0; chk(){ [ "$2" = "$3" ] && echo "  ok: $1 ($2)" || { echo "  FAIL: $1 exp=$3 got=$2"; fail=1; }; }
NCH=$(sqlite3 "$BRIC_DB" "SELECT n_chunks FROM runs WHERE run_id='$RUN';")
chk "run CLOSED" "$(sqlite3 "$BRIC_DB" "SELECT status FROM runs WHERE run_id='$RUN';")" "CLOSED"
chk "segments VERIFIED (2x chunks)" "$(sqlite3 "$BRIC_TAPE_DB" "SELECT COUNT(*) FROM segments WHERE run_id='$RUN' AND state='VERIFIED';")" "$((NCH*2))"
chk "close artifacts VERIFIED on PRIMARY (4 files + TOC; no escrow in this fixture)" "$(sqlite3 "$BRIC_TAPE_DB" "SELECT COUNT(*) FROM tape_artifacts WHERE volumetag='000001L9' AND state='VERIFIED';")" "5"

echo "=== disaster recovery through the REAL backend (no catalogs, no QNAP) ==="
rm -f "$BRIC_DB"* "$BRIC_TAPE_DB"*; rm -rf "$BRIC_QNAP" "$BRIC_KEYS"
DR="$ROOT/recovered"
"$REPO/cluster/scripts/bric-dr-from-tapes.sh" --project proj --user-key-file "$ROOT/userkey.txt" --dest "$DR"
diff -r "$SRC" "$DR" >/dev/null 2>&1 && echo "  ok: project reconstructed from tapes (real backend) matches source" || { echo "  FAIL: DR mismatch"; fail=1; }

echo
[ "$fail" -eq 0 ] && echo "✓ REAL-BACKEND E2E PASSED (archive + close + DR via mtx/mt/dd path)" || { echo "✗ FAILURES"; exit 1; }
