#!/bin/bash
. "$(cd "$(dirname "$(readlink -f "$0")")" && pwd)/lib_test_daemon.sh"
# Review 30M: in local tar-stream mode a producer failure must NOT leave the run stuck active.
# We inject a failing tar-stream helper and assert the stream backup trap:
#   - the run ends FAILED (not PRODUCING),
#   - the global producer slot is freed (no run left PRODUCING),
#   - a signed run.ABORTED marker is published so the tape server releases the reservation.
set -euo pipefail
export BRIC_CONFIG=none   # hermetic: never read /etc/bric/bric.conf inside tests
SRC_REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT

# Work against a private COPY of the repo so we can replace the stream producer with a failing stub.
REPO="$ROOT/repo"; cp -r "$SRC_REPO" "$REPO"
cat > "$REPO/cluster/libexec/bric-tar-stream" <<'STUB'
#!/bin/bash
# Consume a little input so the tar side starts, then fail deterministically.
dd bs=4096 count=1 of=/dev/null 2>/dev/null || true
echo "fault-injection: tar stream helper failed" >&2
exit 42
STUB
chmod +x "$REPO/cluster/libexec/bric-tar-stream"
chmod +x "$REPO"/cluster/scripts/*.sh "$REPO"/cluster/bin/bric "$REPO"/cluster/bin/bric-run "$REPO"/tape/bin/bric-tape-daemon 2>/dev/null || true

export BRIC_HOME="$REPO/cluster" BRIC_DB="$ROOT/cluster_catalog.db" BRIC_QNAP="$ROOT/qnap/bric" BRIC_KEYS="$ROOT/keys"
export BRIC_USER="tester" BRIC_RUN_MODE="local" BRIC_RESERVE_TIMEOUT=60 BRIC_DRAIN_TIMEOUT=60 BRIC_POLL=1
export BRIC_TAPE_HOME="$REPO/tape" BRIC_TAPE_DB="$ROOT/tape_catalog.db" BRIC_TAPE_BACKEND="sim" BRIC_TAPELIB="$ROOT/tapelib" BRIC_TAPE_LOCK="$ROOT/tape.lock"
mkdir -p "$BRIC_QNAP" "$BRIC_KEYS" "$BRIC_TAPELIB" "$(dirname "$BRIC_DB")"

sqlite3 "$BRIC_DB"      < "$REPO/cluster/sql/cluster_init.sql"
sqlite3 "$BRIC_TAPE_DB" < "$REPO/tape/sql/tape_init.sql"
sqlite3 "$BRIC_DB"      "UPDATE config SET value='128' WHERE key='segment_target_bytes';"   # many small chunks
sqlite3 "$BRIC_TAPE_DB" "UPDATE config SET value='1' WHERE key='poll_seconds';"
head -c 32 /dev/urandom | base64 > "$BRIC_KEYS/${BRIC_USER}_user_key.txt"
head -c 32 /dev/urandom | base64 > "$BRIC_KEYS/master.key"; chmod 600 "$BRIC_KEYS"/*
sqlite3 "$BRIC_TAPE_DB" "INSERT INTO tapes (volumetag,slot,role,pair_number,paired_volumetag,capacity_tb,used_tb,status)
   VALUES ('000001L9',1,'PRIMARY',1,'000002L9',18.0,0,'EMPTY'),('000002L9',2,'BACKUP',1,'000001L9',18.0,0,'EMPTY');"

SRC="$ROOT/src"; mkdir -p "$SRC"; for i in 1 2 3 4; do head -c 300 /dev/urandom > "$SRC/f$i.bin"; done

setsid "$REPO/tape/bin/bric-tape-daemon" --loop >/dev/null 2>&1 & DAEMON=$!
sleep 1
fail() { echo "FAIL: $*" >&2; bric_test_stop_group "$DAEMON"; exit 1; }

# The backup is EXPECTED to fail. --wait bypasses the normal detached supervisor in tests.
if timeout 50 "$REPO/cluster/bin/bric" backup --project P --source "$SRC" --wait >/dev/null 2>"$ROOT/bk.log"; then
    fail "backup unexpectedly succeeded despite an injected chunk failure"
fi
bric_test_stop_group "$DAEMON"

ST="$(sqlite3 "$BRIC_DB" "SELECT status FROM runs WHERE project_name='P';")"
[ "$ST" = FAILED ] || fail "run status is '$ST', expected FAILED (stream trap did not fire)"
echo "  ok: run ended FAILED, not stuck active"

NPROD="$(sqlite3 "$BRIC_DB" "SELECT COUNT(*) FROM runs WHERE status='PRODUCING';")"
[ "${NPROD:-1}" = 0 ] || fail "$NPROD run(s) still PRODUCING — producer slot was not released"
echo "  ok: producer slot freed (no run left PRODUCING)"

find "$BRIC_QNAP" -name 'run.ABORTED' | grep -q . || fail "no run.ABORTED marker published — tape reservation not released"
echo "  ok: signed run.ABORTED published (tape reservation release requested)"

echo "PASS run_local_abort"
