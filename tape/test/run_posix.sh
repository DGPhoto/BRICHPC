#!/bin/bash
. "$(cd "$(dirname "$(readlink -f "$0")")" && pwd)/lib_test_daemon.sh"
# POSIX fidelity + NUL-safety + sliding-window test for BRIC Archive 2.0 (Batch 2).
# Asserts the archive now preserves the real tree, not just regular files:
#   - empty directories survive a round trip
#   - directory permissions are preserved (applied last, after files are placed)
#   - symlinks are stored as links (relative and absolute), never dereferenced
#   - file names with spaces and NEWLINES round-trip (NUL-safe member lists + tar --null)
#   - FIFOs/sockets/devices are skipped with a warning (not silently lost)
# Plus free-on-DONE: the tape daemon frees each QNAP blob right after it is VERIFIED on tape,
# so blobs do not accumulate until finalize (the basis of the sliding window).
set -euo pipefail
export BRIC_CONFIG=none   # hermetic: never read /etc/bric/bric.conf inside tests
REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
ROOT="$(mktemp -d)"
echo "repo=$REPO"; echo "workroot=$ROOT"

export BRIC_HOME="$REPO/cluster"
export BRIC_DB="$ROOT/cluster_catalog.db"
export BRIC_QNAP="$ROOT/qnap/bric"
export BRIC_KEYS="$ROOT/keys"
export BRIC_RUNSTATE="$ROOT/runstate"
export BRIC_SQL_INIT="$REPO/cluster/sql/cluster_init.sql"
export BRIC_USER="vsz652"
export BRIC_RUN_MODE="local"
export BRIC_RESERVE_TIMEOUT=60 BRIC_DRAIN_TIMEOUT=120 BRIC_CLOSE_TIMEOUT=120 BRIC_POLL=1
export BRIC_TAPE_HOME="$REPO/tape"
export BRIC_TAPE_DB="$ROOT/tape_catalog.db"
export BRIC_TAPE_SQL_INIT="$REPO/tape/sql/tape_init.sql"
export BRIC_TAPE_BACKEND="sim"
export BRIC_TAPELIB="$ROOT/tapelib"
export BRIC_TAPE_LOCK="$ROOT/tape.lock"

mkdir -p "$BRIC_QNAP" "$BRIC_KEYS" "$BRIC_TAPELIB" "$(dirname "$BRIC_DB")"
chmod +x "$REPO"/cluster/scripts/*.sh "$REPO"/cluster/bin/bric "$REPO"/tape/bin/bric-tape-daemon 2>/dev/null || true
sqlite3 "$BRIC_DB"      < "$BRIC_SQL_INIT"      >/dev/null
sqlite3 "$BRIC_TAPE_DB" < "$BRIC_TAPE_SQL_INIT" >/dev/null
sqlite3 "$BRIC_DB"      "UPDATE config SET value='5242880' WHERE key='segment_target_bytes';"
sqlite3 "$BRIC_DB"      "UPDATE config SET value='3' WHERE key='max_inflight_chunks';"
sqlite3 "$BRIC_TAPE_DB" "UPDATE config SET value='1' WHERE key='poll_seconds';"
head -c 32 /dev/urandom | base64 > "$BRIC_KEYS/${BRIC_USER}_user_key.txt"
head -c 32 /dev/urandom | base64 > "$BRIC_KEYS/master.key"; chmod 600 "$BRIC_KEYS"/*
pair=1; for n in 1 3 5 7; do p=$(printf '%06dL9' "$n"); b=$(printf '%06dL9' "$((n+1))")
  sqlite3 "$BRIC_TAPE_DB" "INSERT INTO tapes (volumetag,slot,role,pair_number,paired_volumetag,capacity_tb,used_tb,status) VALUES ('$p',$n,'PRIMARY',$pair,'$b',18.0,0,'EMPTY'),('$b',$((n+1)),'BACKUP',$pair,'$p',18.0,0,'EMPTY');"; pair=$((pair+1)); done

fail=0; ok(){ echo "  ok: $1"; }; bad(){ echo "  FAIL: $1"; fail=1; }

# ---------------------------------------------------------------------------
# a rich POSIX tree
# ---------------------------------------------------------------------------
SRC="$ROOT/data/posixproj"; mkdir -p "$SRC/raw" "$SRC/meta"
for i in 1 2 3; do dd if=/dev/urandom of="$SRC/meta/m_$i.txt" bs=1K count=300 status=none; done
dd if=/dev/urandom of="$SRC/raw/r_1.fastq" bs=1K count=800 status=none
mkdir -p "$SRC/empty_dir"                              # empty directory
mkdir -p "$SRC/restricted"; echo "secret" > "$SRC/restricted/secret.txt"; chmod 0500 "$SRC/restricted"  # read-only dir perms
ln -s "meta/m_1.txt" "$SRC/link_rel"                  # relative symlink within tree
ln -s "/etc/hostname" "$SRC/link_abs"                 # absolute symlink (may dangle on restore)
echo "spaced content" > "$SRC/a file with spaces.txt" # space in name
NL_NAME=$'weird\nname.txt'; echo "newline content" > "$SRC/$NL_NAME"  # NEWLINE in name (hostile)
mkfifo "$SRC/a_fifo"                                   # special file -> must be skipped+warned

echo "source tree:"; find "$SRC" -printf '  %y %p\n' | sort | sed "s#$SRC/#  #"

# ---------------------------------------------------------------------------
# archive (full close); capture output to inspect the special-file warning
# ---------------------------------------------------------------------------
setsid "$REPO/tape/bin/bric-tape-daemon" --loop & DAEMON=$!
trap 'bric_test_stop_group "$DAEMON"; [ -n "${KEEP:-}" ] || { chmod -R u+w "$ROOT" 2>/dev/null || true; rm -rf "$ROOT" 2>/dev/null || { sleep 1; rm -rf "$ROOT"; }; }' EXIT
sleep 1
echo "=== bric backup ==="
BK_OUT="$ROOT/backup.out"
"$REPO/cluster/bin/bric" backup --project posixproj --source "$SRC" >"$ROOT/run_id.txt" 2>"$BK_OUT"
RUN_ID="$(cat "$ROOT/run_id.txt")"; echo "run: $RUN_ID"
CLOSED=$(sqlite3 "$BRIC_DB" "SELECT status FROM runs WHERE run_id='$RUN_ID';")
[ "$CLOSED" = CLOSED ] && ok "run CLOSED" || bad "run not closed ($CLOSED)"

grep -Eqi "skipped unsupported tar member|skipped [0-9]+ unsupported special tar member" "$BK_OUT" \
  && ok "streaming archiver warned about the FIFO (special file skipped)" \
  || bad "no special-file warning in backup output"
# the fifo must not be catalogued as a file/dir/symlink
NF=$(sqlite3 "$BRIC_DB" "SELECT COUNT(*) FROM files WHERE run_id='$RUN_ID' AND rel_path='a_fifo';")
[ "$NF" = 0 ] && ok "FIFO not catalogued" || bad "FIFO leaked into catalog"
# entry_type breakdown
echo "  catalog entry types:"; sqlite3 -separator ' x' "$BRIC_DB" "SELECT entry_type,COUNT(*) FROM files WHERE run_id='$RUN_ID' GROUP BY entry_type;" | sed 's/^/    /'

# ---------------------------------------------------------------------------
# whole-run restore + fidelity assertions
# ---------------------------------------------------------------------------
echo "=== restore whole run ==="
DEST="$ROOT/restore"
"$REPO/cluster/bin/bric" restore --project posixproj --dest "$DEST" >&2

# regular files
for rel in meta/m_1.txt meta/m_2.txt meta/m_3.txt raw/r_1.fastq "restricted/secret.txt" "a file with spaces.txt"; do
  if cmp -s "$SRC/$rel" "$DEST/$rel"; then ok "regular file matches: $rel"; else bad "content mismatch: $rel"; fi
done
# newline-named file
if cmp -s "$SRC/$NL_NAME" "$DEST/$NL_NAME"; then ok "newline-in-name file round-tripped"; else bad "newline-named file not restored correctly"; fi
# empty directory
[ -d "$DEST/empty_dir" ] && ok "empty directory restored" || bad "empty directory missing"
# directory permissions preserved (0500), applied after the file was placed inside
MODE=$(stat -c '%a' "$DEST/restricted" 2>/dev/null || echo "?")
[ "$MODE" = "500" ] && ok "directory perms preserved (restricted = 0500)" || bad "directory perms not preserved (got $MODE)"
# symlinks stored as links (not dereferenced)
if [ -L "$DEST/link_rel" ]; then ok "relative symlink restored as a link"; else bad "link_rel not a symlink"; fi
[ "$(readlink "$DEST/link_rel" 2>/dev/null)" = "meta/m_1.txt" ] && ok "relative symlink target correct" || bad "link_rel wrong target"
if [ -L "$DEST/link_abs" ]; then ok "absolute symlink restored as a link"; else bad "link_abs not a symlink"; fi
[ "$(readlink "$DEST/link_abs" 2>/dev/null)" = "/etc/hostname" ] && ok "absolute symlink target preserved" || bad "link_abs wrong target"
# the FIFO must NOT have been recreated
[ ! -e "$DEST/a_fifo" ] && ok "FIFO correctly absent from restore" || bad "FIFO unexpectedly present in restore"

# ---------------------------------------------------------------------------
# free-on-DONE: drive chunks manually and confirm the daemon frees each blob
# BEFORE finalize runs (isolates the sliding-window reclamation from finalize).
# ---------------------------------------------------------------------------
echo "=== free-on-DONE (daemon frees blobs at DONE, not at finalize) ==="
SRC2="$ROOT/data/fod"; mkdir -p "$SRC2"
for i in $(seq 1 20); do dd if=/dev/urandom of="$SRC2/f_$i.dat" bs=1K count=900 status=none; done
dd if=/dev/urandom of="$SRC2/setgid-large.bin" bs=1M count=6 status=none; chmod 2755 "$SRC2/setgid-large.bin"
RID2="$("$REPO/cluster/scripts/bric-plan.sh" --project fodproj --source "$SRC2" 2>>"$ROOT/plan2.err")"
N2=$(sqlite3 "$BRIC_DB" "SELECT n_chunks FROM runs WHERE run_id='$RID2';")
echo "  planned $N2 chunk(s)"
sqlite3 "$BRIC_DB" "UPDATE runs SET status='PRODUCING' WHERE run_id='$RID2';"
for c in $(seq 1 "$N2"); do "$REPO/cluster/scripts/bric-chunk.sh" --run "$RID2" --chunk "$c" >&2; done
RDIR2="$BRIC_QNAP/archive/fodproj/$RID2"
# wait until all chunks reached DONE (daemon)
t=0; while [ "$(find "$RDIR2" -name 'chunk_*.DONE' 2>/dev/null | wc -l | tr -d ' ')" -lt "$N2" ] && [ "$t" -lt 60 ]; do sleep 1; t=$((t+1)); done
DONES=$(find "$RDIR2" -name 'chunk_*.DONE' 2>/dev/null | wc -l | tr -d ' ')
LEFT=$(find "$RDIR2" -name 'chunk_*.enc' 2>/dev/null | wc -l | tr -d ' ')
[ "$DONES" = "$N2" ] && ok "all $N2 chunks reached DONE" || bad "only $DONES/$N2 reached DONE"
[ "$LEFT" = 0 ] && ok "daemon freed every blob at DONE (0 left) BEFORE finalize" || bad "$LEFT blob(s) still on QNAP after DONE"
grep -q '%' "$REPO/cluster/bin/bric" && ok "dispatcher wires the sliding-window array (1-N%max_inflight)" || bad "sliding-window not wired in dispatcher"
# leave fodproj catalog tidy and prove the serial planner/chunker applies the regular-file special-bit policy.
if "$REPO/cluster/scripts/bric-finalize.sh" --run "$RID2" >&2 && "$REPO/cluster/scripts/bric-close.sh" --run "$RID2" >&2; then
  FODDEST="$ROOT/fod-restore"
  "$REPO/cluster/bin/bric" restore --project fodproj --dest "$FODDEST" >&2 || bad "serial planner/chunker restore failed"
  [ "$(stat -c %a "$FODDEST/setgid-large.bin" 2>/dev/null || echo '?')" = 755 ] \
    && ok "serial planner LARGE_FILE_CHUNK clears setgid (2755 -> 0755)" \
    || bad "serial planner large setgid policy mismatch"
else
  bad "serial planner/chunker finalize/close failed"
fi

echo "=== a bus free that FAILS must be loud, never silent ==="
# Regression for the LAST silent failure on the bus: freeing used to be
# `rm -f ... 2>/dev/null || true`, so on a bus shared between two hosts a permission problem left
# ~segment-sized blobs on the QNAP while every log line still said DONE — the staging area filled
# up with no diagnosis anywhere. The helper must now WARN, and must still never fail the daemon.
FB="$ROOT/freetest"; mkdir -p "$FB/rundir"
{ echo 'log() { printf "[test] %s\n" "$*" >&2; }'
  awk '/^_free_bus_blob\(\)/,/^\}/' "$REPO/tape/bin/bric-tape-daemon"
  echo '_free_bus_blob "$1" "$2" "$3" someRun 1'
} > "$FB/probe.sh"
grep -q "_free_bus_blob()" "$FB/probe.sh" && ok "helper extracted from the daemon (single implementation)" || bad "helper not found in the daemon"

# An undeletable blob, deterministically and for ANY user (root included): a non-empty DIRECTORY in
# the blob's place. `rm -f` cannot remove it, so the helper sees the blob survive — the very code
# path a permission failure takes on the real bus, without depending on DAC or on runuser.
mkdir -p "$FB/rundir/chunk_0001.enc/stuck"
RC=0; OUT="$(bash "$FB/probe.sh" "$FB/rundir/chunk_0001.enc" "$FB/rundir" chunk_0001 2>&1)" || RC=$?
[ "$RC" = 0 ] && ok "a failed free does NOT fail the daemon (rc=0 under set -e)" || bad "failed free returned rc=$RC — would abort the daemon"
echo "$OUT" | grep -q "WARNING: could not free bus blob" && ok "a failed free is LOUD (warning emitted)" || bad "failed free was silent: [$OUT]"
echo "$OUT" | grep -q "will NOT drain" && ok "the warning names the consequence (bus will not drain)" || bad "warning lacks the consequence"
rm -rf "$FB/rundir/chunk_0001.enc"

# happy path: blob AND sidecars removed, nothing logged
head -c 1024 /dev/urandom > "$FB/rundir/chunk_0001.enc"
: > "$FB/rundir/chunk_0001.enc.sha256"; : > "$FB/rundir/chunk_0001.enc.hmac"
RC=0; OUT2="$(bash "$FB/probe.sh" "$FB/rundir/chunk_0001.enc" "$FB/rundir" chunk_0001 2>&1)" || RC=$?
[ ! -e "$FB/rundir/chunk_0001.enc" ] && ok "happy path: blob freed" || bad "blob not removed on the happy path"
[ ! -e "$FB/rundir/chunk_0001.enc.sha256" ] && ok "happy path: sidecars freed too" || bad "sidecars left behind"
[ -z "$OUT2" ] && ok "happy path stays quiet (no spurious warning)" || bad "happy path emitted: [$OUT2]"

echo
[ "$fail" -eq 0 ] && echo "✓ ALL POSIX/NUL/SLIDING-WINDOW CHECKS PASSED" || { echo "✗ POSIX FAILURES"; exit 1; }
