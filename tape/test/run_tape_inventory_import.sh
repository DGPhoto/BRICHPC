#!/bin/bash
# Real-changer inventory import: complete-pair selection, state preservation and config authority.
set -euo pipefail
IFS=$'\n\t'

REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
DB="$ROOT/tape.db"
CFG="$ROOT/bric.conf"
STATUS="$ROOT/mtx.status"

sqlite3 "$DB" < "$REPO/tape/sql/tape_init.sql" >/dev/null
sqlite3 "$DB" <<'SQL'
UPDATE config SET value='odd' WHERE key='primary_parity';
DELETE FROM tapes;
INSERT INTO tapes(volumetag,slot,role,pair_number,paired_volumetag,capacity_tb,used_tb,status,project_name,owner,health)
VALUES('000001L9',45,'PRIMARY',1,'000002L9',18,0.125,'PARTIAL','smoke_real1','vsz652','OK'),
      ('000002L9',44,'BACKUP',1,'000001L9',18,0.125,'PARTIAL','smoke_real1','vsz652','OK');
SQL
cat > "$CFG" <<EOF2
BRIC_ROLE=tape
BRIC_TAPE_HOME=$REPO/tape
BRIC_TAPE_DB=$DB
BRIC_TAPE_SQL_INIT=$REPO/tape/sql/tape_init.sql
BRIC_TAPE_BACKEND=real
BRIC_CHANGER=/dev/sg4
BRIC_PRIMARY_PARITY=odd
BRIC_TAPE_CAPACITY_TB=18.0
BRIC_TAPE_LOCK=$ROOT/runtime/bric/tape.lock
BRIC_TAPE_WORK_LOCK=$ROOT/runtime/bric/tape.lock.work
BRIC_TAPE_DAEMON_SERVICE=bric-test-daemon.service
BRIC_LOG_DIR=$ROOT/log
BRIC_LOG_FALLBACK_DIR=$ROOT/log2
BRIC_REQUIRE_LOGGING=0
BRIC_REQUIRE_NFS_BUS=0
EOF2
{
    echo '  Storage Changer /dev/sg4:2 Drives, 80 Slots ( 0 Import/Export )'
    echo 'Data Transfer Element 0:Empty'
    echo 'Data Transfer Element 1:Empty'
    slot=1
    for n in $(seq 1 21) $(seq 23 42) $(seq 44 80); do
        printf '      Storage Element %d:Full :VolumeTag=%06dL9\n' "$slot" "$n"
        slot=$((slot+1))
    done
} > "$STATUS"

# Fake systemctl models an initially active daemon. On start it must be able to acquire both
# importer locks immediately. This reproduces the 30Y failure where the EXIT trap restarted
# systemd while still holding fd 8/fd 9.
mkdir -p "$ROOT/fakebin"
printf 'active\n' > "$ROOT/service.state"
cat > "$ROOT/fakebin/systemctl" <<'EOS'
#!/bin/bash
set -euo pipefail
state="${TEST_SERVICE_STATE:?}"
lock="${TEST_LOCK:?}"
work="${TEST_WORK_LOCK:?}"
case "${1:-}" in
  is-active)
    [ "$(cat "$state" 2>/dev/null || true)" = active ]
    ;;
  stop)
    printf 'inactive\n' > "$state"
    ;;
  start)
    exec 9>"$lock"
    flock -n 9 || exit 1
    exec 8>"$work"
    flock -n 8 || exit 1
    printf 'active\n' > "$state"
    printf 'locks-free-at-start\n' > "${state}.start-check"
    ;;
  status) exit 0;;
  *) exit 0;;
esac
EOS
chmod +x "$ROOT/fakebin/systemctl"
export PATH="$ROOT/fakebin:$PATH"
export TEST_SERVICE_STATE="$ROOT/service.state"
export TEST_LOCK="$ROOT/runtime/bric/tape.lock"
export TEST_WORK_LOCK="$ROOT/runtime/bric/tape.lock.work"

# Stale environment values must not override the selected tape config.
BRIC_ROLE=slurm BRIC_TAPE_DB=/wrong \
  "$REPO/tape/bin/bric-tape-import-inventory" \
  --config "$CFG" --status-file "$STATUS" --dry-run > "$ROOT/dry.log"
grep -q 'complete pairs:   38 (76 tapes)' "$ROOT/dry.log"
grep -q 'new catalog rows: 74' "$ROOT/dry.log"
grep -q '000021L9->000022L9' "$ROOT/dry.log"
grep -q '000044L9->000043L9' "$ROOT/dry.log"
[ "$(sqlite3 "$DB" 'SELECT COUNT(*) FROM tapes;')" = 2 ]

BRIC_ROLE=slurm BRIC_TAPE_DB=/wrong \
  "$REPO/tape/bin/bric-tape-import-inventory" \
  --config "$CFG" --status-file "$STATUS" --apply > "$ROOT/apply.log"
[ "$(sqlite3 "$DB" 'SELECT COUNT(*) FROM tapes;')" = 76 ]
[ -d "$ROOT/runtime/bric" ]
[ "$(cat "$ROOT/service.state")" = active ]
[ "$(cat "$ROOT/service.state.start-check")" = locks-free-at-start ]
[ "$(sqlite3 "$DB" 'SELECT COUNT(DISTINCT pair_number) FROM tapes;')" = 38 ]
[ "$(sqlite3 "$DB" "SELECT COUNT(*) FROM tapes WHERE status='EMPTY' AND project_name IS NULL;")" = 74 ]
[ "$(sqlite3 "$DB" "SELECT project_name||'|'||owner||'|'||used_tb FROM tapes WHERE volumetag='000001L9';")" = 'smoke_real1|vsz652|0.125' ]
[ "$(sqlite3 "$DB" "SELECT role||'|'||pair_number||'|'||paired_volumetag FROM tapes WHERE volumetag='000079L9';")" = 'PRIMARY|40|000080L9' ]
[ "$(sqlite3 "$DB" "SELECT COUNT(*) FROM tapes WHERE volumetag IN ('000021L9','000044L9');")" = 0 ]
find "$ROOT" -name 'tape.db.before-inventory-import.*' -type f | grep -q .

# An idempotent preview finds no new/changed rows.
"$REPO/tape/bin/bric-tape-import-inventory" \
  --config "$CFG" --status-file "$STATUS" --dry-run > "$ROOT/dry2.log"
grep -q 'new catalog rows: 0' "$ROOT/dry2.log"
grep -q 'refreshed rows:   0' "$ROOT/dry2.log"
grep -q 'unchanged rows:   76' "$ROOT/dry2.log"

# Config/catalog pairing disagreement is fatal before any catalog mutation.
sed 's/BRIC_PRIMARY_PARITY=odd/BRIC_PRIMARY_PARITY=even/' "$CFG" > "$ROOT/conflict.conf"
if "$REPO/tape/bin/bric-tape-import-inventory" \
     --config "$ROOT/conflict.conf" --status-file "$STATUS" --apply >"$ROOT/conflict.out" 2>&1; then
    echo 'FAIL: parity conflict was accepted' >&2; exit 1
fi
grep -q 'pairing conflict' "$ROOT/conflict.out"
[ "$(sqlite3 "$DB" 'SELECT COUNT(*) FROM tapes;')" = 76 ]

echo 'PASS: physical inventory import preserves media state, skips orphans, rejects parity conflicts and releases locks before daemon restart'
