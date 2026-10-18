#!/bin/bash
. "$(cd "$(dirname "$(readlink -f "$0")")" && pwd)/lib_test_daemon.sh"
# Audit trail + tape-health observability, plus the 128 GB packing arithmetic.
set -euo pipefail
export BRIC_CONFIG=none   # hermetic: never read /etc/bric/bric.conf inside tests
REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
ROOT="$(mktemp -d)"; echo "workroot=$ROOT"
export BRIC_HOME="$REPO/cluster" BRIC_DB="$ROOT/c.db" BRIC_QNAP="$ROOT/qnap/bric" BRIC_KEYS="$ROOT/keys" BRIC_SQL_INIT="$REPO/cluster/sql/cluster_init.sql"
export BRIC_USER=vsz652 BRIC_RUN_MODE=local BRIC_RESERVE_TIMEOUT=60 BRIC_DRAIN_TIMEOUT=120 BRIC_CLOSE_TIMEOUT=120 BRIC_POLL=1
export BRIC_TAPE_HOME="$REPO/tape" BRIC_TAPE_DB="$ROOT/t.db" BRIC_TAPE_SQL_INIT="$REPO/tape/sql/tape_init.sql"
export BRIC_TAPE_BACKEND=sim BRIC_TAPELIB="$ROOT/tl" BRIC_TAPE_LOCK="$ROOT/t.lock"
mkdir -p "$BRIC_QNAP" "$BRIC_KEYS" "$BRIC_TAPELIB"; chmod +x "$REPO"/cluster/scripts/*.sh "$REPO"/cluster/bin/bric "$REPO"/tape/bin/bric-tape-daemon
sqlite3 "$BRIC_DB" < "$BRIC_SQL_INIT" >/dev/null; sqlite3 "$BRIC_TAPE_DB" < "$BRIC_TAPE_SQL_INIT" >/dev/null
sqlite3 "$BRIC_DB" "UPDATE config SET value='8388608' WHERE key='segment_target_bytes';"
sqlite3 "$BRIC_TAPE_DB" "UPDATE config SET value='1' WHERE key='poll_seconds'; UPDATE config SET value='8388608' WHERE key='chunk_target_bytes';"
head -c 32 /dev/urandom|base64>"$BRIC_KEYS/vsz652_user_key.txt"; head -c 32 /dev/urandom|base64>"$BRIC_KEYS/master.key"
sqlite3 "$BRIC_TAPE_DB" "INSERT INTO tapes(volumetag,slot,role,pair_number,paired_volumetag,capacity_tb,used_tb,status) VALUES('000001L9',1,'PRIMARY',1,'000002L9',18,0,'EMPTY'),('000002L9',2,'BACKUP',1,'000001L9',18,0,'EMPTY');"
SRC="$ROOT/data/proj"; mkdir -p "$SRC"; for i in 1 2 3; do dd if=/dev/urandom of="$SRC/f_$i.dat" bs=1M count=2 status=none; done

fail=0; chk(){ [ "$2" = "$3" ] && echo "  ok: $1 ($2)" || { echo "  FAIL: $1 exp=$3 got=$2"; fail=1; }; }
ge(){ [ "$2" -ge "$3" ] && echo "  ok: $1 ($2>=$3)" || { echo "  FAIL: $1 got=$2 want>=$3"; fail=1; }; }

setsid "$REPO/tape/bin/bric-tape-daemon" --loop & DAEMON=$!
trap 'bric_test_stop_group "$DAEMON"; [ -n "${KEEP:-}" ] || { rm -rf "$ROOT" 2>/dev/null || { sleep 1; rm -rf "$ROOT"; }; }' EXIT
sleep 1
echo "=== archive ==="; RUN="$("$REPO/cluster/bin/bric" backup --project proj --source "$SRC" 2>/dev/null)"
bric_test_stop_group "$DAEMON"

echo "=== audit trail ==="
ge "cluster audit rows" "$(sqlite3 "$BRIC_DB" "SELECT COUNT(*) FROM audit_log;")" 2
chk "cluster logged RUN_CLOSED" "$(sqlite3 "$BRIC_DB" "SELECT COUNT(*) FROM audit_log WHERE action='RUN_CLOSED' AND object='$RUN';")" "1"
chk "cluster logged RUN_RESERVED" "$(sqlite3 "$BRIC_DB" "SELECT COUNT(*) FROM audit_log WHERE action='RUN_RESERVED';")" "1"
ge "tape audit rows" "$(sqlite3 "$BRIC_TAPE_DB" "SELECT COUNT(*) FROM audit_log;")" 3
chk "tape logged RESERVED" "$(sqlite3 "$BRIC_TAPE_DB" "SELECT COUNT(*) FROM audit_log WHERE action='RESERVED';")" "1"
chk "tape logged CLOSED" "$(sqlite3 "$BRIC_TAPE_DB" "SELECT COUNT(*) FROM audit_log WHERE action='CLOSED';")" "1"
ge "tape logged SEGMENT_VERIFIED" "$(sqlite3 "$BRIC_TAPE_DB" "SELECT COUNT(*) FROM audit_log WHERE action='SEGMENT_VERIFIED';")" 2

echo "=== tape health telemetry ==="
ge "PRIMARY write_count" "$(sqlite3 "$BRIC_TAPE_DB" "SELECT write_count FROM tapes WHERE volumetag='000001L9';")" 1
chk "PRIMARY health OK" "$(sqlite3 "$BRIC_TAPE_DB" "SELECT health FROM tapes WHERE volumetag='000001L9';")" "OK"

echo "=== periodic re-verify (clean) ==="
"$REPO/tape/bin/bric-tape-daemon" --verify 000001L9 >/dev/null 2>&1 && echo "  ok: re-verify exit 0" || { echo "  FAIL: re-verify nonzero"; fail=1; }
chk "last_verify set" "$([ -n "$(sqlite3 "$BRIC_TAPE_DB" "SELECT last_verify FROM tapes WHERE volumetag='000001L9';")" ] && echo yes || echo no)" "yes"
chk "REVERIFY audited OK" "$(sqlite3 "$BRIC_TAPE_DB" "SELECT result FROM audit_log WHERE action='REVERIFY' ORDER BY id DESC LIMIT 1;")" "OK"

echo "=== re-verify detects corruption ==="
FN=$(sqlite3 "$BRIC_TAPE_DB" "SELECT file_number FROM segments WHERE volumetag='000001L9' AND state='VERIFIED' ORDER BY file_number LIMIT 1;")
dd if=/dev/urandom of="$BRIC_TAPELIB/000001L9/$(printf 'f_%06d' "$FN")" bs=1M count=1 status=none   # silent bit-rot
set +e; "$REPO/tape/bin/bric-tape-daemon" --verify 000001L9 >/dev/null 2>&1; VRC=$?; set -e
chk "re-verify now fails" "$([ "$VRC" -ne 0 ] && echo yes || echo no)" "yes"
chk "tape flagged BAD" "$(sqlite3 "$BRIC_TAPE_DB" "SELECT health FROM tapes WHERE volumetag='000001L9';")" "BAD"
ge "read_errors counted" "$(sqlite3 "$BRIC_TAPE_DB" "SELECT read_errors FROM tapes WHERE volumetag='000001L9';")" 1
chk "REVERIFY audited FAIL" "$(sqlite3 "$BRIC_TAPE_DB" "SELECT result FROM audit_log WHERE action='REVERIFY' ORDER BY id DESC LIMIT 1;")" "FAIL"

echo "=== packing arithmetic: 128 GB chunks pack ~138 per 18 TB LTO-9 ==="
FIT=$(awk 'BEGIN{cap=18.0;head=0.30;chunk=128000000000;usable=(cap-head)*1e12;printf "%d", int(usable/chunk)}')
chk "chunks per tape" "$FIT" "138"
DEFDB="$ROOT/def.db"; sqlite3 "$DEFDB" < "$BRIC_SQL_INIT" >/dev/null
chk "default segment_target_bytes" "$(sqlite3 "$DEFDB" "SELECT value FROM config WHERE key='segment_target_bytes';")" "128000000000"

echo
[ "$fail" -eq 0 ] && echo "✓ AUDIT + HEALTH + PACKING PASSED" || { echo "✗ FAILURES"; exit 1; }
