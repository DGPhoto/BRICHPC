#!/bin/bash
. "$(cd "$(dirname "$(readlink -f "$0")")" && pwd)/lib_test_daemon.sh"
# Review 33R3 decisive E2E: real backup+restore with final mode-000 directory crossing chunks.
set -euo pipefail
export BRIC_CONFIG=none
REPO="${1:-$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)}"
ROOT="$(mktemp -d /tmp/bric-acc33.XXXXXX)"; echo "workroot=$ROOT"
fail=0; ok(){ echo "  ok: $*"; }; bad(){ echo "  FAIL: $*"; fail=1; }
export BRIC_HOME="$REPO/cluster" BRIC_DB="$ROOT/cluster.db" BRIC_QNAP="$ROOT/qnap/bric"
export BRIC_KEYS="$ROOT/keys" BRIC_SQL_INIT="$REPO/cluster/sql/cluster_init.sql"
export BRIC_USER="accuser" BRIC_RUN_MODE=local BRIC_POLL=1
export BRIC_RESERVE_TIMEOUT=120 BRIC_DRAIN_TIMEOUT=180 BRIC_CLOSE_TIMEOUT=180 BRIC_RESTORE_TIMEOUT=180
export BRIC_KEEP_RESTORE_BUS=1
export BRIC_TAPE_HOME="$REPO/tape" BRIC_TAPE_DB="$ROOT/tape.db" BRIC_TAPE_SQL_INIT="$REPO/tape/sql/tape_init.sql"
export BRIC_TAPE_BACKEND=sim BRIC_TAPELIB="$ROOT/tapelib" BRIC_TAPE_LOCK="$ROOT/tape.lock"
export BRIC_RESTORE_PROGRESS_INTERVAL=1 BRIC_RESTORE_CONSUME_TIMEOUT=120
export BRIC_LOG_DIR="$ROOT/log/primary" BRIC_LOG_FALLBACK_DIR="$ROOT/log/fallback" BRIC_REQUIRE_LOGGING=1
export BRIC_RESTORE_JOURNAL_ROOT="$ROOT/journal"
mkdir -p "$BRIC_QNAP" "$BRIC_KEYS" "$BRIC_TAPELIB" "$BRIC_LOG_DIR" "$BRIC_LOG_FALLBACK_DIR" "$ROOT/journal"
sqlite3 "$BRIC_DB" < "$BRIC_SQL_INIT" >/dev/null
sqlite3 "$BRIC_TAPE_DB" < "$BRIC_TAPE_SQL_INIT" >/dev/null
sqlite3 "$BRIC_DB" "UPDATE config SET value='1048576' WHERE key='segment_target_bytes';"
sqlite3 "$BRIC_TAPE_DB" "UPDATE config SET value='1' WHERE key='poll_seconds';"
head -c 32 /dev/urandom | base64 > "$BRIC_KEYS/${BRIC_USER}_user_key.txt"
head -c 32 /dev/urandom | base64 > "$BRIC_KEYS/master.key"
sqlite3 "$BRIC_TAPE_DB" "INSERT INTO tapes(volumetag,slot,role,pair_number,paired_volumetag,capacity_tb,used_tb,status) VALUES('000094L9',1,'PRIMARY',1,'000095L9',18,0,'EMPTY'),('000095L9',2,'BACKUP',1,'000094L9',18,0,'EMPTY');"
SRC="$ROOT/source"; mkdir -p "$SRC/frozen/data" "$SRC/open"
dd if=/dev/urandom of="$SRC/frozen/data/file.dat" bs=1K count=64 status=none
dd if=/dev/urandom of="$SRC/open/big.bin" bs=1M count=3 status=none
dd if=/dev/urandom of="$SRC/open/filler.bin" bs=1M count=2 status=none
chmod 644 "$SRC/open/big.bin"
WANT_SHA="$(sha256sum "$SRC/frozen/data/file.dat" | awk '{print $1}')"
chmod 500 "$SRC/frozen/data"; chmod 000 "$SRC/frozen"
setsid "$REPO/tape/bin/bric-tape-daemon" --loop >"$ROOT/daemon.log" 2>&1 & DAEMON=$!
cleanup(){ bric_test_stop_group "$DAEMON"; chmod -R u+rwx "$ROOT" 2>/dev/null || true; [ -n "${KEEP:-}" ] || { rm -rf "$ROOT" 2>/dev/null || { sleep 1; rm -rf "$ROOT"; }; }; }
trap cleanup EXIT
sleep 1
RUN="$("$REPO/cluster/bin/bric" backup --project acc --source "$SRC" --as frozenset 2>"$ROOT/backup.err")" || { tail -30 "$ROOT/backup.err"; exit 1; }
[ "$(sqlite3 "$BRIC_DB" "SELECT status FROM runs WHERE run_id='$RUN';")" = CLOSED ] && ok "run CLOSED" || bad "run not CLOSED"
DIRCHUNK="$(sqlite3 "$BRIC_DB" "SELECT chunk_no FROM files WHERE run_id='$RUN' AND rel_path='frozen' AND entry_type='D';")"
FILECHUNK="$(sqlite3 "$BRIC_DB" "SELECT chunk_no FROM files WHERE run_id='$RUN' AND rel_path='frozen/data/file.dat';")"
NCHUNKS="$(sqlite3 "$BRIC_DB" "SELECT COUNT(*) FROM chunks WHERE run_id='$RUN';")"
echo "  chunks=$NCHUNKS frozen(D)=chunk_${DIRCHUNK:-none} frozen/data/file.dat=chunk_${FILECHUNK:-none}"
[ -n "$DIRCHUNK" ] && [ -n "$FILECHUNK" ] && [ "$DIRCHUNK" != "$FILECHUNK" ] && ok "restrictive directory metadata is cross-chunk" || bad "cross-chunk property not exercised"
DEST="$ROOT/restored"; umask 022
set +e; "$REPO/cluster/scripts/bric-restore.sh" --project acc --dest "$DEST" >"$ROOT/restore.log" 2>&1; RRC=$?; set -e
[ "$RRC" -eq 0 ] && ok "restore exited 0" || bad "restore exited $RRC"
grep -q 'MISSING/WRONG-TYPE' "$ROOT/restore.log" && bad "false MISSING/WRONG-TYPE" || ok "no MISSING/WRONG-TYPE"
grep -q 'CHECKSUM-MISMATCH: ' "$ROOT/restore.log" && bad "checksum mismatch" || ok "no checksum mismatch"
grep -q 'VERIFIED-DESTINATION: frozen/data/file.dat' "$ROOT/restore.log" && ok "restrictive descendant VERIFIED-DESTINATION" || bad "descendant not destination-verified"
FM="$(stat -c '%a' "$DEST/frozen" 2>/dev/null || echo '?')"; { [ "$FM" = 0 ] || [ "$FM" = 000 ]; } && ok "final mode 000 restored" || bad "final frozen mode=$FM"
# N1 regression: LARGE_FILE_CHUNK must not inherit a leaked umask 077 from journal setup.
BIGTYPE="$(sqlite3 "$BRIC_DB" "SELECT type FROM chunks WHERE run_id='$RUN' AND big_rel_path='open/big.bin' LIMIT 1;")"
[ "$BIGTYPE" = LARGE_FILE_CHUNK ] || bad "big.bin did not exercise LARGE_FILE_CHUNK"
BM="$(stat -c '%a' "$DEST/open/big.bin" 2>/dev/null || echo '?')"; [ "$BM" = 644 ] && ok "LARGE_FILE_CHUNK mode remains 644 (no umask leak)" || bad "LARGE_FILE_CHUNK restored mode=$BM expected=644"
chmod u+rwx "$DEST/frozen" "$DEST/frozen/data" 2>/dev/null || true
[ "$(sha256sum "$DEST/frozen/data/file.dat" | awk '{print $1}')" = "$WANT_SHA" ] && ok "payload identical" || bad "payload sha mismatch"
[ "$(find "$ROOT/journal" -name '*.sqlite' 2>/dev/null | wc -l)" -eq 0 ] && ok "journal removed after finalize" || bad "journal left behind"

# D4 regression: readable destination with no catalog digest is NO-DIGEST, not stream-only.
sqlite3 "$BRIC_DB" "UPDATE files SET sha256_plain='' WHERE run_id='$RUN' AND entry_type NOT IN ('D','L');"
DEST2="$ROOT/restored2"
set +e; "$REPO/cluster/scripts/bric-restore.sh" --project acc --dest "$DEST2" --require-destination-verify >"$ROOT/restore2.log" 2>&1; R2=$?; set -e
[ "$R2" -eq 0 ] && ok "strict destination verify accepts readable NO-DIGEST objects" || bad "strict destination verify failed rc=$R2"
grep -q 'NO-DIGEST:' "$ROOT/restore2.log" && ok "NO-DIGEST reported" || bad "NO-DIGEST missing"
grep -q 'VERIFIED-STREAM: .*catalog has no destination digest' "$ROOT/restore2.log" && bad "no-digest misclassified as stream-only" || ok "no-digest not misclassified"
chmod -R u+rwx "$DEST2" 2>/dev/null || true

echo
[ "$fail" -eq 0 ] && echo "ACCEPTANCE PASS" || echo "ACCEPTANCE FAIL"
exit "$fail"
