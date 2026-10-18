#!/bin/bash
# Review 32A: one project/run, multiple local tar-stream workers, one global chunk namespace.
set -euo pipefail
REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export PATH="${BRIC_TEST_SQLITE_BIN:-/tmp/sqlitebin}:$PATH"
command -v sqlite3 >/dev/null || { echo "SKIP: sqlite3 unavailable"; exit 77; }
export BRIC_CONFIG=none BRIC_ROLE=slurm BRIC_HOME="$REPO/cluster" BRIC_DB="$T/catalog.db"
export BRIC_SQL_INIT="$REPO/cluster/sql/cluster_init.sql" BRIC_QNAP="$T/qnap/bric" BRIC_QNAP_MNT="$T/qnap"
export BRIC_RUNSTATE="$T/runstate" BRIC_REQUIRE_NFS_BUS=0 BRIC_REQUIRE_LOGGING=0 BRIC_LOG_CAPTURE_STDIO=0
mkdir -p "$BRIC_QNAP/archive/p/r" "$BRIC_RUNSTATE/r" "$T/src/d/sub" "$T/out"
sqlite3 "$BRIC_DB" < "$BRIC_SQL_INIT"
sqlite3 "$BRIC_DB" <<SQL
INSERT INTO projects(project_name,owner) VALUES('p','u');
INSERT INTO runs(run_id,project_name,kind,source_path,submitted_by,owner,status) VALUES('r','p','ARCHIVE','$T/src','u','u','PRODUCING');
INSERT INTO run_source_semantics(run_id,source_change_policy,source_consistency) VALUES('r','strict','pending');
UPDATE config SET value='100' WHERE key='max_inflight_chunks';
UPDATE config SET value='0' WHERE key='qnap_budget_bytes';
UPDATE config SET value='0' WHERE key='require_bus_signing';
SQL
printf '%s\n' 999999999999 > "$BRIC_RUNSTATE/r/reserved_capacity"
printf secret-pass > "$T/enc"; printf hmac-key > "$T/hmac"
# Uneven ordinary files exercise greedy balancing and concurrent publication. Sparse/oversized
# semantics are covered exhaustively by run_tar_stream.sh; keep this test small enough for the
# Python sqlite3 compatibility shim used in non-native CI.
for i in 1 2 3 4 5 6 7 8; do head -c $((i*70000)) /dev/urandom > "$T/src/d/f$i.bin"; done
printf hello > "$T/src/d/sub/tiny.txt"
# One oversized file is owned by exactly one worker but allocates multiple globally interleaved chunks.
head -c 25000000 /dev/urandom > "$T/src/d/huge.bin"
ln -s ../f1.bin "$T/src/d/link"

"$REPO/cluster/scripts/bric-stream-parallel-produce.sh" \
  --run r --project p --owner u --source "$T/src" --target 10000000 --workers 4 \
  --runstate "$BRIC_RUNSTATE/r" --run-dir "$BRIC_QNAP/archive/p/r" \
  --enc-pass-file "$T/enc" --hmac-key-file "$T/hmac" --tar-blocking-factor 8192 \
  --progress-every 2 --sparse-min-hole 1048576 --sparse-max-allocated-percent 75 \
  --sparse-batch-target 1048576 --source-change-policy strict > "$T/result"

alloc="$(sqlite3 "$BRIC_DB" "SELECT COUNT(*) FROM chunks WHERE run_id='r' AND state='ALLOCATED';")"
[ "$alloc" = 0 ] || { echo "FAIL: $alloc ALLOCATED chunks remain"; exit 1; }
n="$(sqlite3 "$BRIC_DB" "SELECT COUNT(*) FROM chunks WHERE run_id='r';")"
max="$(sqlite3 "$BRIC_DB" "SELECT COALESCE(MAX(chunk_no),0) FROM chunks WHERE run_id='r';")"
[ "$n" -gt 4 ] && [ "$n" = "$max" ] || { echo "FAIL: global chunk namespace has gaps count=$n max=$max"; exit 1; }
dup="$(sqlite3 "$BRIC_DB" "SELECT COUNT(*) FROM (SELECT chunk_no,COUNT(*) c FROM chunks WHERE run_id='r' GROUP BY chunk_no HAVING c<>1);")"
[ "$dup" = 0 ] || { echo "FAIL: duplicate chunk numbers"; exit 1; }
[ "$(sqlite3 "$BRIC_DB" "SELECT source_consistency FROM run_source_semantics WHERE run_id='r';")" = clean ]

# Restore all TAR_PARTs; ordering by chunk_no is not required for file data, but directory metadata was
# deliberately produced after data and therefore naturally lands later.
while IFS='|' read -r c typ; do
  blob="$BRIC_QNAP/archive/p/r/chunk_$(printf '%04d' "$c").enc"
  [ -s "$blob" ] || { echo "FAIL: missing blob $blob"; exit 1; }
  if [ "$typ" = TAR_PART ]; then
    openssl enc -d -aes-256-cbc -pbkdf2 -iter 10000 -pass file:"$T/enc" -in "$blob" | tar -C "$T/out" --delay-directory-restore -xf -
  fi
done < <(sqlite3 -separator '|' "$BRIC_DB" "SELECT chunk_no,type FROM chunks WHERE run_id='r' ORDER BY chunk_no;")
# Reassemble the oversized file strictly by semantic piece order, independent of global chunk_no.
large_n="$(sqlite3 "$BRIC_DB" "SELECT COUNT(*) FROM chunks WHERE run_id='r' AND type='LARGE_FILE_CHUNK' AND big_rel_path='d/huge.bin';")"
[ "$large_n" -ge 3 ] || { echo "FAIL: oversized file did not produce multiple LARGE_FILE_CHUNK rows ($large_n)"; exit 1; }
: > "$T/out/d/huge.bin"
while IFS='|' read -r c idx off; do
  blob="$BRIC_QNAP/archive/p/r/chunk_$(printf '%04d' "$c").enc"
  openssl enc -d -aes-256-cbc -pbkdf2 -iter 10000 -pass file:"$T/enc" -in "$blob" >> "$T/out/d/huge.bin"
done < <(sqlite3 -separator '|' "$BRIC_DB" "SELECT chunk_no,chunk_index,offset_bytes FROM chunks WHERE run_id='r' AND big_rel_path='d/huge.bin' ORDER BY chunk_index;")
for f in d/f1.bin d/f8.bin d/sub/tiny.txt d/huge.bin; do cmp -s "$T/src/$f" "$T/out/$f" || { echo "FAIL: restore mismatch $f"; exit 1; }; done
[ -L "$T/out/d/link" ] && [ "$(readlink "$T/out/d/link")" = ../f1.bin ] || { echo "FAIL: symlink restore"; exit 1; }
# Every catalog file path is unique even though publication was concurrent.
dups="$(sqlite3 "$BRIC_DB" "SELECT COUNT(*) FROM (SELECT rel_path,COUNT(*) c FROM files WHERE run_id='r' GROUP BY rel_path HAVING c<>1);")"
[ "$dups" = 0 ] || { echo "FAIL: duplicate file catalog rows"; exit 1; }
grep -q '^workers=4$' "$T/result"
echo "PASS single-run parallel producer: workers=4 chunks=$n global namespace contiguous restore=exact"
