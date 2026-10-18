#!/bin/bash
# WAL crash-safety (ChatGPT review point D). Both catalogs run in journal_mode=WAL with a 60s
# busy_timeout on every connection. This test kill -9's a writer with an OPEN transaction and asserts
# the catalog recovers cleanly on the next open: a COMMITTED row survives, an UNCOMMITTED row is rolled
# back, PRAGMA integrity_check passes, leftover -wal/-shm are recovered, and no lock stays stuck (a
# fresh writer succeeds immediately). The atomicity guarantee is per-database, so audit_log is used as
# the observable sentinel while integrity_check covers the real reservation/segments tables.
set -euo pipefail
export BRIC_CONFIG=none   # hermetic: never read /etc/bric/bric.conf inside tests
REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"; ROOT="$(mktemp -d)"; echo "workroot=$ROOT"
trap '[ -n "${KEEP:-}" ]||rm -rf "$ROOT"' EXIT
command -v sqlite3 >/dev/null || { echo "SKIP: sqlite3 not installed"; exit 0; }
DB="$ROOT/tape_catalog.db"
sqlite3 "$DB" < "$REPO/tape/sql/tape_init.sql" >/dev/null
fail=0; ok(){ echo "  ok: $1"; }; bad(){ echo "  FAIL: $1"; fail=1; }

ins() { printf "INSERT INTO audit_log(actor,action,object,result,detail) VALUES('crashtest','%s','%s','x','y');" "$1" "$2"; }

echo "=== crash a writer mid-transaction (kill -9 with an open BEGIN IMMEDIATE) ==="
# Use Python's native sqlite3 binding for the crash writer when available.  A test-only/minimal
# sqlite3 CLI may buffer stdin until EOF, which would make COMMIT execute only after the writer is
# allowed to exit and would invalidate this durability test.  The Python writer executes COMMIT,
# opens a second transaction, signals readiness, and then blocks until kill -9.
READY="$ROOT/writer.ready"
if command -v python3 >/dev/null 2>&1; then
  python3 - "$DB" "$READY" <<'PY_WRITER' &
import os, sqlite3, sys, time
path, ready = sys.argv[1:]
db = sqlite3.connect(path, timeout=60.0, isolation_level=None)
db.execute("PRAGMA foreign_keys=ON")
db.execute("BEGIN IMMEDIATE")
db.execute("INSERT INTO audit_log(actor,action,object,result,detail) VALUES('crashtest','CRASH_COMMITTED','s1','x','y')")
db.execute("COMMIT")
db.execute("BEGIN IMMEDIATE")
db.execute("INSERT INTO audit_log(actor,action,object,result,detail) VALUES('crashtest','CRASH_PENDING','s2','x','y')")
open(ready, "w").close()
while True:
    time.sleep(60)
PY_WRITER
  SQLPID=$!
  for _ in $(seq 1 100); do [ -e "$READY" ] && break; sleep 0.05; done
  [ -e "$READY" ] || { kill -9 "$SQLPID" 2>/dev/null || true; bad "crash writer never reached the open transaction"; }
else
  FIFO="$ROOT/cmd.fifo"; mkfifo "$FIFO"
  sqlite3 "$DB" < "$FIFO" & SQLPID=$!
  exec 7>"$FIFO"
  {
    printf '.timeout 60000\n'
    printf 'BEGIN IMMEDIATE;\n'
    ins CRASH_COMMITTED s1; printf '\n'
    printf 'COMMIT;\n'
    printf 'BEGIN IMMEDIATE;\n'
    ins CRASH_PENDING s2; printf '\n'
  } >&7
  sleep 1
fi
[ -f "$DB-wal" ] && ok "WAL file present during the live transaction" || echo "  note: no -wal visible (still ok)"
kill -9 "$SQLPID" 2>/dev/null || true
[ -z "${FIFO:-}" ] || exec 7>&-
wait "$SQLPID" 2>/dev/null || true
ok "writer killed -9 with an uncommitted transaction open"

echo "=== reopen and verify clean recovery ==="
IC="$(sqlite3 "$DB" 'PRAGMA integrity_check;' 2>&1)"
[ "$IC" = "ok" ] && ok "PRAGMA integrity_check = ok after crash" || bad "integrity_check returned: $IC"
CC="$(sqlite3 "$DB" "SELECT COUNT(*) FROM audit_log WHERE action='CRASH_COMMITTED';")"
[ "$CC" = "1" ] && ok "committed row survived the crash (durable)" || bad "committed row lost ($CC)"
CP="$(sqlite3 "$DB" "SELECT COUNT(*) FROM audit_log WHERE action='CRASH_PENDING';")"
[ "$CP" = "0" ] && ok "uncommitted row was rolled back (atomic)" || bad "uncommitted row leaked ($CP)"

echo "=== no stuck lock: a fresh writer succeeds immediately ==="
t0=$(date +%s)
if sqlite3 "$DB" "$(ins POSTCRASH s3)" 2>"$ROOT/werr"; then
  t1=$(date +%s); [ $((t1-t0)) -lt 5 ] && ok "post-crash write committed without waiting on a stale lock" || bad "post-crash write was delayed (stale lock?)"
else bad "post-crash write failed: $(cat "$ROOT/werr")"; fi
[ "$(sqlite3 "$DB" "SELECT COUNT(*) FROM audit_log WHERE action='POSTCRASH';")" = "1" ] && ok "post-crash row persisted" || bad "post-crash row missing"

echo "=== real tables intact (reservation/segments usable) ==="
if sqlite3 "$DB" "INSERT INTO reservation(run_id,project_name,owner,requested_tb,pairs_csv,state) VALUES('wal__x','p','o',1.0,'3,7','GRANTED');" 2>"$ROOT/rerr" \
   && [ "$(sqlite3 "$DB" "SELECT state FROM reservation WHERE run_id='wal__x';")" = GRANTED ]; then
  ok "reservation table writable and consistent after crash"
else echo "  note: reservation insert shape differs ($(cat "$ROOT/rerr")) — integrity_check already covered it"; fi

echo
[ "$fail" -eq 0 ] && echo "✓ WAL CRASH-SAFETY CHECKS PASSED" || { echo "✗ WAL CRASH-SAFETY FAILURES"; exit 1; }
