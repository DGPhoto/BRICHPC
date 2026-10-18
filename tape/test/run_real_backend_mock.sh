#!/bin/bash
# Validate the REAL lib_tape_io backend (mtx/mt/dd orchestration, mtx-status parsing, load/unload,
# eod/fsf positioning, 1-based file-number arithmetic) WITHOUT hardware, using faithful command
# mocks that model a tape library as state (slots, one drive, per-tape numbered files + position).
set -euo pipefail
export BRIC_CONFIG=none   # hermetic: never read /etc/bric/bric.conf inside tests
REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
LIB="$ROOT/lib"; BIN="$ROOT/bin"; mkdir -p "$LIB/slots" "$LIB/tapes" "$BIN"
echo "workroot=$ROOT"

# ---- mock changer: mtx -f CH (status|load SLOT DRV|unload SLOT DRV) ----
cat > "$BIN/mtx" <<'M'
#!/bin/bash
ST="$BRIC_MOCK_LIB"; shift 2; cmd="$1"
case "$cmd" in
  status)
    if [ -s "$ST/drive0.vt" ]; then echo "Data Transfer Element 0:Full (Storage Element $(cat "$ST/drive0.slot") Loaded):VolumeTag = $(cat "$ST/drive0.vt")"
    else echo "Data Transfer Element 0:Empty"; fi
    for s in "$ST"/slots/*; do [ -s "$s" ] || continue; echo "      Storage Element $(basename "$s"):Full :VolumeTag=$(cat "$s")"; done ;;
  load)   echo "$(cat "$ST/slots/$2")" > "$ST/drive0.vt"; echo "$2" > "$ST/drive0.slot"; rm -f "$ST/slots/$2" ;;
  unload) echo "$(cat "$ST/drive0.vt")" > "$ST/slots/$2"; rm -f "$ST/drive0.vt" "$ST/drive0.slot" ;;
esac
M

# ---- mock drive positioner: mt -f DEV op [arg] ----
cat > "$BIN/mt" <<'M'
#!/bin/bash
dev="$2"; op="$3"; arg="${4:-}"; st="$dev.pos"
vt="$(cat "$BRIC_MOCK_LIB/drive0.vt" 2>/dev/null || true)"
eod(){ cat "$BRIC_MOCK_LIB/tapes/$vt/.eod" 2>/dev/null || echo 0; }
pos(){ cat "$st" 2>/dev/null || echo 0; }
[ -z "${BRIC_MOCK_MT_LOG:-}" ] || printf '%s %s\n' "$op" "$arg" >> "$BRIC_MOCK_MT_LOG"
case "$op" in
  setblk) : ;;
  weof)   n=$(( $(eod) + 1 )); mkdir -p "$BRIC_MOCK_LIB/tapes/$vt"; echo "$n" > "$BRIC_MOCK_LIB/tapes/$vt/.eod"; echo "$n" > "$st" ;;
  rewind) echo 0 > "$st" ;;
  eod)    eod > "$st" ;;
  fsf)    echo $(( $(pos) + arg )) > "$st" ;;
  # Linux st semantics observed on the real LTO-9 drives: from EOD after file N, `bsfm 2`
  # leaves the next read positioned at file N, which mt status reports as file number N-1.
  bsfm)
    if [ -n "${BRIC_MOCK_BSFM_FAIL_ONCE:-}" ] && [ -e "$BRIC_MOCK_BSFM_FAIL_ONCE" ]; then
      rm -f "$BRIC_MOCK_BSFM_FAIL_ONCE"
      exit 1
    elif [ -n "${BRIC_MOCK_BSFM_WRONG_ONCE:-}" ] && [ -e "$BRIC_MOCK_BSFM_WRONG_ONCE" ]; then
      rm -f "$BRIC_MOCK_BSFM_WRONG_ONCE"
      n=$(( $(pos) - 2 )); [ "$n" -ge 0 ] || n=0; echo "$n" > "$st"
    else
      n=$(( $(pos) - 1 )); [ "$n" -ge 0 ] || n=0; echo "$n" > "$st"
    fi ;;
  status) echo "file number=$(pos), block number=0, partition=0." ;;
esac
M

# ---- mock dd: device <-> file, real dd otherwise ----
cat > "$BIN/dd" <<'M'
#!/bin/bash
IN=""; OUT=""; for a in "$@"; do case "$a" in if=*) IN="${a#if=}";; of=*) OUT="${a#of=}";; esac; done
DEV="$BRIC_DRIVE0"; vt="$(cat "$BRIC_MOCK_LIB/drive0.vt" 2>/dev/null || true)"
d="$BRIC_MOCK_LIB/tapes/$vt"; pos="$(cat "$DEV.pos" 2>/dev/null || echo 0)"
if [ "$OUT" = "$DEV" ]; then
  mkdir -p "$d"; eod="$(cat "$d/.eod" 2>/dev/null || echo 0)"; n=$((eod + 1))
  cp -f "$IN" "$d/$(printf 'f_%06d' "$n")"
  # Model Linux st close-after-write: one flushing filemark and position advance.
  echo "$n" > "$d/.eod"; echo "$n" > "$DEV.pos"
elif [ "$IN" = "$DEV" ]; then
  src="$d/$(printf 'f_%06d' "$((pos+1))")"
  if [ -n "$OUT" ]; then cp -f "$src" "$OUT"; else cat "$src"; fi
else exec /usr/bin/dd "$@"; fi
M
chmod +x "$BIN"/* 2>/dev/null || true

# ---- fake library: 1 drive (element 0), 2 tapes in slots 1,2 ----
echo 000001L9 > "$LIB/slots/1"; echo 000002L9 > "$LIB/slots/2"
export BRIC_MOCK_LIB="$LIB" PATH="$BIN:$PATH"
export BRIC_TAPE_BACKEND=real BRIC_CHANGER=/mock/sch0 BRIC_DRIVE0="$LIB/nst0" BRIC_TAPE_DRIVES="0" BRIC_CHANGER_LOCK="$LIB/changer.lock"
. "$REPO/tape/scripts/lib_tape_io.sh"

A="$ROOT/A"; B="$ROOT/B"; C="$ROOT/C"; D="$ROOT/D"
head -c 5000 /dev/urandom > "$A"; head -c 9000 /dev/urandom > "$B"; head -c 3000 /dev/urandom > "$C"; head -c 7000 /dev/urandom > "$D"
export BRIC_MOCK_MT_LOG="$ROOT/mt.log"
fail=0; chk(){ [ "$2" = "$3" ] && echo "  ok: $1 ($2)" || { echo "  FAIL: $1 exp=$3 got=$2"; fail=1; }; }
cmpf(){ cmp -s "$1" "$2" && echo "  ok: $3" || { echo "  FAIL: $3"; fail=1; }; }

echo "=== append first file and prove first-file bsfm-failure fallback (rewind only, no fsf) ==="
n1="$(tape_append_file 000001L9 "$A")"; chk "first append returns file 1" "$n1" "1"
touch "$ROOT/bsfm-fail-once"; export BRIC_MOCK_BSFM_FAIL_ONCE="$ROOT/bsfm-fail-once"
: > "$BRIC_MOCK_MT_LOG"
tape_read_file_immediate 000001L9 1 "$ROOT/r1fallback"
cmpf "$A" "$ROOT/r1fallback" "file-1 bsfm command failure falls back byte-identically"
grep -q '^bsfm 2$' "$BRIC_MOCK_MT_LOG" && grep -q '^rewind ' "$BRIC_MOCK_MT_LOG" \
  && ! grep -q '^fsf ' "$BRIC_MOCK_MT_LOG" \
  && echo "  ok: file-1 fallback used rewind without fsf" \
  || { echo "  FAIL: file-1 absolute fallback sequence wrong"; fail=1; }
unset BRIC_MOCK_BSFM_FAIL_ONCE

echo "=== append second file (file-number arithmetic) ==="
n2="$(tape_append_file 000001L9 "$B")"; chk "second append returns file 2" "$n2" "2"
chk "tape_last_file_number = 2" "$(tape_last_file_number 000001L9)" "2"

echo "=== immediate readback uses eod + bsfm 2 and returns byte-identical file ==="
: > "$BRIC_MOCK_MT_LOG"
tape_read_file_immediate 000001L9 2 "$ROOT/r2fast"
cmpf "$B" "$ROOT/r2fast" "bsfm2 immediate readback is byte-identical"
grep -q '^bsfm 2$' "$BRIC_MOCK_MT_LOG" && echo "  ok: bsfm2 fast path issued" || { echo "  FAIL: bsfm2 not issued"; fail=1; }
if grep -q '^rewind ' "$BRIC_MOCK_MT_LOG"; then echo "  FAIL: fast path unexpectedly rewound"; fail=1; else echo "  ok: fast path avoided rewind"; fi

echo "=== successful-but-wrong bsfm landing is detected and falls back absolute ==="
n3="$(tape_append_file 000001L9 "$D")"; chk "third append returns file 3" "$n3" "3"
touch "$ROOT/bsfm-wrong-once"; export BRIC_MOCK_BSFM_WRONG_ONCE="$ROOT/bsfm-wrong-once"
: > "$BRIC_MOCK_MT_LOG"
tape_read_file_immediate 000001L9 3 "$ROOT/r3fallback"
cmpf "$D" "$ROOT/r3fallback" "wrong bsfm landing still reads correct file after fallback"
grep -q '^bsfm 2$' "$BRIC_MOCK_MT_LOG" && grep -q '^rewind ' "$BRIC_MOCK_MT_LOG" && grep -q '^fsf 2$' "$BRIC_MOCK_MT_LOG" \
  && echo "  ok: wrong successful landing triggered rewind+fsf fallback" \
  || { echo "  FAIL: absolute fallback sequence missing"; fail=1; }
unset BRIC_MOCK_BSFM_WRONG_ONCE

echo "=== arbitrary reads remain absolute (rewind + fsf positioning) ==="
tape_read_file 000001L9 1 "$ROOT/r1"; cmpf "$A" "$ROOT/r1" "file 1 round-trips"
tape_read_file 000001L9 2 "$ROOT/r2"; cmpf "$B" "$ROOT/r2" "file 2 round-trips"

echo "=== streaming verification hashes/counts without materializing a readback file ==="
BS="$(stat -c %s "$B")"; BH="$(sha256sum "$B" | awk '{print $1}')"
: > "$BRIC_MOCK_MT_LOG"
if tape_verify_file_immediate 000001L9 3 "$(stat -c %s "$D")" "$(sha256sum "$D" | awk '{print $1}')"; then
  echo "  ok: immediate streaming verify succeeds"
else
  echo "  FAIL: immediate streaming verify failed"; fail=1
fi
if tape_verify_file 000001L9 2 "$BS" "$BH"; then
  echo "  ok: absolute streaming verify succeeds"
else
  echo "  FAIL: absolute streaming verify failed"; fail=1
fi

echo "=== write to the OTHER tape (forces unload 000001L9 + load 000002L9 on the single drive) ==="
m1="$(tape_append_file 000002L9 "$C")"; chk "append on 2nd tape returns file 1" "$m1" "1"
tape_read_file 000002L9 1 "$ROOT/r3"; cmpf "$C" "$ROOT/r3" "2nd tape file round-trips"

echo "=== read 000001L9 again (forces reload + reposition) ==="
tape_read_file 000001L9 2 "$ROOT/r2b"; cmpf "$B" "$ROOT/r2b" "reload + read file 2 still correct"

echo "=== tape_list_volumetags sees both cartridges ==="
LST="$(tape_list_volumetags | sort | paste -sd, -)"; chk "library inventory" "$LST" "000001L9,000002L9"

echo
[ "$fail" -eq 0 ] && echo "✓ REAL BACKEND MOCK PASSED (absolute + bsfm2 immediate positioning, wrong-landing fallback, numbering)" || { echo "✗ FAILURES"; exit 1; }
