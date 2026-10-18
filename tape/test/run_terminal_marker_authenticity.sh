#!/bin/bash
# Review 30AC: marker existence is a safety fence, not destructive authority.
# With bus signing required, an unsigned run.ABORTED must stop tape I/O but must NOT delete staging,
# mutate the tape catalog, or publish ABORT_DONE. Only handle_abort after marker_verify may clean up.
set -euo pipefail
export BRIC_CONFIG=none
REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
fail(){ echo "FAIL: $*" >&2; exit 1; }

export BRIC_TAPE_HOME="$REPO/tape"
export BRIC_TAPE_DB="$ROOT/tape.db"
export BRIC_TAPE_SQL_INIT="$REPO/tape/sql/tape_init.sql"
export BRIC_TAPE_BACKEND=sim
export BRIC_TAPELIB="$ROOT/tapelib"
export BRIC_TAPE_LOCK="$ROOT/tape.lock"
export BRIC_TAPE_WORK_LOCK="$ROOT/tape.work.lock"
export BRIC_QNAP="$ROOT/qnap/bric"
export BRIC_REQUIRE_LOGGING=0
export BRIC_LOG_CAPTURE_STDIO=0
mkdir -p "$BRIC_QNAP/archive" "$BRIC_TAPELIB"
sqlite3 "$BRIC_TAPE_DB" < "$BRIC_TAPE_SQL_INIT" >/dev/null
sqlite3 "$BRIC_TAPE_DB" "UPDATE config SET value='1' WHERE key='require_bus_signing'; UPDATE config SET value='1' WHERE key='poll_seconds';" >/dev/null

openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$ROOT/cluster.pem" >/dev/null 2>&1
openssl pkey -in "$ROOT/cluster.pem" -pubout -out "$ROOT/cluster.pub" >/dev/null 2>&1
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$ROOT/tape.pem" >/dev/null 2>&1
export BRIC_BUS_SIGN_KEY="$ROOT/tape.pem"
export BRIC_BUS_VERIFY_KEY="$ROOT/cluster.pub"

RUN=authfence__20260828T000000Z__0001
RD="$BRIC_QNAP/archive/authfence/$RUN"
mkdir -p "$RD"
printf 'run_id=%s\nproject=authfence\n' "$RUN" > "$RD/run.ABORTED"   # deliberately UNSIGNED
printf 'ciphertext-must-survive' > "$RD/chunk_0001.enc"
printf 'ready-must-survive' > "$RD/chunk_0001.READY"
printf 'run_id=%s\nproject=authfence\nowner=tester\nchunk_no=1\ntype=TAR_PART\nsize_bytes=23\npayload_sha256=deadbeef\n' "$RUN" > "$RD/chunk_0001.meta"

before="$(sha256sum "$RD/chunk_0001.enc" | awk '{print $1}')"
"$REPO/tape/bin/bric-tape-daemon" --once >"$ROOT/daemon.log" 2>&1

after="$(sha256sum "$RD/chunk_0001.enc" | awk '{print $1}')"
[ "$before" = "$after" ] || fail "unsigned ABORTED modified/deleted ciphertext"
[ -e "$RD/chunk_0001.READY" ] || fail "unsigned ABORTED deleted READY"
[ ! -e "$RD/run.ABORT_DONE" ] || fail "unsigned ABORTED was acknowledged as authentic"
[ -z "$(find "$BRIC_TAPELIB" -type f -name 'f_*' -print -quit 2>/dev/null)" ] || fail "unsigned ABORTED allowed tape I/O"
grep -qi 'REFUSED run.ABORTED' "$ROOT/daemon.log" || fail "unsigned ABORTED rejection was not logged"

echo "PASS run_terminal_marker_authenticity"
