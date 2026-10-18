#!/bin/bash
. "$(cd "$(dirname "$(readlink -f "$0")")" && pwd)/lib_test_daemon.sh"
# require_bus_signing hardening (Gemini #1): when the catalog sets require_bus_signing=1, both sides
# must REFUSE to operate unsigned instead of silently degrading. Asserts:
#   - daemon refuses to start with the flag set but no keys; starts (MANDATORY) with keys;
#   - cluster refuses to plan/publish with the flag set but no keys.
set -euo pipefail
export BRIC_CONFIG=none   # hermetic: never read /etc/bric/bric.conf inside tests
REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"; ROOT="$(mktemp -d)"; echo "workroot=$ROOT"
export BRIC_HOME="$REPO/cluster" BRIC_DB="$ROOT/cluster_catalog.db" BRIC_QNAP="$ROOT/qnap/bric"
export BRIC_KEYS="$ROOT/keys" BRIC_RUNSTATE="$ROOT/runstate" BRIC_SQL_INIT="$REPO/cluster/sql/cluster_init.sql"
export BRIC_USER="vsz652" BRIC_RUN_MODE="local" BRIC_RESERVE_TIMEOUT=8 BRIC_POLL=1
export BRIC_TAPE_HOME="$REPO/tape" BRIC_TAPE_DB="$ROOT/tape_catalog.db" BRIC_TAPE_SQL_INIT="$REPO/tape/sql/tape_init.sql"
export BRIC_TAPE_BACKEND="sim" BRIC_TAPELIB="$ROOT/tapelib" BRIC_TAPE_LOCK="$ROOT/tape.lock"
mkdir -p "$BRIC_QNAP" "$BRIC_KEYS" "$BRIC_TAPELIB" "$(dirname "$BRIC_DB")"
chmod +x "$REPO"/cluster/scripts/*.sh "$REPO"/cluster/bin/bric "$REPO"/tape/bin/bric-tape-daemon 2>/dev/null || true
sqlite3 "$BRIC_DB" < "$BRIC_SQL_INIT" >/dev/null
sqlite3 "$BRIC_TAPE_DB" < "$BRIC_TAPE_SQL_INIT" >/dev/null
head -c 32 /dev/urandom | base64 > "$BRIC_KEYS/${BRIC_USER}_user_key.txt"
head -c 32 /dev/urandom | base64 > "$BRIC_KEYS/master.key"; chmod 600 "$BRIC_KEYS"/*
fail=0; ok(){ echo "  ok: $1"; }; bad(){ echo "  FAIL: $1"; fail=1; }

# turn the hardening ON in both catalogs
sqlite3 "$BRIC_TAPE_DB" "UPDATE config SET value='1' WHERE key='require_bus_signing';"
sqlite3 "$BRIC_DB"      "UPDATE config SET value='1' WHERE key='require_bus_signing';"

echo "=== daemon refuses to start unsigned when required ==="
unset BRIC_BUS_SIGN_KEY BRIC_BUS_VERIFY_KEY || true
if timeout 10 "$REPO/tape/bin/bric-tape-daemon" --once >"$ROOT/d1.log" 2>&1; then
  bad "daemon started despite require_bus_signing=1 and no keys"
else
  grep -qi "require_bus_signing=1 but BRIC_BUS_SIGN_KEY" "$ROOT/d1.log" && ok "daemon refused to start unsigned (clear message)" || { bad "daemon exited but without the expected message"; tail -3 "$ROOT/d1.log"|sed 's/^/    /'; }
fi

echo "=== cluster refuses to plan unsigned when required ==="
SRC="$ROOT/data/p"; mkdir -p "$SRC"; echo hi > "$SRC/f.txt"
if "$REPO/cluster/bin/bric" backup --project p --source "$SRC" >"$ROOT/c1.log" 2>&1; then
  bad "cluster planned despite require_bus_signing=1 and no keys"
else
  grep -qi "require_bus_signing=1 but BRIC_BUS_SIGN_KEY" "$ROOT/c1.log" && ok "cluster refused to publish unsigned (clear message)" || { bad "cluster failed but without the expected message"; tail -3 "$ROOT/c1.log"|sed 's/^/    /'; }
fi

echo "=== with keys present, the daemon starts in MANDATORY mode ==="
"$REPO/cluster/scripts/bric-bus-keygen.sh" "$BRIC_KEYS" >/dev/null 2>&1
export BRIC_BUS_SIGN_KEY="$BRIC_KEYS/tape_bus_ecdsa_p256.pem" BRIC_BUS_VERIFY_KEY="$BRIC_KEYS/cluster_bus_ecdsa_p256.pub"
setsid "$REPO/tape/bin/bric-tape-daemon" --loop >"$ROOT/d2.log" 2>&1 & D=$!
trap 'bric_test_stop_group "$D"; [ -n "${KEEP:-}" ]||rm -rf "$ROOT"' EXIT
sleep 2
if kill -0 "$D" 2>/dev/null && grep -qi "bus authentication is MANDATORY" "$ROOT/d2.log"; then ok "daemon started in MANDATORY mode with keys present"; else bad "daemon did not start in mandatory mode"; tail -3 "$ROOT/d2.log"|sed 's/^/    /'; fi

echo
[ "$fail" -eq 0 ] && echo "✓ REQUIRE-BUS-SIGNING CHECKS PASSED" || { echo "✗ FAILURES"; exit 1; }
