#!/bin/bash
. "$(cd "$(dirname "$(readlink -f "$0")")" && pwd)/lib_test_daemon.sh"
# Review 32B2: progressive reverse-bus restore contract.
# Proves per-chunk READY->CONSUMED backpressure, inline tape-read SHA verification,
# bounded staging cleanup, whole-tree exactness, and terminal progress receipt.
set -euo pipefail
export BRIC_CONFIG=none
REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
ROOT="$(mktemp -d)"; echo "workroot=$ROOT"
fail=0; ok(){ echo "  ok: $*"; }; bad(){ echo "  FAIL: $*"; fail=1; }

export BRIC_HOME="$REPO/cluster" BRIC_DB="$ROOT/cluster.db" BRIC_QNAP="$ROOT/qnap/bric"
export BRIC_KEYS="$ROOT/keys" BRIC_SQL_INIT="$REPO/cluster/sql/cluster_init.sql"
export BRIC_USER="vsz652" BRIC_RUN_MODE=local BRIC_POLL=1
export BRIC_RESERVE_TIMEOUT=60 BRIC_DRAIN_TIMEOUT=90 BRIC_CLOSE_TIMEOUT=90 BRIC_RESTORE_TIMEOUT=60
export BRIC_KEEP_RESTORE_BUS=1
export BRIC_TAPE_HOME="$REPO/tape" BRIC_TAPE_DB="$ROOT/tape.db" BRIC_TAPE_SQL_INIT="$REPO/tape/sql/tape_init.sql"
export BRIC_TAPE_BACKEND=sim BRIC_TAPELIB="$ROOT/tapelib" BRIC_TAPE_LOCK="$ROOT/tape.lock"
export BRIC_RESTORE_PROGRESS_INTERVAL=1 BRIC_RESTORE_CONSUME_TIMEOUT=60
export BRIC_LOG_DIR="$ROOT/log/primary" BRIC_LOG_FALLBACK_DIR="$ROOT/log/fallback" BRIC_REQUIRE_LOGGING=1
mkdir -p "$BRIC_QNAP" "$BRIC_KEYS" "$BRIC_TAPELIB" "$BRIC_LOG_DIR" "$BRIC_LOG_FALLBACK_DIR"
sqlite3 "$BRIC_DB" < "$BRIC_SQL_INIT" >/dev/null
sqlite3 "$BRIC_TAPE_DB" < "$BRIC_TAPE_SQL_INIT" >/dev/null
sqlite3 "$BRIC_DB" "UPDATE config SET value='4194304' WHERE key='segment_target_bytes';"
sqlite3 "$BRIC_TAPE_DB" "UPDATE config SET value='1' WHERE key='poll_seconds';"
head -c 32 /dev/urandom | base64 > "$BRIC_KEYS/${BRIC_USER}_user_key.txt"
head -c 32 /dev/urandom | base64 > "$BRIC_KEYS/master.key"
sqlite3 "$BRIC_TAPE_DB" "INSERT INTO tapes(volumetag,slot,role,pair_number,paired_volumetag,capacity_tb,used_tb,status)
 VALUES('000090L9',1,'PRIMARY',1,'000091L9',18,0,'EMPTY'),('000091L9',2,'BACKUP',1,'000090L9',18,0,'EMPTY');"

SRC="$ROOT/src"; mkdir -p "$SRC/a" "$SRC/b"
dd if=/dev/urandom of="$SRC/a/one.bin" bs=1M count=3 status=none
dd if=/dev/urandom of="$SRC/a/two.bin" bs=1M count=3 status=none
dd if=/dev/urandom of="$SRC/b/large.bin" bs=1M count=11 status=none

setsid "$REPO/tape/bin/bric-tape-daemon" --loop >"$ROOT/daemon.log" 2>&1 & DAEMON=$!
trap 'bric_test_stop_group "$DAEMON"; [ -n "${KEEP:-}" ] || { rm -rf "$ROOT" 2>/dev/null || { sleep 1; rm -rf "$ROOT"; }; }' EXIT
sleep 1
RUN="$("$REPO/cluster/bin/bric" backup --project progressive --source "$SRC")"
[ "$(sqlite3 "$BRIC_DB" "SELECT status FROM runs WHERE run_id='$RUN';")" = CLOSED ] && ok "source run CLOSED" || bad "source run not CLOSED"
NCH="$(sqlite3 "$BRIC_DB" "SELECT COUNT(*) FROM chunks WHERE run_id='$RUN';")"
[ "$NCH" -ge 3 ] && ok "fixture spans multiple chunks ($NCH)" || bad "fixture did not create enough chunks ($NCH)"

DEST="$ROOT/restore"
if "$REPO/cluster/scripts/bric-restore.sh" --project progressive --dest "$DEST" >"$ROOT/restore.log" 2>&1 \
   && diff -r "$SRC" "$DEST" >/dev/null 2>&1; then
    ok "progressive whole-run restore is exact"
else
    bad "progressive restore failed/mismatched"; tail -30 "$ROOT/restore.log" || true
fi
RDIR="$(find "$BRIC_QNAP/restore/progressive" -mindepth 1 -maxdepth 1 -type d | head -1)"
[ -n "$RDIR" ] || { bad "retained restore request directory missing"; exit 1; }
grep -q '^protocol=restore-progressive-v1$' "$RDIR/request" && ok "request advertises progressive-v1" || bad "progressive protocol missing"
[ -f "$RDIR/request.STAGED" ] && ok "terminal request.STAGED published" || bad "request.STAGED missing"
[ -f "$RDIR/request.PROGRESS" ] && grep -q '^state=DONE$' "$RDIR/request.PROGRESS" \
    && ok "signed progress reached DONE" || bad "terminal progress marker missing/not DONE"
CONSUMED="$(find "$RDIR" -maxdepth 1 -type f -name 'staged_*.CONSUMED' | wc -l | tr -d ' ')"
[ "$CONSUMED" = "$NCH" ] && ok "every chunk acknowledged CONSUMED ($CONSUMED/$NCH)" || bad "CONSUMED count $CONSUMED expected $NCH"
LEFT="$(find "$RDIR" -maxdepth 1 -type f \( -name 'staged_*.enc' -o -name 'staged_*.enc.part' \) | wc -l | tr -d ' ')"
[ "$LEFT" = 0 ] && ok "no staged ciphertext remains after per-chunk consumption" || bad "$LEFT staged ciphertext file(s) remain"
grep -Rq 'inline_sha256=yes' "$BRIC_LOG_DIR/events" "$BRIC_LOG_FALLBACK_DIR/events" 2>/dev/null && ok "daemon used inline tape-read sha256" || bad "inline sha256 evidence absent"
grep -q 'consumed and released chunk' "$ROOT/restore.log" && ok "cluster log exposes per-chunk consumption" || bad "per-chunk restore log absent"
if grep -Fq 'sha256sum "$rdir/staged_$cb.enc.part"' "$REPO/tape/bin/bric-tape-daemon"; then
    bad "legacy second-pass QNAP sha256 still present"
else
    ok "legacy second-pass QNAP sha256 removed"
fi

echo
[ "$fail" -eq 0 ] && echo "✓ PROGRESSIVE RESTORE CHECKS PASSED" || { echo "✗ PROGRESSIVE RESTORE FAILURES"; exit 1; }
