#!/bin/bash
. "$(cd "$(dirname "$(readlink -f "$0")")" && pwd)/lib_test_daemon.sh"
# Review 30M: initial one-pair stream reservation expands project-scoped capacity on demand.
set -euo pipefail
export BRIC_CONFIG=none
REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"; T="$(mktemp -d)"
export BRIC_HOME="$REPO/cluster" BRIC_DB="$T/c.db" BRIC_QNAP="$T/q/bric" BRIC_KEYS="$T/keys" BRIC_SQL_INIT="$REPO/cluster/sql/cluster_init.sql" BRIC_USER=u BRIC_RUNSTATE="$T/runstate" BRIC_RESERVE_TIMEOUT=30 BRIC_POLL=1
export BRIC_TAPE_HOME="$REPO/tape" BRIC_TAPE_DB="$T/t.db" BRIC_TAPE_SQL_INIT="$REPO/tape/sql/tape_init.sql" BRIC_TAPE_BACKEND=sim BRIC_TAPELIB="$T/lib" BRIC_TAPE_LOCK="$T/lock"
mkdir -p "$BRIC_QNAP" "$BRIC_KEYS" "$BRIC_TAPELIB" "$T/src"; echo x > "$T/src/x"
sqlite3 "$BRIC_DB" < "$BRIC_SQL_INIT" >/dev/null; sqlite3 "$BRIC_TAPE_DB" < "$BRIC_TAPE_SQL_INIT" >/dev/null
sqlite3 "$BRIC_DB" "UPDATE config SET value='400000000000' WHERE key='segment_target_bytes';"
sqlite3 "$BRIC_TAPE_DB" "UPDATE config SET value='1' WHERE key='poll_seconds'; UPDATE config SET value='0' WHERE key='tape_headroom_tb';
INSERT INTO tapes(volumetag,slot,role,pair_number,paired_volumetag,capacity_tb,used_tb,status) VALUES
('P1',1,'PRIMARY',1,'B1',1,0,'EMPTY'),('B1',2,'BACKUP',1,'P1',1,0,'EMPTY'),
('P2',3,'PRIMARY',2,'B2',1,0,'EMPTY'),('B2',4,'BACKUP',2,'P2',1,0,'EMPTY');"
head -c 32 /dev/urandom | base64 > "$BRIC_KEYS/u_user_key.txt"
setsid "$REPO/tape/bin/bric-tape-daemon" --loop >"$T/daemon.log" 2>&1 & D=$!
trap 'bric_test_stop_group "$D"; rm -rf "$T" 2>/dev/null || { sleep 1; rm -rf "$T"; }' EXIT
sleep 1
RUN="$("$REPO/cluster/scripts/bric-stream-plan.sh" --project p --source "$T/src")"
C1="$(cat "$T/runstate/$RUN/reserved_capacity")"; [ "$C1" = 1000000000000 ]
C2="$("$REPO/cluster/scripts/bric-reserve-extend.sh" --run "$RUN" --required-total 1500000000000 | tail -1)"; [ "$C2" = 2000000000000 ]
[ "$(sqlite3 "$BRIC_TAPE_DB" "SELECT COUNT(DISTINCT pair_number) FROM tapes WHERE project_name='p';")" = 2 ]
echo "✓ dynamic project-scoped stream reservation passed"
