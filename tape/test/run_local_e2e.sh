#!/bin/bash
. "$(cd "$(dirname "$(readlink -f "$0")")" && pwd)/lib_test_daemon.sh"
# Local end-to-end test for BRIC Archive 2.0.
# Drives the real cluster scripts and the real tape daemon against a local directory standing in
# for the QNAP share and a simulated tape library. Verifies: reservation -> chunk production ->
# tape write+read-back verify -> project close (3 catalog levels) -> restore a file FROM TAPE.
set -euo pipefail
export BRIC_CONFIG=none   # hermetic: never read /etc/bric/bric.conf inside tests
# Exercise production terminal-bus semantics even when run_all_tests.sh exports the
# debugging escape hatch globally. CLOSED runs must not depend on retained QNAP state.
export BRIC_KEEP_TERMINAL_BUS=0
REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
ROOT="$(mktemp -d)"
echo "repo=$REPO"; echo "workroot=$ROOT"

# ---- environment shared by both "servers" (same dir stands in for the NFS export) ----
export BRIC_HOME="$REPO/cluster"
export BRIC_DB="$ROOT/cluster_catalog.db"
export BRIC_QNAP="$ROOT/qnap/bric"
export BRIC_KEYS="$ROOT/keys"
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

# ---- init both catalogs ----
sqlite3 "$BRIC_DB"      < "$BRIC_SQL_INIT"
sqlite3 "$BRIC_TAPE_DB" < "$BRIC_TAPE_SQL_INIT"
# small chunks so the test exercises multi-chunk packing + a large-file split
sqlite3 "$BRIC_DB"      "UPDATE config SET value='5242880' WHERE key='segment_target_bytes';"  # 5 MiB
sqlite3 "$BRIC_TAPE_DB" "UPDATE config SET value='1' WHERE key='poll_seconds';"

# ---- keys ----
head -c 32 /dev/urandom | base64 > "$BRIC_KEYS/${BRIC_USER}_user_key.txt"
head -c 32 /dev/urandom | base64 > "$BRIC_KEYS/master.key"
chmod 600 "$BRIC_KEYS"/*

# ---- register a few simulated tape pairs (role/pair system-assigned; barcodes opaque) ----
pair=1
for n in 1 3 5 7; do
  p=$(printf '%06dL9' "$n"); b=$(printf '%06dL9' "$((n+1))")
  sqlite3 "$BRIC_TAPE_DB" "INSERT INTO tapes (volumetag,slot,role,pair_number,paired_volumetag,capacity_tb,used_tb,status)
     VALUES ('$p',$n,'PRIMARY',$pair,'$b',18.0,0,'EMPTY'),
            ('$b',$((n+1)),'BACKUP',$pair,'$p',18.0,0,'EMPTY');"
  pair=$((pair+1))
done
echo "registered tapes:"; sqlite3 -column "$BRIC_TAPE_DB" "SELECT volumetag,role,pair_number,status FROM tapes ORDER BY slot;"

# ---- test data: several small files (multiple TAR_PART chunks) + one big file (LARGE_FILE_CHUNK x3) ----
SRC="$ROOT/data/mouse_rnaseq"; mkdir -p "$SRC/raw" "$SRC/meta"
for i in 1 2 3 4 5 6; do dd if=/dev/urandom of="$SRC/raw/sample_$i.fastq" bs=1M count=2 status=none; done
for i in 1 2 3; do dd if=/dev/urandom of="$SRC/meta/m_$i.txt" bs=1K count=200 status=none; done
dd if=/dev/urandom of="$SRC/raw/huge.bam" bs=1M count=12 status=none   # > 5 MiB target -> split
mkdir -p "$SRC/intentionally_omitted"
printf 'not part of archive scope\n' > "$SRC/intentionally_omitted/secret.txt"
echo "source tree:"; find "$SRC" -type f -printf '  %P  %s bytes\n' | sort

# ---- start the tape daemon (background poll loop) ----
setsid "$REPO/tape/bin/bric-tape-daemon" --loop &
DAEMON=$!
trap 'bric_test_stop_group "$DAEMON"; [ -n "${KEEP:-}" ] || { rm -rf "$ROOT" 2>/dev/null || { sleep 1; rm -rf "$ROOT"; }; }' EXIT
sleep 1

# ---- run the archive (local mode drives tar stream -> chunks -> finalize -> close inline) ----
echo "=== bric backup ==="
RUN_ID="$("$REPO/cluster/bin/bric" backup --project mouse_rnaseq --source "$SRC" --exclude intentionally_omitted)"
echo "run: $RUN_ID"

echo "=== bric status ==="; "$REPO/cluster/bin/bric" status --project mouse_rnaseq
echo "=== bric list --long ==="; "$REPO/cluster/bin/bric" list --long

# ---- assertions on the archive spine ----
fail=0
chk() { if [ "$2" = "$3" ]; then echo "  ok: $1 ($2)"; else echo "  FAIL: $1 expected=$3 got=$2"; fail=1; fi; }
NCH=$(sqlite3 "$BRIC_DB" "SELECT n_chunks FROM runs WHERE run_id='$RUN_ID';")
DONE=$(sqlite3 "$BRIC_DB" "SELECT COUNT(*) FROM chunks WHERE run_id='$RUN_ID' AND state='DONE';")
chk "all chunks DONE" "$DONE" "$NCH"
VER=$(sqlite3 "$BRIC_TAPE_DB" "SELECT COUNT(*) FROM segments WHERE run_id='$RUN_ID' AND state='VERIFIED';")
chk "segments verified (2x chunks)" "$VER" "$((NCH*2))"
CLOSED=$(sqlite3 "$BRIC_DB" "SELECT status FROM runs WHERE run_id='$RUN_ID';")
chk "run CLOSED" "$CLOSED" "CLOSED"
EXN=$(sqlite3 "$BRIC_DB" "SELECT COUNT(*) FROM run_exclusions WHERE run_id='$RUN_ID' AND rel_path='intentionally_omitted' AND reason='user-declared';")
chk "declared exclusion recorded distinctly as user-declared" "$EXN" "1"
OMIT=$(sqlite3 "$BRIC_DB" "SELECT COUNT(*) FROM files WHERE run_id='$RUN_ID' AND rel_path LIKE 'intentionally_omitted%';")
chk "excluded subtree absent from archived file map" "$OMIT" "0"
"$REPO/cluster/bin/bric" exclusions mouse_rnaseq --run "$RUN_ID" > "$ROOT/exclusions.out"
grep -q 'intentionally_omitted' "$ROOT/exclusions.out" && echo "  ok: bric exclusions reports declared scope" || { echo "  FAIL: bric exclusions output"; fail=1; }
TAPES=$(sqlite3 "$BRIC_DB" "SELECT COUNT(*) FROM project_tapes WHERE project_name='mouse_rnaseq';")
[ "$TAPES" -ge 1 ] && echo "  ok: project_tapes populated ($TAPES)" || { echo "  FAIL: no project_tapes"; fail=1; }
# QNAP blobs freed after DONE
LEFT=$(find "$BRIC_QNAP" -name 'chunk_*.enc' | wc -l | tr -d ' ')
chk "QNAP blobs freed" "$LEFT" "0"
# Close artifacts are durable on tape. The QNAP run directory is transport state and must
# disappear after the signed CLOSED receipt has been committed. The tape daemon replicates every
# signed close artifact to every tape already belonging to this project, then writes/verifies a TOC.
PROJECT_VOLUMES=$(sqlite3 "$BRIC_TAPE_DB" "SELECT COUNT(DISTINCT volumetag) FROM segments WHERE project_name='mouse_rnaseq';")
CATS=$(sqlite3 "$BRIC_TAPE_DB" "SELECT COUNT(*) FROM tape_artifacts WHERE run_id='$RUN_ID' AND filename='catalog_project.enc' AND kind='CATALOG' AND state='VERIFIED';")
chk "project catalog VERIFIED on every project tape" "$CATS" "$PROJECT_VOLUMES"
TOCS=$(sqlite3 "$BRIC_TAPE_DB" "SELECT COUNT(*) FROM tape_artifacts WHERE run_id='$RUN_ID' AND filename='TAPE_TOC.txt' AND kind='TOC' AND state='VERIFIED';")
chk "final TOC VERIFIED on every project tape" "$TOCS" "$PROJECT_VOLUMES"
RUN_BUS="$BRIC_QNAP/archive/mouse_rnaseq/$RUN_ID"
BUS_LEFT=0; [ ! -e "$RUN_BUS" ] || BUS_LEFT=1
chk "terminal QNAP run directory cleaned" "$BUS_LEFT" "0"

# ---- restore a single file FROM TAPE (read sim tape -> decrypt -> tar -x -> compare) ----
echo "=== restore-from-tape check ==="
# pick the TAR_PART chunk holding meta/m_1.txt, find its PRIMARY placement, read the tape file, decrypt
REL="meta/m_1.txt"
CNO=$(sqlite3 "$BRIC_DB" "SELECT chunk_no FROM files WHERE run_id='$RUN_ID' AND rel_path='$REL';")
read -r PVT PFN <<EOF2
$(sqlite3 -separator ' ' "$BRIC_TAPE_DB" "SELECT volumetag,file_number FROM segments WHERE run_id='$RUN_ID' AND chunk_no=$CNO AND copy_role='PRIMARY';")
EOF2
echo "  $REL is in chunk $CNO, PRIMARY $PVT file #$PFN"
ENCK=$(printf '%s:encryption' "$(cat "$BRIC_KEYS/${BRIC_USER}_user_key.txt")" | sha256sum | awk '{print $1}')
printf '%s' "$ENCK" > "$ROOT/p"; chmod 600 "$ROOT/p"
OUT="$ROOT/restore"; mkdir -p "$OUT"
cp "$BRIC_TAPELIB/$PVT/$(printf 'f_%06d' "$PFN")" "$ROOT/blob.enc"
openssl enc -d -aes-256-cbc -pbkdf2 -pass file:"$ROOT/p" -in "$ROOT/blob.enc" | tar -C "$OUT" -xpf -
if cmp -s "$SRC/$REL" "$OUT/$REL"; then echo "  ok: $REL restored from tape matches original"; else echo "  FAIL: $REL mismatch"; fail=1; fi

# ---- restore the big split file: concatenate its LARGE_FILE_CHUNK pieces from tape ----
# chunk->piece order lives in the CLUSTER catalog; chunk->tape/file lives in the TAPE catalog.
# Two separate DBs by design, so cross them explicitly (the same mapping is embedded into the
# user-key-encrypted on-tape catalog as a 'placement' table at project close).
BIG="raw/huge.bam"
CHUNK_NOS=$(sqlite3 "$BRIC_DB" "SELECT chunk_no FROM chunks WHERE run_id='$RUN_ID' AND big_rel_path='$BIG' ORDER BY chunk_index;")
: > "$ROOT/huge.restored"
for cno in $CHUNK_NOS; do
  read -r vt fn <<<"$(sqlite3 -separator ' ' "$BRIC_TAPE_DB" "SELECT volumetag,file_number FROM segments WHERE run_id='$RUN_ID' AND chunk_no=$cno AND copy_role='PRIMARY';")"
  openssl enc -d -aes-256-cbc -pbkdf2 -pass file:"$ROOT/p" -in "$BRIC_TAPELIB/$vt/$(printf 'f_%06d' "$fn")" >> "$ROOT/huge.restored"
done
if cmp -s "$SRC/$BIG" "$ROOT/huge.restored"; then echo "  ok: $BIG (split) restored from tape matches original"; else echo "  FAIL: $BIG mismatch"; fail=1; fi

echo "=== scripted restore via reverse bus (bric restore) ==="
S1="$ROOT/sr_single"
"$REPO/cluster/bin/bric" restore --project mouse_rnaseq --file meta/m_1.txt --dest "$S1" >&2
cmp -s "$SRC/meta/m_1.txt" "$S1/mouse_rnaseq/meta/m_1.txt" && echo "  ok: scripted single-file restore matches" || { echo "  FAIL: scripted single-file"; fail=1; }
S2="$ROOT/sr_big"
"$REPO/cluster/bin/bric" restore --project mouse_rnaseq --file raw/huge.bam --dest "$S2" >&2
cmp -s "$SRC/raw/huge.bam" "$S2/mouse_rnaseq/raw/huge.bam" && echo "  ok: scripted split-file restore matches" || { echo "  FAIL: scripted split-file"; fail=1; }
S3="$ROOT/sr_full"
"$REPO/cluster/bin/bric" restore --project mouse_rnaseq --dest "$S3" >&2
[ ! -e "$S3/intentionally_omitted" ] && echo "  ok: excluded subtree is absent from full restore" || { echo "  FAIL: excluded subtree restored"; fail=1; }
DIFF=$(diff -r --exclude=intentionally_omitted "$SRC" "$S3" 2>&1 | wc -l | tr -d ' ')
[ "$DIFF" = 0 ] && echo "  ok: scripted whole-run restore matches included source scope" || { echo "  FAIL: whole-run diff ($DIFF lines)"; fail=1; }

echo
[ "$fail" -eq 0 ] && echo "✓ ALL E2E CHECKS PASSED" || { echo "✗ E2E FAILURES"; exit 1; }
