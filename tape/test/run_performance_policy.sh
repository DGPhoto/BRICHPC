#!/bin/bash
# Review 32A performance policy regression checks.
set -euo pipefail
export BRIC_CONFIG=none
REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
fail(){ echo "FAIL: $*" >&2; exit 1; }

export BRIC_TAPE_BACKEND=sim BRIC_LOG_CAPTURE_STDIO=0
bric_event(){ :; }
die(){ echo "ERROR: $*" >&2; exit 1; }
. "$REPO/tape/scripts/lib_tape_io.sh"

[ "$BRIC_TAPE_BLOCK" = 262144 ] || fail "BRIC_TAPE_BLOCK changed: $BRIC_TAPE_BLOCK"
[ "$BRIC_TAPE_STAGE_READ_BLOCK" = 4194304 ] || fail "stage read block is $BRIC_TAPE_STAGE_READ_BLOCK"
grep -Fq 'dd if="$src" of="$dev" iflag=fullblock ibs="$BRIC_TAPE_STAGE_READ_BLOCK" obs="$BRIC_TAPE_BLOCK"' \
    "$REPO/tape/scripts/lib_tape_io.sh" || fail "tape append path does not decouple staging read size from tape block"
echo "  ok: tape writes retain 256 KiB records while QNAP input reads use 4 MiB"

export BRIC_TAPE_VERIFY_POSITION_MODE=adaptive
export BRIC_TAPE_BSFM_BYTES_PER_SEC=210000000
export BRIC_TAPE_REWIND_MILLISECONDS=46000
export BRIC_TAPE_FSF_MILLISECONDS_PER_FILE=400

# ~6 GB reverse ~= 28.6 s and beats rewind at file 1.
[ "$(_tape_verify_position_method 1 6000000000)" = relative ] || fail "small immediate file should use relative positioning"
# ~128 GB reverse ~= 10.2 min and must never beat a normal rewind+fsf on LTO-9.
[ "$(_tape_verify_position_method 18 128000000000)" = absolute ] || fail "128 GB immediate file should use absolute positioning"
# A later small file can still favor relative movement.
[ "$(_tape_verify_position_method 100 10000000000)" = relative ] || fail "small late file should use relative positioning"
BRIC_TAPE_VERIFY_POSITION_MODE=absolute
[ "$(_tape_verify_position_method 1 1)" = absolute ] || fail "forced absolute mode ignored"
BRIC_TAPE_VERIFY_POSITION_MODE=relative
[ "$(_tape_verify_position_method 1 999999999999)" = relative ] || fail "forced relative mode ignored"
echo "  ok: adaptive tape positioning selects both branches and honors overrides"

# Producer record tuning is deliberately limited to the OUTER one-pass tar stream. TAR streams
# encrypted/stored directly keep GNU tar's conservative record behavior to avoid large trailing
# record padding interacting badly with openssl|tar pipe consumers.
grep -Fq -- '--blocking-factor="$TAR_BLOCKING_FACTOR"' "$REPO/cluster/scripts/bric-stream-backup.sh" || fail "stream producer lacks outer tar blocking factor"
if grep -Fq -- '--blocking-factor="$TAR_BLOCKING_FACTOR"' "$REPO/cluster/scripts/bric-chunk.sh"; then
    fail "planned producer must not store large-record GNU tar output directly"
fi
"$REPO/cluster/libexec/bric-tar-stream" --version | grep -q '34-file-metadata' || fail "Go helper version is not Review 34"
grep -Fq 'Drain that padding to EOF so the producer never receives SIGPIPE' "$REPO/cluster/libexec/bric-tar-stream.go" || fail "Go helper does not drain outer tar record padding"
echo "  ok: 4 MiB record tuning is limited to the repacked one-pass outer stream and drains record padding safely"

command -v sqlite3 >/dev/null 2>&1 || fail "sqlite3 required"
DB="$(mktemp)"; trap 'rm -f "$DB"' EXIT
sqlite3 "$DB" < "$REPO/cluster/sql/cluster_init.sql" >/dev/null
[ "$(sqlite3 "$DB" "SELECT value FROM config WHERE key='segment_target_bytes';")" = 128000000000 ] || fail "chunk target default mismatch"
[ "$(sqlite3 "$DB" "SELECT value FROM config WHERE key='max_concurrent_producers';")" = 1 ] || fail "run-level producer concurrency default mismatch"
[ "$(sqlite3 "$DB" "SELECT value FROM config WHERE key='stream_parallel_workers';")" = 4 ] || fail "single-run worker default mismatch"
[ "$(sqlite3 "$DB" "SELECT value FROM config WHERE key='stream_worker_chunk_bytes';")" = 128000000000 ] || fail "worker chunk target mismatch"
[ "$(sqlite3 "$DB" "SELECT value FROM config WHERE key='tar_blocking_factor';")" = 8192 ] || fail "tar blocking factor default mismatch"
TDB="$(mktemp)"; trap 'rm -f "$DB" "$TDB"' EXIT
sqlite3 "$TDB" < "$REPO/tape/sql/tape_init.sql" >/dev/null
[ "$(sqlite3 "$TDB" "SELECT value FROM config WHERE key='chunk_target_bytes';")" = 128000000000 ] || fail "tape chunk target default mismatch"
grep -Fq -- '--allocate "$ALLOC"' "$REPO/cluster/scripts/bric-stream-parallel-produce.sh" || fail "parallel producer does not use atomic chunk allocator"
grep -Fq "state='ALLOCATED'" "$REPO/cluster/scripts/bric-stream-allocate.sh" || fail "allocator does not reserve placeholder chunks"
echo "  ok: fresh catalog defaults to one run with four internal workers with a 128 GB hard chunk bound"

echo "PASS run_performance_policy"
