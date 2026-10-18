#!/bin/bash
. "$(cd "$(dirname "$(readlink -f "$0")")" && pwd)/lib_test_daemon.sh"
# Long-term resilience, three properties in one harness:
#
#  A) QUIESCENCE GUARD  — mutating a source file between plan and production ABORTS the run
#     (signed run.ABORTED, reservation released) instead of writing a mixed-version copy to tape.
#  B) CORRUPTED-TOC FALLBACK — with TWO closes on tape (two TOCs), corrupting the header of the
#     LATEST TOC on every tape must make DR fall back to the previous valid TOC and still recover
#     everything the previous TOC indexes (run1). run2 (only in the corrupted TOC) is expected lost.
#  C) REBUILT-CATALOG CONTINUITY — a catalog rebuilt from the tapes (--verify) is not just
#     equivalent: a NEW daemon on it must serve a NEW APPEND run to CLOSED with NO duplicate
#     segment rows (seg_id format identical), and DR from the tapes must then recover BOTH runs.
set -euo pipefail
export BRIC_CONFIG=none   # hermetic: never read /etc/bric/bric.conf inside tests
REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
ROOT="$(mktemp -d)"
echo "workroot=$ROOT"
fail=0; ok() { echo "  ok: $*"; }; bad() { echo "  FAIL: $*"; fail=1; }

export BRIC_HOME="$REPO/cluster" BRIC_DB="$ROOT/cluster_catalog.db" BRIC_QNAP="$ROOT/qnap/bric"
export BRIC_KEYS="$ROOT/keys" BRIC_SQL_INIT="$REPO/cluster/sql/cluster_init.sql"
export BRIC_USER="vsz652" BRIC_RUN_MODE="local"
export BRIC_RESERVE_TIMEOUT=60 BRIC_DRAIN_TIMEOUT=60 BRIC_CLOSE_TIMEOUT=60 BRIC_POLL=1
export BRIC_TAPE_HOME="$REPO/tape" BRIC_TAPE_DB="$ROOT/tape_catalog.db" BRIC_TAPE_SQL_INIT="$REPO/tape/sql/tape_init.sql"
export BRIC_TAPE_BACKEND="sim" BRIC_TAPELIB="$ROOT/tapelib" BRIC_TAPE_LOCK="$ROOT/tape.lock"

mkdir -p "$BRIC_QNAP" "$BRIC_KEYS" "$BRIC_TAPELIB"
chmod +x "$REPO"/cluster/scripts/*.sh "$REPO"/cluster/bin/bric "$REPO"/tape/bin/bric-tape-daemon 2>/dev/null || true
sqlite3 "$BRIC_DB" < "$BRIC_SQL_INIT" >/dev/null
sqlite3 "$BRIC_TAPE_DB" < "$BRIC_TAPE_SQL_INIT" >/dev/null
sqlite3 "$BRIC_DB" "UPDATE config SET value='4194304' WHERE key='segment_target_bytes';"   # 4 MiB
sqlite3 "$BRIC_TAPE_DB" "UPDATE config SET value='1' WHERE key='poll_seconds';"
head -c 32 /dev/urandom | base64 > "$BRIC_KEYS/${BRIC_USER}_user_key.txt"
head -c 32 /dev/urandom | base64 > "$BRIC_KEYS/master.key"
UK="$ROOT/uk.txt"; cp "$BRIC_KEYS/${BRIC_USER}_user_key.txt" "$UK"
# Barcodes follow the PRODUCTION parity convention (primary_parity=even: even=PRIMARY/onsite,
# BACKUP=PRIMARY+1) so the rebuild's pair derivation reconstructs the same pairs.
pair=1; for n in 0 2; do p=$(printf '%06dL9' "$n"); b=$(printf '%06dL9' "$((n+1))")
  sqlite3 "$BRIC_TAPE_DB" "INSERT INTO tapes(volumetag,slot,role,pair_number,paired_volumetag,capacity_tb,used_tb,status)
    VALUES('$p',$((n+1)),'PRIMARY',$pair,'$b',18,0,'EMPTY'),('$b',$((n+2)),'BACKUP',$pair,'$p',18,0,'EMPTY');"; pair=$((pair+1)); done

daemon_start() { setsid "$REPO/tape/bin/bric-tape-daemon" --loop >>"$ROOT/daemon.log" 2>&1 & DAEMON=$!; sleep 1; }
daemon_stop()  { bric_test_stop_group "$DAEMON"; }
trap 'daemon_stop; [ -n "${KEEP:-}" ] || { rm -rf "$ROOT" 2>/dev/null || { sleep 1; rm -rf "$ROOT"; }; }' EXIT

# ================================ A) quiescence guard =============================================
echo "=== A) quiescence guard: source mutates between plan and production -> run ABORTS ==="
SRCQ="$ROOT/data/mutating"; mkdir -p "$SRCQ"
dd if=/dev/urandom of="$SRCQ/still.dat"  bs=1M count=1 status=none
dd if=/dev/urandom of="$SRCQ/moving.dat" bs=1M count=1 status=none
daemon_start
RUNQ="$("$REPO/cluster/scripts/bric-plan.sh" --project mutating --source "$SRCQ" 2>/dev/null)" || { bad "plan failed"; }
sleep 1.1; echo "drift" >> "$SRCQ/moving.dat"          # mutate AFTER plan, BEFORE production
if "$REPO/cluster/bin/bric" backup --project mutating --source "$SRCQ" >/dev/null 2>&1; then
    : # a second plan would be blocked by one-active-run anyway; we drive chunks by hand below
fi
# produce the planned run's chunks directly (local mode path), expecting the guard to abort
Q_ABORTED=0
for c in $(seq 1 "$(sqlite3 "$BRIC_DB" "SELECT n_chunks FROM runs WHERE run_id='$RUNQ';")"); do
    "$REPO/cluster/scripts/bric-chunk.sh" --run "$RUNQ" --chunk "$c" >/dev/null 2>&1 || Q_ABORTED=1
done
[ "$Q_ABORTED" = 1 ] && ok "chunk production refused (guard tripped)" || bad "no chunk aborted despite source drift"
sqlite3 "$BRIC_DB" "SELECT error FROM chunks WHERE run_id='$RUNQ' AND state='ERROR';" | grep -q "quiescence violation" \
    && ok "chunk marked ERROR with an explicit quiescence-violation message" || bad "no quiescence ERROR recorded"
"$REPO/cluster/scripts/bric-finalize.sh" --run "$RUNQ" >/dev/null 2>&1 && bad "finalize should have failed the run" || true
[ "$(sqlite3 "$BRIC_DB" "SELECT status FROM runs WHERE run_id='$RUNQ';")" = FAILED ] \
    && ok "run FAILED fast (no drain-timeout wait)" || bad "run not FAILED after guard abort"
sleep 2   # let the daemon process run.ABORTED (releases reservation, orphans partials)
[ "$(sqlite3 "$BRIC_TAPE_DB" "SELECT state FROM reservation WHERE run_id='$RUNQ';")" = RELEASED ] \
    && ok "tape reservation RELEASED after abort" || bad "reservation not released"
daemon_stop
sqlite3 "$BRIC_TAPE_DB" "UPDATE tapes SET status='EMPTY', project_name=NULL, owner=NULL WHERE project_name='mutating';"

# ================================ B) + C) two closes, then corruption / rebuild ===================
echo "=== archive run1 (genome) ==="
SRC="$ROOT/data/genome"; mkdir -p "$SRC/raw"
for i in 1 2 3; do dd if=/dev/urandom of="$SRC/raw/r_$i.fastq" bs=1M count=2 status=none; done
dd if=/dev/urandom of="$SRC/raw/huge.bam" bs=1M count=9 status=none    # >4MiB -> LARGE pieces
daemon_start
RUN1="$("$REPO/cluster/bin/bric" backup --project genome --source "$SRC")"
[ "$(sqlite3 "$BRIC_DB" "SELECT status FROM runs WHERE run_id='$RUN1';")" = CLOSED ] && ok "run1 CLOSED" || bad "run1 not closed"

echo "=== archive run2 (APPEND: one new file) ==="
dd if=/dev/urandom of="$SRC/raw/extra.fastq" bs=1M count=2 status=none
RUN2="$("$REPO/cluster/bin/bric" backup --project genome --source "$SRC")"
[ "$(sqlite3 "$BRIC_DB" "SELECT status,kind FROM runs WHERE run_id='$RUN2';")" = "CLOSED|APPEND" ] && ok "run2 CLOSED (APPEND)" || bad "run2 not closed as APPEND"
daemon_stop

# --------- B) corrupted latest TOC -> DR must fall back to the previous valid TOC ---------------
echo "=== B) corrupt the header of the LATEST TOC on every tape ==="
CORR="$ROOT/tapelib_corrupt"; cp -a "$BRIC_TAPELIB" "$CORR"
for vt in "$CORR"/*/; do
    last_toc=""
    for f in $(ls "$vt" | sort); do
        head -c 32 "$vt/$f" 2>/dev/null | grep -q '^# BRIC tape TOC v1' && last_toc="$f"
    done
    [ -n "$last_toc" ] || { bad "no TOC found on $(basename "$vt")"; continue; }
    printf 'XXXXXXXX' | dd of="$vt/$last_toc" bs=1 count=8 conv=notrunc status=none   # kill the magic
done
ok "latest TOC header corrupted on every tape (previous TOC left intact)"
DRB="$ROOT/dr_fallback"
if "$REPO/cluster/scripts/bric-dr-from-tapes.sh" --tapelib "$CORR" --project genome \
     --user-key-file "$UK" --dest "$DRB" --file "raw/r_1.fastq" >"$ROOT/drB.log" 2>&1; then
    [ "$(sha256sum "$DRB/raw/r_1.fastq" | awk '{print $1}')" = "$(sha256sum "$SRC/raw/r_1.fastq" | awk '{print $1}')" ] \
        && ok "DR fell back past the corrupted TOC and recovered a run1 file (bit-identical)" \
        || bad "fallback DR produced wrong content"
else bad "DR did not fall back to the previous TOC (see drB.log)"; fi
# run2's extra.fastq is indexed ONLY by the corrupted TOC: expected UNRECOVERABLE (documented degradation)
if "$REPO/cluster/scripts/bric-dr-from-tapes.sh" --tapelib "$CORR" --project genome \
     --user-key-file "$UK" --dest "$ROOT/dr_fallback2" --file "raw/extra.fastq" >/dev/null 2>&1; then
    ok "run2 file recovered too (older TOC unexpectedly covered it — fine)"
else
    ok "run2 file (only in the corrupted TOC) reported unrecoverable — expected degradation"
fi

# --------- C) rebuild --verify, then a NEW daemon + NEW run on the REBUILT catalog ---------------
echo "=== C) rebuilt-catalog continuity ==="
rm -f "$BRIC_TAPE_DB" "$BRIC_TAPE_DB-wal" "$BRIC_TAPE_DB-shm"
"$REPO/tape/scripts/bric-tape-rebuild-catalog.sh" --out "$BRIC_TAPE_DB" --tapelib "$BRIC_TAPELIB" --verify >"$ROOT/rebuild.log" 2>&1 \
    && ok "tape catalog rebuilt from tapes (--verify)" || bad "rebuild failed"
sqlite3 "$BRIC_TAPE_DB" "UPDATE config SET value='1' WHERE key='poll_seconds';"
daemon_start
dd if=/dev/urandom of="$SRC/raw/postrebuild.fastq" bs=1M count=2 status=none
RUN3="$("$REPO/cluster/bin/bric" backup --project genome --source "$SRC")" || bad "run3 backup failed on rebuilt catalog"
[ "$(sqlite3 "$BRIC_DB" "SELECT status FROM runs WHERE run_id='$RUN3';")" = CLOSED ] \
    && ok "run3 CLOSED on the REBUILT catalog (reservation, drain, close all worked)" || bad "run3 not closed on rebuilt catalog"
daemon_stop
# no duplicate segment rows: one seg_id per (run,chunk,role); rebuilt + new ids share one format
DUP="$(sqlite3 "$BRIC_TAPE_DB" "SELECT COUNT(*) - COUNT(DISTINCT run_id||'|'||chunk_no||'|'||copy_role) FROM segments WHERE state='VERIFIED';")"
[ "$DUP" = 0 ] && ok "no duplicate segment rows after resuming on the rebuilt catalog" || bad "$DUP duplicate segment row(s) — seg_id format divergence?"
# and DR from the tapes recovers the FULL tree including run3's file (cumulative TOC written by the resumed daemon)
DRC="$ROOT/dr_continuity"
"$REPO/cluster/scripts/bric-dr-from-tapes.sh" --tapelib "$BRIC_TAPELIB" --project genome \
    --user-key-file "$UK" --dest "$DRC" >"$ROOT/drC.log" 2>&1 || bad "final DR failed (see drC.log)"
diff -r "$SRC" "$DRC" >/dev/null 2>&1 && ok "final DR tree == source (runs 1+2+3, across original AND rebuilt catalog eras)" \
    || { bad "final DR tree differs"; diff -r "$SRC" "$DRC" 2>/dev/null | head -5; }

echo
[ "$fail" -eq 0 ] && echo "✓ RESILIENCE CONTINUITY CHECKS PASSED" || { echo "✗ RESILIENCE CONTINUITY FAILURES"; exit 1; }
