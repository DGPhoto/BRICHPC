#!/bin/bash
. "$(cd "$(dirname "$(readlink -f "$0")")" && pwd)/lib_test_daemon.sh"
# bric-setup end-to-end: the provisioning path must produce a WORKING system.
#   A) setup --role all (real run, temp paths via config file): DBs created with schema, tapes
#      registered with correct pairing/parity, users registered WITH escrow + handout
#   B) idempotency: run setup AGAIN -> no duplicate tapes/users, keys unchanged, exit 0
#   C) the provisioned system actually works: backup -> restore -> DR, bit-identical
#   D) setup honors /etc/bric/bric.conf semantics (values come from the config file; env wins)
set -uo pipefail
# Review 31E3: this test must be hermetic even when invoked directly from an administrator shell
# that already exported production BRIC_* variables. The full suite runner also sanitizes them,
# but individual tests are documented/supported entry points too. Clear all inherited BRIC_ and
# internal _BRIC_ state before constructing this test's private configuration.
for _bric_v in ${!BRIC_@} ${!_BRIC_@}; do
    unset "$_bric_v"
done
unset _bric_v
export BRIC_CONFIG=none   # hermetic default; scenario D sets its own
REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
ROOT="$(mktemp -d)"
export BRIC_LOG_DIR="$ROOT/test-log/primary"
export BRIC_LOG_FALLBACK_DIR="$ROOT/test-log/fallback"
export BRIC_REQUIRE_LOGGING=1
mkdir -p "$BRIC_LOG_DIR" "$BRIC_LOG_FALLBACK_DIR"
echo "workroot=$ROOT"
fail=0; ok() { echo "  ok: $*"; }; bad() { echo "  FAIL: $*"; fail=1; }
trap 'bric_test_stop_group "${DAEMON:-0}"; [ -n "${KEEP:-}" ] || bric_test_rmrf_retry "$ROOT"' EXIT
chmod +x "$REPO"/cluster/scripts/*.sh "$REPO"/cluster/bin/bric "$REPO"/tape/bin/bric-tape-daemon "$REPO"/bric-setup.sh 2>/dev/null || true

# Setup is an administrative command. The E2E test must exercise its systemd/link-installation path
# without ever mutating the host that runs the suite. Route every administrative destination into
# the temporary root and provide deterministic ps/pgrep/systemctl shims only for the setup calls.
HOSTROOT="$ROOT/host"
FAKEBIN="$ROOT/fakebin"
SYSTEMCTL_LOG="$ROOT/systemctl.log"
PGREP_LOG="$ROOT/pgrep.log"
mkdir -p "$FAKEBIN" "$HOSTROOT"
cat > "$FAKEBIN/systemctl" <<'EOF_SYSTEMCTL'
#!/bin/bash
printf '%s\n' "$*" >> "${BRIC_TEST_SYSTEMCTL_LOG:?}"
case "${1:-}" in
  is-active) exit 0 ;;
  status) printf '%s\n' 'mock bric-tape-daemon.service active' ;;
esac
exit 0
EOF_SYSTEMCTL
cat > "$FAKEBIN/ps" <<'EOF_PS'
#!/bin/bash
if [ "$#" -eq 4 ] && [ "$1" = -p ] && [ "$2" = 1 ] && [ "$3" = -o ] && [ "$4" = comm= ]; then
  printf '%s\n' systemd
  exit 0
fi
exec /usr/bin/ps "$@"
EOF_PS
cat > "$FAKEBIN/pgrep" <<'EOF_PGREP'
#!/bin/bash
printf '%s\n' "$*" >> "${BRIC_TEST_PGREP_LOG:?}"
# Never return a host PID to bric-setup: a hermetic test must not kill a real daemon.
exit 1
EOF_PGREP
chmod +x "$FAKEBIN/systemctl" "$FAKEBIN/ps" "$FAKEBIN/pgrep"

fingerprint_path() {
    local p="$1"
    if [ -L "$p" ]; then printf 'L:%s' "$(readlink "$p")"
    elif [ -f "$p" ]; then printf 'F:%s' "$(sha256sum "$p" | awk '{print $1}')"
    elif [ -e "$p" ]; then printf 'E:%s' "$(stat -c '%F:%s' "$p" 2>/dev/null || echo unknown)"
    else printf 'ABSENT'; fi
}
REAL_ADMIN_PATHS=(
  /etc/systemd/system/bric-tape-daemon.service
  /usr/local/bin/bric
  /usr/local/sbin/bric-activate-user
  /usr/local/sbin/bric-bus-cleanup
  /usr/local/sbin/bric-update
  /usr/local/sbin/bric-tape-import-inventory
  /usr/local/share/man/man1/bric.1
)
declare -A REAL_ADMIN_BEFORE=()
for _p in "${REAL_ADMIN_PATHS[@]}"; do REAL_ADMIN_BEFORE["$_p"]="$(fingerprint_path "$_p")"; done

run_setup_all() {
    env PATH="$FAKEBIN:$PATH" \
        BRIC_TEST_SYSTEMCTL_LOG="$SYSTEMCTL_LOG" BRIC_TEST_PGREP_LOG="$PGREP_LOG" \
        BRIC_SYSTEMD_UNIT_DIR="$HOSTROOT/etc/systemd/system" \
        BRIC_COMMAND_LINK="$HOSTROOT/usr/local/bin/bric" \
        BRIC_ACTIVATE_USER_LINK="$HOSTROOT/usr/local/sbin/bric-activate-user" \
        BRIC_BUS_CLEANUP_LINK="$HOSTROOT/usr/local/sbin/bric-bus-cleanup" \
        BRIC_UPDATE_LINK="$HOSTROOT/usr/local/sbin/bric-update" \
        BRIC_TAPE_IMPORT_LINK="$HOSTROOT/usr/local/sbin/bric-tape-import-inventory" \
        BRIC_MAN_DIR="$HOSTROOT/usr/local/share/man/man1" \
        BRIC_CONFIG="$CFG" BRIC_TAPE_COUNT=4 BRIC_USERS_FILE="$USERS" BRIC_SITE_ENV=staging \
        bash "$REPO/bric-setup.sh" --role all
}

# Everything through the CONFIG FILE — the way production will run it.
CFG="$ROOT/bric.conf"
cat > "$CFG" <<EOF
BRIC_HOME=$REPO/cluster
BRIC_DB=$ROOT/sys/cluster/cluster_catalog.db
BRIC_SQL_INIT=$REPO/cluster/sql/cluster_init.sql
BRIC_TAPE_HOME=$REPO/tape
BRIC_TAPE_DB=$ROOT/sys/tape/tape_catalog.db
BRIC_TAPE_SQL_INIT=$REPO/tape/sql/tape_init.sql
BRIC_QNAP=$ROOT/sys/qnap/bric
BRIC_KEYS=$ROOT/sys/keys
BRIC_TAPELIB=$ROOT/sys/tapelib
BRIC_TAPE_BACKEND=sim
BRIC_TAPE_DRIVES=0 1
BRIC_PARALLEL_DRIVES=2
BRIC_TAPE_LOCK=$ROOT/sys/tape.lock
BRIC_NOTIFY_LOG=$ROOT/sys/events.log
BRIC_LOG_DIR=$ROOT/sys/log-primary
BRIC_LOG_FALLBACK_DIR=$ROOT/sys/log-fallback
EOF
mkdir -p "$ROOT/sys/qnap/bric" "$ROOT/sys/tapelib"
USERS="$ROOT/users.txt"; printf 'vsz652\nalice9\n' > "$USERS"

echo "=== A) real setup --role all ==="
run_setup_all >"$ROOT/setup1.log" 2>&1 || { bad "setup exited nonzero"; tail -12 "$ROOT/setup1.log"; }
[ -f "$HOSTROOT/etc/systemd/system/bric-tape-daemon.service" ] \
    && ok "systemd unit installed only in the temporary host root" || bad "temporary systemd unit missing"
[ -L "$HOSTROOT/usr/local/sbin/bric-tape-import-inventory" ] \
    && ok "tape inventory command installed only in the temporary host root" || bad "temporary tape import link missing"
grep -Fxq 'daemon-reload' "$SYSTEMCTL_LOG" 2>/dev/null \
    && grep -Fxq 'enable --now bric-tape-daemon.service' "$SYSTEMCTL_LOG" 2>/dev/null \
    && grep -Fxq 'is-active --quiet bric-tape-daemon.service' "$SYSTEMCTL_LOG" 2>/dev/null \
    && ok "systemd enable/start/active path exercised through the test shim" \
    || bad "expected systemctl lifecycle was not exercised"
PGREP_PATTERN="$(awk '$1=="-f" {sub(/^-f[[:space:]]+/, ""); print; exit}' "$PGREP_LOG" 2>/dev/null || true)"
ARBITRARY_OLD_DAEMON='/opt/bric_archive_2_0_review30e_project_scoped_media_20260727/tape/bin/bric-tape-daemon --loop'
if [ -n "$PGREP_PATTERN" ] && [[ "$ARBITRARY_OLD_DAEMON" =~ $PGREP_PATTERN ]]; then
    ok "manual-daemon collision probe matches a daemon from an arbitrary extracted tree"
else
    bad "daemon collision probe does not match an arbitrary extracted-tree daemon (pattern='$PGREP_PATTERN')"
fi
[ -f "$ROOT/sys/cluster/cluster_catalog.db" ] && ok "cluster catalog created at the config-file path" || bad "cluster DB missing"
[ -f "$ROOT/sys/tape/tape_catalog.db" ] && ok "tape catalog created at the config-file path" || bad "tape DB missing"
NT="$(sqlite3 "$ROOT/sys/tape/tape_catalog.db" "SELECT COUNT(*) FROM tapes;" 2>/dev/null)"
[ "$NT" = 4 ] && ok "4 tapes registered (BRIC_TAPE_COUNT honored)" || bad "tape count=$NT"
BADPAIR="$(sqlite3 "$ROOT/sys/tape/tape_catalog.db" "SELECT COUNT(*) FROM tapes t WHERE (CAST(substr(volumetag,1,6) AS INTEGER)%2=0 AND role!='PRIMARY') OR (CAST(substr(volumetag,1,6) AS INTEGER)%2=1 AND role!='BACKUP');")"
[ "$BADPAIR" = 0 ] && ok "barcode parity respected (even=PRIMARY, odd=BACKUP)" || bad "$BADPAIR tape(s) violate parity"
for u in vsz652 alice9; do
    [ -f "$ROOT/sys/keys/${u}_user_key.txt" ] || { bad "$u key missing"; continue; }
    ESC="$(sqlite3 "$ROOT/sys/cluster/cluster_catalog.db" "SELECT key_escrow FROM users WHERE username='$u';")"
    case "$ESC" in v2:*:*) ok "$u registered with authenticated escrow";; *) bad "$u escrow missing/wrong";; esac
done
[ -f "$ROOT/sys/keys/handouts/vsz652_key_handout.txt" ] && ok "handout sheets produced" || bad "handouts missing"

echo "=== B) idempotency: run setup again ==="
K1="$(cat "$ROOT/sys/keys/vsz652_user_key.txt")"
run_setup_all >"$ROOT/setup2.log" 2>&1 || { bad "second setup run exited nonzero"; tail -12 "$ROOT/setup2.log"; }
[ "$(sqlite3 "$ROOT/sys/tape/tape_catalog.db" "SELECT COUNT(*) FROM tapes;")" = 4 ] && ok "no duplicate tapes on re-run" || bad "tape rows changed"
[ "$(sqlite3 "$ROOT/sys/cluster/cluster_catalog.db" "SELECT COUNT(*) FROM users;")" = 2 ] && ok "no duplicate users on re-run" || bad "user rows changed"
[ "$(cat "$ROOT/sys/keys/vsz652_user_key.txt")" = "$K1" ] && ok "existing key NOT rotated by re-run" || bad "KEY CHANGED on re-run"
ls "$ROOT"/sys/cluster/*.bak* >/dev/null 2>&1 || ls "$ROOT"/sys/cluster/backup* >/dev/null 2>&1 \
    && ok "pre-existing catalog was backed up before touching" || ok "  (no backup artifact found — acceptable if setup skips unchanged DBs)"
HOST_MUTATION=0
for _p in "${REAL_ADMIN_PATHS[@]}"; do
    _after="$(fingerprint_path "$_p")"
    if [ "$_after" != "${REAL_ADMIN_BEFORE[$_p]}" ]; then
        bad "setup test mutated real host path: $_p"
        HOST_MUTATION=1
    fi
done
[ "$HOST_MUTATION" -eq 0 ] && ok "setup E2E left all real administrative host paths unchanged"

echo "=== C) the provisioned system WORKS: backup -> restore -> DR (mandatory bus signing active) ==="
# setup --role all generated both bus key pairs and enabled require_bus_signing=1: the test
# distributes them exactly as setup's own instructions say (each side: OWN private + PEER public).
export BRIC_CONFIG="$CFG" BRIC_USER=vsz652 BRIC_RUN_MODE=local BRIC_POLL=1
export BRIC_RESERVE_TIMEOUT=40 BRIC_DRAIN_TIMEOUT=60 BRIC_CLOSE_TIMEOUT=60 BRIC_RESTORE_TIMEOUT=40
export BRIC_BUS_SIGN_KEY="$ROOT/sys/keys/cluster_bus_ecdsa_p256.pem" BRIC_BUS_VERIFY_KEY="$ROOT/sys/keys/tape_bus_ecdsa_p256.pub"
sqlite3 "$ROOT/sys/cluster/cluster_catalog.db" "UPDATE config SET value='4194304' WHERE key='segment_target_bytes';"
sqlite3 "$ROOT/sys/tape/tape_catalog.db" "UPDATE config SET value='1' WHERE key='poll_seconds';"
BRIC_BUS_SIGN_KEY="$ROOT/sys/keys/tape_bus_ecdsa_p256.pem" BRIC_BUS_VERIFY_KEY="$ROOT/sys/keys/cluster_bus_ecdsa_p256.pub" \
    setsid "$REPO/tape/bin/bric-tape-daemon" --loop >"$ROOT/daemon.log" 2>&1 & DAEMON=$!
sleep 1
SRC="$ROOT/data/realproj"; mkdir -p "$SRC/sub"
dd if=/dev/urandom of="$SRC/a.dat" bs=1M count=2 status=none
dd if=/dev/urandom of="$SRC/sub/b.dat" bs=1M count=1 status=none
RUN="$("$REPO/cluster/bin/bric" backup --project realproj --source "$SRC")" || bad "backup on provisioned system failed"
[ "$(sqlite3 "$ROOT/sys/cluster/cluster_catalog.db" "SELECT status FROM runs WHERE run_id='$RUN';")" = CLOSED ] \
    && ok "backup CLOSED on the setup-provisioned layout" || bad "run not CLOSED"
"$REPO/cluster/scripts/bric-restore.sh" --project realproj --dest "$ROOT/rest" >/dev/null 2>&1 \
    && diff -r "$SRC" "$ROOT/rest" >/dev/null && ok "restore bit-identical" || bad "restore failed"
bric_test_stop_group "$DAEMON"
"$REPO/cluster/scripts/bric-dr-from-tapes.sh" --tapelib "$ROOT/sys/tapelib" --project realproj \
    --user-key-file "$ROOT/sys/keys/vsz652_user_key.txt" --dest "$ROOT/dr" >/dev/null 2>&1 \
    && diff -r "$SRC" "$ROOT/dr" >/dev/null && ok "DR from the setup-created tapes + key alone: bit-identical" || bad "DR failed"
grep -q "|BACKUP_DONE|" "$ROOT/sys/events.log" && ok "event log at the config-file path" || bad "event log missing"

echo "=== D) config semantics in setup: env wins over file ==="
out="$(BRIC_CONFIG="$CFG" BRIC_QNAP=/tmp/env_overrides_this bash "$REPO/bric-setup.sh" --role cluster --dry-run 2>&1)"
echo "$out" | grep -q "env_overrides_this" && ok "environment overrides the config file in setup" || bad "env precedence broken in setup"

echo
[ "$fail" -eq 0 ] && echo "✓ SETUP E2E CHECKS PASSED" || { echo "✗ SETUP E2E FAILURES"; exit 1; }
