#!/bin/bash
# Real-backend mock that models Linux st semantics exactly where Review 30B failed on hardware:
# closing the non-rewinding tape device after dd write emits one flushing filemark.  An explicit
# subsequent `mt weof` would therefore create an empty tape file and numbering 1,3,5,... .
set -euo pipefail
export BRIC_CONFIG=none
REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
LIB="$ROOT/lib"; BIN="$ROOT/bin"; mkdir -p "$LIB/slots" "$LIB/tapes" "$BIN"

echo 000044L9 > "$LIB/slots/1"
echo 000045L9 > "$LIB/slots/2"

cat > "$BIN/mtx" <<'M'
#!/bin/bash
ST="$BRIC_MOCK_LIB"; shift 2; cmd="$1"
case "$cmd" in
 status)
   if [ -s "$ST/drive0.vt" ]; then echo "Data Transfer Element 0:Full (Storage Element $(cat "$ST/drive0.slot") Loaded):VolumeTag = $(cat "$ST/drive0.vt")"; else echo "Data Transfer Element 0:Empty"; fi
   for s in "$ST"/slots/*; do [ -s "$s" ] && echo "      Storage Element $(basename "$s"):Full :VolumeTag=$(cat "$s")" || true; done ;;
 load) cat "$ST/slots/$2" > "$ST/drive0.vt"; echo "$2" > "$ST/drive0.slot"; : > "$ST/slots/$2" ;;
 unload) cat "$ST/drive0.vt" > "$ST/slots/$2"; rm -f "$ST/drive0.vt" "$ST/drive0.slot" ;;
 *) exit 1;;
esac
M

cat > "$BIN/mt" <<'M'
#!/bin/bash
dev="$2"; op="$3"; arg="${4:-1}"; st="$dev.pos"
vt="$(cat "$BRIC_MOCK_LIB/drive0.vt" 2>/dev/null || true)"; d="$BRIC_MOCK_LIB/tapes/$vt"
eod(){ cat "$d/.eod" 2>/dev/null || echo 0; }; pos(){ cat "$st" 2>/dev/null || echo 0; }
case "$op" in
 setblk) : ;;
 rewind) echo 0 > "$st" ;;
 eod) eod > "$st" ;;
 fsf) echo $(( $(pos) + arg )) > "$st" ;;
 weof) n=$(( $(eod) + arg )); mkdir -p "$d"; echo "$n" > "$d/.eod"; echo "$n" > "$st"; echo "$arg" >> "$BRIC_MOCK_LIB/weof.calls" ;;
 status) echo "SCSI 2 tape drive:"; echo "File number=$(pos), block number=0, partition=0." ;;
 *) : ;;
esac
M

cat > "$BIN/dd" <<'M'
#!/bin/bash
IN=""; OUT=""; for a in "$@"; do case "$a" in if=*) IN="${a#if=}";; of=*) OUT="${a#of=}";; esac; done
DEV="$BRIC_DRIVE0"; vt="$(cat "$BRIC_MOCK_LIB/drive0.vt" 2>/dev/null || true)"; d="$BRIC_MOCK_LIB/tapes/$vt"
if [ "$OUT" = "$DEV" ]; then
  mkdir -p "$d"; eod="$(cat "$d/.eod" 2>/dev/null || echo 0)"; n=$((eod + 1))
  cp -f "$IN" "$d/$(printf 'f_%06d' "$n")"
  # This is the behavior of Linux st on close after a write.  The override is used only
  # by the negative test to prove that production fails closed on an unexpected position jump.
  marks="${BRIC_MOCK_CLOSE_FILEMARKS:-1}"; new_eod=$((eod + marks))
  echo "$new_eod" > "$d/.eod"; echo "$new_eod" > "$DEV.pos"
elif [ "$IN" = "$DEV" ]; then
  pos="$(cat "$DEV.pos" 2>/dev/null || echo 0)"; src="$d/$(printf 'f_%06d' "$((pos+1))")"; if [ -n "$OUT" ]; then cp -f "$src" "$OUT"; else cat "$src"; fi
else exec /usr/bin/dd "$@"; fi
M
chmod +x "$BIN"/*

touch "$LIB/sch0" "$LIB/nst0"
export PATH="$BIN:$PATH" BRIC_MOCK_LIB="$LIB"
export BRIC_TAPE_BACKEND=real BRIC_CHANGER="$LIB/sch0" BRIC_DRIVE0="$LIB/nst0" BRIC_TAPE_DRIVES=0
export BRIC_CHANGER_LOCK="$LIB/changer.lock" BRIC_DRIVE_LOCK_PREFIX="$LIB/drive.lock."
. "$REPO/tape/scripts/lib_tape_io.sh"

head -c 8192 /dev/urandom > "$ROOT/a"
head -c 5001 /dev/urandom > "$ROOT/b"
n1="$(tape_append_file 000044L9 "$ROOT/a")"
n2="$(tape_append_file 000044L9 "$ROOT/b")"
[ "$n1" = 1 ] || { echo "FAIL: first file number $n1, expected 1"; exit 1; }
[ "$n2" = 2 ] || { echo "FAIL: second file number $n2, expected 2"; exit 1; }
[ "$(tape_last_file_number 000044L9)" = 2 ] || { echo "FAIL: EOD is not 2"; exit 1; }
[ ! -s "$LIB/weof.calls" ] || { echo "FAIL: explicit mt weof was invoked"; cat "$LIB/weof.calls"; exit 1; }
tape_read_file 000044L9 1 "$ROOT/ra"
tape_read_file 000044L9 2 "$ROOT/rb"
cmp -s "$ROOT/a" "$ROOT/ra" || { echo "FAIL: file 1 mismatch"; exit 1; }
cmp -s "$ROOT/b" "$ROOT/rb" || { echo "FAIL: file 2 mismatch"; exit 1; }

# Negative path: if a driver/mode unexpectedly advances by two file positions, do not return a
# plausible catalog number.  The write may have consumed tape, but the operation must fail closed.
set +e
BRIC_MOCK_CLOSE_FILEMARKS=2 tape_append_file 000045L9 "$ROOT/a" >"$ROOT/bad.out" 2>"$ROOT/bad.err"
rc=$?
set -e
[ "$rc" -ne 0 ] || { echo "FAIL: anomalous +2 file-position advance was accepted"; exit 1; }
grep -q 'unexpected tape file position' "$ROOT/bad.err" || { echo "FAIL: position mismatch diagnostic missing"; cat "$ROOT/bad.err"; exit 1; }

# Non-destructive driver-option guards. /dev/null supplies a real character device while a test-only
# sysfs root supplies deterministic option masks.
mkdir -p "$LIB/sys/null"
echo 0x10 > "$LIB/sys/null/options"
if ( BRIC_SYSFS_SCSI_TAPE="$LIB/sys" _assert_contiguous_file_mode /dev/null test ) >"$ROOT/twofm.out" 2>"$ROOT/twofm.err"; then
    echo "FAIL: MT_ST_TWO_FM was accepted"; exit 1
fi
grep -q 'MT_ST_TWO_FM' "$ROOT/twofm.err" || { echo "FAIL: MT_ST_TWO_FM diagnostic missing"; exit 1; }
echo 0x20 > "$LIB/sys/null/options"
if ( BRIC_SYSFS_SCSI_TAPE="$LIB/sys" _assert_contiguous_file_mode /dev/null test ) >"$ROOT/fasteom.out" 2>"$ROOT/fasteom.err"; then
    echo "FAIL: MT_ST_FAST_MTEOM was accepted"; exit 1
fi
grep -q 'MT_ST_FAST_MTEOM' "$ROOT/fasteom.err" || { echo "FAIL: MT_ST_FAST_MTEOM diagnostic missing"; exit 1; }

echo "PASS run_filemark_semantics: contiguous 1,2 numbering; anomalous position and unsafe st options fail closed"
