#!/bin/bash
# Review 31D: post-write verification must be streaming, classify read/size/hash failures distinctly,
# and remain correct even when the caller is in an errexit-suppressed context.
set -euo pipefail
export BRIC_CONFIG=none
REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
fail(){ echo "FAIL: $*" >&2; exit 1; }
export BRIC_TAPE_BACKEND=sim BRIC_TAPELIB="$ROOT/tapelib" BRIC_LOG_CAPTURE_STDIO=0
mkdir -p "$BRIC_TAPELIB/000001L9" "$ROOT/tmp"
export TMPDIR="$ROOT/tmp"
bric_event(){ :; }
die(){ echo "ERROR: $*" >&2; exit 1; }
. "$REPO/tape/scripts/lib_tape_io.sh"

PAY="$BRIC_TAPELIB/000001L9/f_000001"
head -c 1048577 /dev/urandom >"$PAY"
SIZE="$(stat -c %s "$PAY")"; SHA="$(sha256sum "$PAY" | awk '{print $1}')"

rc=0; if tape_verify_file_immediate 000001L9 1 "$SIZE" "$SHA"; then rc=0; else rc=$?; fi
[ "$rc" -eq 0 ] || fail "good stream returned rc=$rc"
[ -z "$(find "$TMPDIR" -mindepth 1 -maxdepth 1 -print -quit)" ] || fail "streaming verify left control scratch"
echo "  ok: exact stream verifies with control-only scratch"

export BRIC_FAULT_SIM_VERIFY_MODE=io
rc=0; if tape_verify_file_immediate 000001L9 1 "$SIZE" "$SHA"; then rc=0; else rc=$?; fi
[ "$rc" -eq 20 ] || fail "transport failure expected rc=20 got $rc"
echo "  ok: transport/local failure classified rc=20"

export BRIC_FAULT_SIM_VERIFY_MODE=short
rc=0; if tape_verify_file_immediate 000001L9 1 "$SIZE" "$SHA"; then rc=0; else rc=$?; fi
[ "$rc" -eq 21 ] || fail "short stream expected rc=21 got $rc"
echo "  ok: clean short stream classified rc=21 for caller media policy"

export BRIC_FAULT_SIM_VERIFY_MODE=corrupt
rc=0; if tape_verify_file_immediate 000001L9 1 "$SIZE" "$SHA"; then rc=0; else rc=$?; fi
[ "$rc" -eq 22 ] || fail "complete corrupt stream expected rc=22 got $rc"
echo "  ok: exact-size hash mismatch classified rc=22"
unset BRIC_FAULT_SIM_VERIFY_MODE

DAEMON="$REPO/tape/bin/bric-tape-daemon"
! grep -Eq 'rb=.*mktemp.*tape_read_file_immediate|tape_read_file_immediate.*\$rb' "$DAEMON" \
  || fail "daemon still materializes immediate verification into a tempfile"
grep -q 'if tape_verify_file_immediate' "$DAEMON" || fail "daemon does not explicitly inspect verify rc"
! grep -q 'one_pass ||' "$DAEMON" || fail "daemon still invokes one_pass under errexit-suppressing ||"
echo "  ok: daemon has no segment-sized verify tempfile and no one_pass || suppression"

echo "PASS run_stream_verify"
