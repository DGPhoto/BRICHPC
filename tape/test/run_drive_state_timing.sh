#!/bin/bash
# Real-backend mock: two drives have deliberately different ready/eject times.  Pair preparation and
# final release must wait for each drive independently and finish with both cartridges back in slots.
set -euo pipefail
export BRIC_CONFIG=none
REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
LIB="$ROOT/lib"; BIN="$ROOT/bin"; mkdir -p "$LIB/slots" "$BIN"
fail(){ echo "FAIL: $*" >&2; exit 1; }
now(){ date +%s; }

cat > "$BIN/mtx" <<'M'
#!/bin/bash
set -e
ST="$BRIC_MOCK_LIB"; shift 2; cmd="$1"; shift
case "$cmd" in
 status)
   for d in 0 1; do
     if [ -s "$ST/drive$d.vt" ]; then
       echo "Data Transfer Element $d:Full (Storage Element $(cat "$ST/drive$d.slot") Loaded):VolumeTag = $(cat "$ST/drive$d.vt")"
     else echo "Data Transfer Element $d:Empty"; fi
   done
   for s in "$ST"/slots/*; do [ -s "$s" ] && echo "      Storage Element $(basename "$s"):Full :VolumeTag=$(cat "$s")" || true; done
   ;;
 load)
   slot="$1"; d="$2"; [ -s "$ST/slots/$slot" ] || exit 1; [ ! -s "$ST/drive$d.vt" ] || exit 1
   cat "$ST/slots/$slot" > "$ST/drive$d.vt"; echo "$slot" > "$ST/drive$d.slot"; : > "$ST/slots/$slot"
   delay=1; [ "$d" = 1 ] && delay=3
   echo $(( $(date +%s) + delay )) > "$ST/drive$d.ready_at"
   printf 'load|%s|%s|%s\n' "$d" "$(cat "$ST/drive$d.vt")" "$(date +%s)" >> "$ST/trace"
   ;;
 unload)
   slot="$1"; d="$2"; [ -s "$ST/drive$d.vt" ] || exit 1
   until_at="$(cat "$ST/drive$d.eject_at" 2>/dev/null || echo 0)"
   [ "$(date +%s)" -ge "$until_at" ] || exit 1
   vt="$(cat "$ST/drive$d.vt")"; echo "$vt" > "$ST/slots/$slot"
   rm -f "$ST/drive$d.vt" "$ST/drive$d.slot" "$ST/drive$d.ready_at" "$ST/drive$d.eject_at"
   printf 'unload|%s|%s|%s\n' "$d" "$vt" "$(date +%s)" >> "$ST/trace"
   ;;
 *) exit 1;;
esac
M

cat > "$BIN/mt" <<'M'
#!/bin/bash
ST="$BRIC_MOCK_LIB"; dev="$2"; op="$3"; d="${dev##*nst}"
case "$op" in
 status)
   [ -s "$ST/drive$d.vt" ] || exit 1
   ready="$(cat "$ST/drive$d.ready_at" 2>/dev/null || echo 0)"
   [ "$(date +%s)" -ge "$ready" ] || exit 1
   echo "file number=0, block number=0" ;;
 offline)
   # Deliberately opposite eject delays: drive 0 slow, drive 1 fast.
   delay=3; [ "$d" = 1 ] && delay=1
   echo $(( $(date +%s) + delay )) > "$ST/drive$d.eject_at"
   printf 'offline|%s|%s\n' "$d" "$(date +%s)" >> "$ST/trace" ;;
 *) : ;;
esac
M
chmod +x "$BIN/mtx" "$BIN/mt"

# Wrong media starts loaded and ready; desired pair waits in slots 3/4.
echo OLD000L9 > "$LIB/drive0.vt"; echo 1 > "$LIB/drive0.slot"; echo 0 > "$LIB/drive0.ready_at"
echo OLD001L9 > "$LIB/drive1.vt"; echo 2 > "$LIB/drive1.slot"; echo 0 > "$LIB/drive1.ready_at"
: > "$LIB/slots/1"; : > "$LIB/slots/2"
echo 000000L9 > "$LIB/slots/3"; echo 000001L9 > "$LIB/slots/4"
touch "$LIB/nst0" "$LIB/nst1" "$LIB/sch0"

export PATH="$BIN:$PATH" BRIC_MOCK_LIB="$LIB"
export BRIC_TAPE_BACKEND=real BRIC_CHANGER="$LIB/sch0" BRIC_DRIVE0="$LIB/nst0" BRIC_DRIVE1="$LIB/nst1"
export BRIC_TAPE_DRIVES="0 1" BRIC_CHANGER_LOCK="$LIB/changer.lock" BRIC_DRIVE_LOCK_PREFIX="$LIB/drive.lock."
# Common timeout is deliberately too short for the slow sides; per-drive overrides prove that
# readiness/eject timing is tracked independently rather than by one shared stopwatch.
export BRIC_DRIVE_READY_TIMEOUT=2 BRIC_DRIVE_UNLOAD_TIMEOUT=2
export BRIC_DRIVE_READY_TIMEOUT_0=4 BRIC_DRIVE_READY_TIMEOUT_1=8
export BRIC_DRIVE_UNLOAD_TIMEOUT_0=8 BRIC_DRIVE_UNLOAD_TIMEOUT_1=4
export BRIC_DRIVE_COMMAND_TIMEOUT=3 BRIC_DRIVE_STATUS_TIMEOUT=2 BRIC_DRIVE_POLL_SECONDS=1
. "$REPO/tape/scripts/lib_tape_io.sh"
export BRIC_TAPE_IO_TIMEOUT=10 BRIC_TAPE_IO_TIMEOUT_1=25
[ "$(_drive_io_timeout 0 "$BRIC_TAPE_IO_TIMEOUT")" = 10 ] || fail "drive 0 did not inherit common I/O timeout"
[ "$(_drive_io_timeout 1 "$BRIC_TAPE_IO_TIMEOUT")" = 25 ] || fail "drive 1 I/O timeout override ignored"
echo "  ok: tape streaming timeout is independently overridable per drive"

start="$(now)"
tape_prepare_pair 000000L9 000001L9 0 1
elapsed=$(( $(now) - start ))
[ "$elapsed" -ge 3 ] || fail "pair preparation returned before slower drive became ready (${elapsed}s)"
[ "$(cat "$LIB/drive0.vt")" = 000000L9 ] || fail "PRIMARY not in drive 0"
[ "$(cat "$LIB/drive1.vt")" = 000001L9 ] || fail "BACKUP not in drive 1"

echo "  ok: pair preparation waited for asymmetric readiness (${elapsed}s)"
start="$(now)"
tape_release_all
elapsed=$(( $(now) - start ))
[ "$elapsed" -ge 3 ] || fail "release returned before slower eject completed (${elapsed}s)"
[ ! -s "$LIB/drive0.vt" ] && [ ! -s "$LIB/drive1.vt" ] || fail "one or both drives still loaded"
grep -q '^unload|0|000000L9|' "$LIB/trace" || fail "drive 0 unload not confirmed"
grep -q '^unload|1|000001L9|' "$LIB/trace" || fail "drive 1 unload not confirmed"
echo "  ok: final barrier waited for asymmetric eject and both drives are empty (${elapsed}s)"
echo "PASS run_drive_state_timing"
