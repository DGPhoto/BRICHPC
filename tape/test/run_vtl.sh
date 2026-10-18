#!/bin/bash
. "$(cd "$(dirname "$(readlink -f "$0")")" && pwd)/lib_test_daemon.sh"
# bric-vtl (virtual tape library): fake file-backed devices must carry the FULL real-backend
# pipeline without any real cartridge.
#   A) create + env: library built, exports usable, mock mtx inventory correct
#   B) preflight passes green against a healthy VTL (device nodes, inventory, pairing, sg_*)
#   C) lib-level IO on BOTH drives (append/read via lib_tape_io real functions, drive 1 included)
#   D) full e2e on the VTL: daemon (real backend) -> backup CLOSED -> restore -> DR bit-identical
#   E) reset: content erased, cartridges back in slots, a new backup works again
set -uo pipefail
export BRIC_CONFIG=none   # hermetic: never read /etc/bric/bric.conf inside tests
REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
ROOT="$(mktemp -d)"
export BRIC_LOG_DIR="$ROOT/log-primary" BRIC_LOG_FALLBACK_DIR="$ROOT/log-fallback" BRIC_REQUIRE_LOGGING=1
echo "workroot=$ROOT"
fail=0; ok() { echo "  ok: $*"; }; bad() { echo "  FAIL: $*"; fail=1; }
trap 'bric_test_stop_group "${DAEMON:-0}"; [ -n "${KEEP:-}" ] || bric_test_rmrf_retry "$ROOT"' EXIT
chmod +x "$REPO"/tape/bin/bric-vtl "$REPO"/cluster/scripts/*.sh "$REPO"/cluster/bin/bric "$REPO"/tape/bin/* 2>/dev/null || true
VTL="$ROOT/vtl"

echo "=== A) create + env ==="
"$REPO/tape/bin/bric-vtl" create "$VTL" --tapes 4 --drives 2 >/dev/null || bad "create failed"
[ -f "$VTL/.bric_vtl" ] && ok "VTL marker present" || bad "marker missing"
eval "$("$REPO/tape/bin/bric-vtl" env "$VTL")"
[ "$BRIC_TAPE_BACKEND" = real ] && [ "$BRIC_TAPE_DRIVES" = "0 1" ] && ok "env exports real backend with 2 drives" || bad "env exports wrong"
ST="$("$REPO/tape/bin/bric-vtl" status "$VTL")"
echo "$ST" | grep -q "000000L9" && echo "$ST" | grep -q "000003L9" && ok "4 barcodes inventoried (000000..000003)" || bad "inventory wrong"
if echo "$ST" | grep -q "2 Drives"; then
    ok "changer reports 2 drives"
else
    bad "drive count wrong (ndrives=$(cat "$VTL/ndrives" 2>/dev/null || echo missing))"
    printf '%s\n' "$ST" | sed 's/^/    status: /'
fi

echo "=== B) preflight green on a healthy VTL ==="
if out="$("$REPO/tape/bin/bric-library-preflight" 2>&1)"; then
    ok "preflight exit 0"
    echo "$out" | grep -q "2 complete physical barcode pair(s) currently onsite" && ok "project-scoped pair inventory exercised" || bad "pair inventory summary missing"
else
    bad "preflight failed on healthy VTL"; echo "$out" | grep FAIL | head -3
fi

echo "=== C) lib-level IO on BOTH drives ==="
( . "$REPO/tape/scripts/lib_tape_io.sh"
  head -c 5000 /dev/urandom > "$ROOT/A"; head -c 9000 /dev/urandom > "$ROOT/B"
  n1="$(tape_append_file 000000L9 "$ROOT/A")"; [ "$n1" = 1 ] || { echo "  FAIL: first append got $n1"; exit 1; }
  n2="$(tape_append_file 000000L9 "$ROOT/B")"; [ "$n2" = 2 ] || { echo "  FAIL: second append got $n2"; exit 1; }
  tape_read_file 000000L9 2 "$ROOT/r2"; cmp -s "$ROOT/B" "$ROOT/r2" || { echo "  FAIL: file 2 mismatch"; exit 1; }
  # drive element 1 explicitly
  BRIC_TAPE_DRIVES="1" tape_append_file 000002L9 "$ROOT/A" >/dev/null || { echo "  FAIL: append via drive 1"; exit 1; }
  BRIC_TAPE_DRIVES="1" tape_read_file 000002L9 1 "$ROOT/r3"; cmp -s "$ROOT/A" "$ROOT/r3" || { echo "  FAIL: read via drive 1"; exit 1; }
  echo "  ok: append/read round-trip on drive 0 and drive 1"
) || fail=1
"$REPO/tape/bin/bric-vtl" reset "$VTL" >/dev/null   # clean slate for the e2e

echo "=== D) full e2e on the VTL (daemon real backend) ==="
export BRIC_HOME="$REPO/cluster" BRIC_DB="$ROOT/c.db" BRIC_QNAP="$ROOT/qnap/bric"
export BRIC_KEYS="$ROOT/keys" BRIC_SQL_INIT="$REPO/cluster/sql/cluster_init.sql"
export BRIC_USER="${BRIC_ACCEPTANCE_USER:-vsz652}" BRIC_RUN_MODE=local BRIC_POLL=1
export BRIC_RESERVE_TIMEOUT=40 BRIC_DRAIN_TIMEOUT=90 BRIC_CLOSE_TIMEOUT=60 BRIC_RESTORE_TIMEOUT=40
export BRIC_TAPE_HOME="$REPO/tape" BRIC_TAPE_DB="$ROOT/t.db" BRIC_TAPE_SQL_INIT="$REPO/tape/sql/tape_init.sql"
export BRIC_PARALLEL_DRIVES=2 BRIC_UNLOAD_ON_COMPLETE=1
mkdir -p "$BRIC_QNAP" "$BRIC_KEYS"
sqlite3 "$BRIC_DB" < "$BRIC_SQL_INIT" >/dev/null
sqlite3 "$BRIC_TAPE_DB" < "$BRIC_TAPE_SQL_INIT" >/dev/null
sqlite3 "$BRIC_DB" "UPDATE config SET value='4194304' WHERE key='segment_target_bytes';"
sqlite3 "$BRIC_TAPE_DB" "UPDATE config SET value='1' WHERE key='poll_seconds'; UPDATE config SET value='2' WHERE key='parallel_drives';"
if [ -n "${BRIC_ACCEPTANCE_KEY_FILE:-}" ]; then
    [ -r "$BRIC_ACCEPTANCE_KEY_FILE" ] && [ -s "$BRIC_ACCEPTANCE_KEY_FILE" ] || { echo "FAIL: BRIC_ACCEPTANCE_KEY_FILE is missing/empty/unreadable: $BRIC_ACCEPTANCE_KEY_FILE" >&2; exit 1; }
    [ "$(wc -l < "$BRIC_ACCEPTANCE_KEY_FILE" | tr -d ' ')" -le 1 ] || { echo "FAIL: acceptance user key must be one line" >&2; exit 1; }
    cp -f "$BRIC_ACCEPTANCE_KEY_FILE" "$BRIC_KEYS/${BRIC_USER}_user_key.txt"
    echo "  using supplied acceptance key for logical user $BRIC_USER"
else
    head -c 32 /dev/urandom | base64 > "$BRIC_KEYS/${BRIC_USER}_user_key.txt"
    echo "  using generated disposable key for logical user $BRIC_USER"
fi
head -c 32 /dev/urandom | base64 > "$BRIC_KEYS/master.key"
chmod 600 "$BRIC_KEYS"/*
BRIC_MASTER_KEY_FILE="$BRIC_KEYS/master.key"   "$REPO/cluster/scripts/bric-register-user.sh" --user "$BRIC_USER"   --key-file "$BRIC_KEYS/${BRIC_USER}_user_key.txt" --escrow-only --no-handout >/dev/null
sqlite3 "$BRIC_TAPE_DB" "INSERT INTO tapes(volumetag,slot,role,pair_number,paired_volumetag,capacity_tb,used_tb,status)
  VALUES('000000L9',1,'PRIMARY',1,'000001L9',18,0,'EMPTY'),('000001L9',2,'BACKUP',1,'000000L9',18,0,'EMPTY'),
        ('000002L9',3,'PRIMARY',2,'000003L9',18,0,'EMPTY'),('000003L9',4,'BACKUP',2,'000002L9',18,0,'EMPTY');"
setsid "$REPO/tape/bin/bric-tape-daemon" --loop >"$ROOT/daemon.log" 2>&1 & DAEMON=$!
sleep 1
SRC="$ROOT/data/vtlproj"; mkdir -p "$SRC"
dd if=/dev/urandom of="$SRC/x.dat" bs=1M count=3 status=none 2>/dev/null
dd if=/dev/urandom of="$SRC/y.dat" bs=1M count=2 status=none 2>/dev/null
RUN="$("$REPO/cluster/bin/bric" backup --project vtlproj --source "$SRC")" || bad "backup failed on VTL"
[ "$(sqlite3 "$BRIC_DB" "SELECT status FROM runs WHERE run_id='$RUN';")" = CLOSED ] && ok "backup CLOSED through mtx/mt/dd mocks" || bad "run not CLOSED"
grep -q "streamed concurrently on drives 0/1" "$ROOT/daemon.log" && ok "PRIMARY/BACKUP chunk copies used both drives concurrently" || bad "dual-drive chunk path not exercised"
grep -q "CLOSED .*both copies complete; media returned to slots" "$ROOT/daemon.log" && ok "close waited for both copies/artifacts/TOCs and empty drives" || bad "final close barrier not observed"
grep -q "hw quickcheck passed" "$ROOT/daemon.log" && ok "per-operation hardware gate exercised against the VTL" || bad "quickcheck not exercised"
"$REPO/cluster/scripts/bric-restore.sh" --project vtlproj --dest "$ROOT/rest" >/dev/null 2>&1 \
    && diff -r "$SRC" "$ROOT/rest" >/dev/null && ok "restore bit-identical" || bad "restore failed"
ST_EMPTY="$("$REPO/tape/bin/bric-vtl" status "$VTL")"
echo "$ST_EMPTY" | grep -q 'Data Transfer Element 0:Empty' \
    && echo "$ST_EMPTY" | grep -q 'Data Transfer Element 1:Empty' \
    && ok "restore did not finish until both drives were empty" || bad "a drive remained loaded after restore"
bric_test_stop_group "$DAEMON"
"$REPO/cluster/scripts/bric-dr-from-tapes.sh" --project vtlproj \
    --user-key-file "$BRIC_KEYS/${BRIC_USER}_user_key.txt" --dest "$ROOT/dr" >/dev/null 2>&1 \
    && diff -r "$SRC" "$ROOT/dr" >/dev/null && ok "DR from VTL tapes + key alone: bit-identical" || bad "DR failed"
N0="$(ls "$VTL/tapes/000000L9"/f_* 2>/dev/null | wc -l | tr -d ' ')"
[ "$N0" -ge 8 ] && ok "PRIMARY VTL tape holds chunks + kit + TOC ($N0 tape files)" || bad "unexpected tape file count: $N0"

echo "=== E) reset and reuse ==="
"$REPO/tape/bin/bric-vtl" reset "$VTL" >/dev/null
[ -z "$(ls "$VTL/tapes" 2>/dev/null)" ] && ok "reset erased all written content" || bad "content survived reset"
# NB: captured, not piped — `status | grep -q` under pipefail fails on SIGPIPE despite the match.
ST2="$("$REPO/tape/bin/bric-vtl" status "$VTL")"
echo "$ST2" | grep -q "000000L9" && ok "cartridges back in slots after reset" || bad "inventory broken after reset"

echo
[ "$fail" -eq 0 ] && echo "✓ VTL CHECKS PASSED" || { echo "✗ VTL FAILURES"; exit 1; }
