#!/bin/bash
. "$(cd "$(dirname "$(readlink -f "$0")")" && pwd)/lib_test_daemon.sh"
# Review 32B5: real sim-backend backup + logical single-file restore for TAR/LARGE_FILE_CHUNK,
# legacy --run compatibility, full-restore baseline semantics, and verification-state classification.
set -euo pipefail
export BRIC_CONFIG=none
REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
ROOT="$(mktemp -d /tmp/bric-32b5-restore.XXXXXX)"; echo "workroot=$ROOT"
fail=0; ok(){ echo "  ok: $*"; }; bad(){ echo "  FAIL: $*"; fail=1; }

export BRIC_HOME="$REPO/cluster" BRIC_DB="$ROOT/cluster.db" BRIC_QNAP="$ROOT/qnap/bric"
export BRIC_KEYS="$ROOT/keys" BRIC_SQL_INIT="$REPO/cluster/sql/cluster_init.sql"
export BRIC_USER="vsz652" BRIC_RUN_MODE=local BRIC_POLL=1
export BRIC_RESERVE_TIMEOUT=60 BRIC_DRAIN_TIMEOUT=90 BRIC_CLOSE_TIMEOUT=90 BRIC_RESTORE_TIMEOUT=90
export BRIC_KEEP_RESTORE_BUS=1
export BRIC_TAPE_HOME="$REPO/tape" BRIC_TAPE_DB="$ROOT/tape.db" BRIC_TAPE_SQL_INIT="$REPO/tape/sql/tape_init.sql"
export BRIC_TAPE_BACKEND=sim BRIC_TAPELIB="$ROOT/tapelib" BRIC_TAPE_LOCK="$ROOT/tape.lock"
export BRIC_RESTORE_PROGRESS_INTERVAL=1 BRIC_RESTORE_CONSUME_TIMEOUT=60
export BRIC_LOG_DIR="$ROOT/log/primary" BRIC_LOG_FALLBACK_DIR="$ROOT/log/fallback" BRIC_REQUIRE_LOGGING=1
mkdir -p "$BRIC_QNAP" "$BRIC_KEYS" "$BRIC_TAPELIB" "$BRIC_LOG_DIR" "$BRIC_LOG_FALLBACK_DIR"
sqlite3 "$BRIC_DB" < "$BRIC_SQL_INIT" >/dev/null
sqlite3 "$BRIC_TAPE_DB" < "$BRIC_TAPE_SQL_INIT" >/dev/null
# Small target gives one ordinary TAR chunk plus multiple LARGE_FILE_CHUNK pieces.
sqlite3 "$BRIC_DB" "UPDATE config SET value='1048576' WHERE key='segment_target_bytes';"
sqlite3 "$BRIC_TAPE_DB" "UPDATE config SET value='1' WHERE key='poll_seconds';"
head -c 32 /dev/urandom | base64 > "$BRIC_KEYS/${BRIC_USER}_user_key.txt"
head -c 32 /dev/urandom | base64 > "$BRIC_KEYS/master.key"
sqlite3 "$BRIC_TAPE_DB" "INSERT INTO tapes(volumetag,slot,role,pair_number,paired_volumetag,capacity_tb,used_tb,status)
 VALUES('000092L9',1,'PRIMARY',1,'000093L9',18,0,'EMPTY'),('000093L9',2,'BACKUP',1,'000092L9',18,0,'EMPTY');"

REAL_SRC="$ROOT/real-source"; SRC_LINK="$ROOT/declared-source"
mkdir -p "$REAL_SRC/sub"
printf 'small-v1\n' > "$REAL_SRC/sub/small.txt"
dd if=/dev/urandom of="$REAL_SRC/large.bin" bs=1M count=3 status=none
ln -s "$REAL_SRC" "$SRC_LINK"

setsid "$REPO/tape/bin/bric-tape-daemon" --loop >"$ROOT/daemon.log" 2>&1 & DAEMON=$!
trap 'bric_test_stop_group "$DAEMON"; [ -n "${KEEP:-}" ] || { rm -rf "$ROOT" 2>/dev/null || { sleep 1; rm -rf "$ROOT"; }; }' EXIT
sleep 1
RUN="$("$REPO/cluster/bin/bric" backup --project logical --source "$SRC_LINK" --as datasetA)"
[ "$(sqlite3 "$BRIC_DB" "SELECT status FROM runs WHERE run_id='$RUN';")" = CLOSED ] && ok "--as backup CLOSED" || bad "--as backup not CLOSED"
[ "$(sqlite3 "$BRIC_DB" "SELECT source_path FROM runs WHERE run_id='$RUN';")" = "$SRC_LINK" ] && ok "declared source_path preserved" || bad "declared source_path changed"
[ "$(sqlite3 "$BRIC_DB" "SELECT source_canonical_path FROM runs WHERE run_id='$RUN';")" = "$(readlink -f "$SRC_LINK")" ] && ok "canonical source recorded on planner host" || bad "canonical source wrong"
[ "$(sqlite3 "$BRIC_DB" "SELECT logical_root FROM runs WHERE run_id='$RUN';")" = datasetA ] && ok "logical_root recorded" || bad "logical_root missing"

# Catalog view exposes logical prefix without changing physical rel_path.
BRIC_ROLE=slurm "$REPO/cluster/bin/bric-run" contents logical --limit 0 >"$ROOT/contents.out" 2>"$ROOT/contents.err"
grep -q '^datasetA/sub/small.txt$' "$ROOT/contents.out" && ok "contents exposes logical path" || bad "logical small path absent"
grep -q '^datasetA/large.bin$' "$ROOT/contents.out" && ok "contents exposes logical large path" || bad "logical large path absent"
[ "$(sqlite3 "$BRIC_DB" "SELECT COUNT(*) FROM files WHERE run_id='$RUN' AND rel_path LIKE 'datasetA/%';")" -eq 0 ] && ok "physical catalog rel_path remains unprefixed" || bad "logical root leaked into physical rel_path"

# Automatic logical TAR-member restore: ROOT/REL -> physical REL -> DEST/ROOT/REL.
D1="$ROOT/restore-small"
if "$REPO/cluster/scripts/bric-restore.sh" --project logical --dest "$D1" --file datasetA/sub/small.txt >"$ROOT/restore-small.log" 2>&1 \
   && cmp "$REAL_SRC/sub/small.txt" "$D1/datasetA/sub/small.txt"; then
  ok "logical TAR restore placed under DEST/datasetA"
else bad "logical TAR restore failed"; tail -30 "$ROOT/restore-small.log" || true; fi
grep -q 'VERIFIED-DESTINATION: datasetA/sub/small.txt' "$ROOT/restore-small.log" && ok "destination verification reported" || bad "destination verification status missing"

# Same contract for LARGE_FILE_CHUNK: no double prefix and exact bytes.
D2="$ROOT/restore-large"
if "$REPO/cluster/scripts/bric-restore.sh" --project logical --dest "$D2" --file datasetA/large.bin >"$ROOT/restore-large.log" 2>&1 \
   && cmp "$REAL_SRC/large.bin" "$D2/datasetA/large.bin"; then
  ok "logical LARGE_FILE_CHUNK restore exact and singly prefixed"
else bad "logical LARGE_FILE_CHUNK restore failed"; tail -30 "$ROOT/restore-large.log" || true; fi
[ ! -e "$D2/datasetA/datasetA/large.bin" ] || bad "double logical prefix created"

# Explicit --run retains legacy bare path behavior and also accepts the logical form.
D3="$ROOT/restore-run-bare"
"$REPO/cluster/scripts/bric-restore.sh" --project logical --dest "$D3" --run "$RUN" --file sub/small.txt >"$ROOT/run-bare.log" 2>&1
cmp "$REAL_SRC/sub/small.txt" "$D3/sub/small.txt" && ok "legacy bare --run restore preserved" || bad "legacy bare --run restore changed"
D4="$ROOT/restore-run-logical"
"$REPO/cluster/scripts/bric-restore.sh" --project logical --dest "$D4" --run "$RUN" --file datasetA/sub/small.txt >"$ROOT/run-logical.log" 2>&1
cmp "$REAL_SRC/sub/small.txt" "$D4/datasetA/sub/small.txt" && ok "namespaced --run restore works" || bad "namespaced --run restore failed"

# Full restore remains baseline last-CLOSED semantics: unprefixed tree of the selected run.
DF="$ROOT/restore-full"
if "$REPO/cluster/scripts/bric-restore.sh" --project logical --dest "$DF" >"$ROOT/full.log" 2>&1 && diff -r "$REAL_SRC" "$DF" >/dev/null; then
  ok "full restore remains last-CLOSED and unprefixed"
else bad "full restore semantics regressed"; fi

# Inject a second logical root only into the catalog to prove automatic bare lookup fails closed
# before any staging when the same rel_path is ambiguous.
sqlite3 "$BRIC_DB" "INSERT INTO runs(run_id,project_name,kind,source_path,submitted_by,owner,status,requested_at,closed_at,source_canonical_path,logical_root)
 VALUES('logical__synthetic__rootB','logical','APPEND','/synthetic/B','vsz652','vsz652','CLOSED','2026-09-24 23:00:00','2026-09-24 23:01:00','/synthetic/B','datasetB');
 INSERT INTO files(run_id,rel_path,size_bytes,mtime,sha256_plain,chunk_no,member_index,entry_type)
 SELECT 'logical__synthetic__rootB','sub/small.txt',size_bytes,mtime,sha256_plain,chunk_no,member_index,entry_type FROM files WHERE run_id='$RUN' AND rel_path='sub/small.txt';"
if "$REPO/cluster/scripts/bric-restore.sh" --project logical --dest "$ROOT/ambiguous" --file sub/small.txt >"$ROOT/ambiguous.log" 2>&1; then
  bad "ambiguous automatic bare path was accepted"
else
  grep -q 'legacy bare path is ambiguous' "$ROOT/ambiguous.log" && ok "ambiguous bare path rejected" || bad "wrong ambiguous-path error"
fi
if "$REPO/cluster/scripts/bric-restore.sh" --project logical --dest "$ROOT/mismatch-root" --run "$RUN" --file datasetB/sub/small.txt >"$ROOT/mismatch-root.log" 2>&1; then
  bad "--run accepted another logical root"
else
  grep -q "does not match run" "$ROOT/mismatch-root.log" && ok "--run logical-root mismatch rejected" || bad "wrong --run root mismatch error"
fi
if "$REPO/cluster/scripts/bric-restore.sh" --project logical --dest "$ROOT/traversal" --run "$RUN" --file 'datasetA/../sub/small.txt' >"$ROOT/traversal.log" 2>&1; then
  bad "path traversal accepted"
else
  grep -q 'unsafe --file path' "$ROOT/traversal.log" && ok "path traversal rejected before restore" || bad "wrong traversal error"
fi

# Remove synthetic run before verification-state tape restores so automatic namespaced lookup is unchanged.
sqlite3 "$BRIC_DB" "DELETE FROM files WHERE run_id='logical__synthetic__rootB'; DELETE FROM runs WHERE run_id='logical__synthetic__rootB';"

# Test-only sha256 shim: fail a destination re-read -> VERIFIED-STREAM success; return a wrong digest
# with exit 0 -> CHECKSUM-MISMATCH failure. All other sha256sum calls delegate to the real utility.
MOCKBIN="$ROOT/mockbin"; mkdir -p "$MOCKBIN"
cat > "$MOCKBIN/sha256sum" <<'SH'
#!/bin/bash
last="${!#}"
if [ -n "${BRIC_TEST_SHA_PATH:-}" ] && [ "$last" = "$BRIC_TEST_SHA_PATH" ]; then
  case "${BRIC_TEST_SHA_MODE:-}" in
    fail) echo "sha256sum: $last: Permission denied" >&2; exit 1;;
    mismatch) printf '%064d  %s\n' 0 "$last"; exit 0;;
  esac
fi
exec /usr/bin/sha256sum "$@"
SH
chmod +x "$MOCKBIN/sha256sum"

DS="$ROOT/restore-stream"
if PATH="$MOCKBIN:$PATH" BRIC_TEST_SHA_PATH="$DS/datasetA/sub/small.txt" BRIC_TEST_SHA_MODE=fail \
   "$REPO/cluster/scripts/bric-restore.sh" --project logical --dest "$DS" --file datasetA/sub/small.txt >"$ROOT/stream.log" 2>&1; then
  grep -q 'VERIFIED-STREAM: datasetA/sub/small.txt' "$ROOT/stream.log" && ok "unreadable destination classified VERIFIED-STREAM" || bad "VERIFIED-STREAM not reported"
  ! grep -q 'CHECKSUM-MISMATCH: datasetA/sub/small.txt' "$ROOT/stream.log" || bad "sha read failure mislabeled checksum mismatch"
else bad "VERIFIED-STREAM fallback returned non-zero"; tail -30 "$ROOT/stream.log" || true; fi

DM="$ROOT/restore-mismatch"
if PATH="$MOCKBIN:$PATH" BRIC_TEST_SHA_PATH="$DM/datasetA/sub/small.txt" BRIC_TEST_SHA_MODE=mismatch \
   "$REPO/cluster/scripts/bric-restore.sh" --project logical --dest "$DM" --file datasetA/sub/small.txt >"$ROOT/mismatch.log" 2>&1; then
  bad "real digest mismatch returned success"
else
  grep -q 'CHECKSUM-MISMATCH: datasetA/sub/small.txt' "$ROOT/mismatch.log" && ok "computed unequal digest classified CHECKSUM-MISMATCH" || bad "checksum mismatch status absent"
  ! grep -q 'VERIFIED-STREAM: datasetA/sub/small.txt' "$ROOT/mismatch.log" || bad "mismatch downgraded to stream verification"
fi

echo
[ "$fail" -eq 0 ] && echo 'PASS: 32B5 logical backup/restore and verification classification' || { echo 'FAIL: 32B5 logical restore checks'; exit 1; }
