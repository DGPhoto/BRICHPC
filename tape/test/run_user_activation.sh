#!/bin/bash
# One-command activation wrapper regression: clean environment, canonical onboarding,
# escrow/key/ACL verification, idempotency and a real `bric status` as the target NSS user.
set -euo pipefail
IFS=$'\n\t'
REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
ok(){ echo "  ok: $*"; }
bad(){ echo "  FAIL: $*"; exit 1; }

if [ "$(id -u)" -ne 0 ]; then
    echo "  ok: root-only activation test skipped for non-root suite invocation"
    exit 0
fi
command -v runuser >/dev/null 2>&1 || { echo "  ok: runuser unavailable; activation test skipped"; exit 0; }
TEST_USER="${BRIC_TEST_OS_USER:-nobody}"
PW="$(getent passwd "$TEST_USER" || true)"
[ -n "$PW" ] || { echo "  ok: NSS user '$TEST_USER' unavailable; activation test skipped"; exit 0; }
IFS=: read -r _ _ U G _ _ _ <<EOF_PW
$PW
EOF_PW
[ "$U" != 0 ] || { echo "  ok: refusing uid0 activation test"; exit 0; }

ROOT="$(mktemp -d)"; chmod 711 "$ROOT"; trap 'rm -rf "$ROOT"' EXIT
HOME_TEST="$ROOT/home"; mkdir -p "$HOME_TEST"; chown "$U:$G" "$HOME_TEST"; chmod 700 "$HOME_TEST"
DBDIR="$ROOT/db"; mkdir -p "$DBDIR"
DB="$DBDIR/cluster.db"
ADMIN="$ROOT/admin"; mkdir -p "$ADMIN"; chmod 700 "$ADMIN"
QNAP="$ROOT/qnap/bric"; mkdir -p "$QNAP"; chown -R "$U:$G" "$ROOT/qnap"; chmod 700 "$ROOT/qnap" "$QNAP"
LOGROOT="$ROOT/log"; mkdir -p "$LOGROOT"; chmod 777 "$LOGROOT"

sqlite3 "$DB" < "$REPO/cluster/sql/cluster_init.sql" >/dev/null
head -c 32 /dev/urandom | base64 > "$ADMIN/master.key"; chmod 400 "$ADMIN/master.key"
CONF="$ROOT/bric.conf"
cat > "$CONF" <<EOF_CONF
BRIC_ROLE=slurm
BRIC_HOME=$REPO/cluster
BRIC_DB=$DB
BRIC_QNAP=$QNAP
BRIC_QNAP_MNT=$ROOT/qnap
BRIC_REQUIRE_NFS_BUS=0
BRIC_ADMIN_KEYS=$ADMIN
BRIC_KEYS=$ADMIN
BRIC_MASTER_KEY_FILE=$ADMIN/master.key
BRIC_REQUIRE_LOGGING=0
BRIC_LOG_DIR=$LOGROOT
BRIC_USER_LOG_ROOT=$LOGROOT/users
BRIC_LOG_ADMIN_GROUP=root
BRIC_LOG_GROUP=root
BRIC_LOG_FALLBACK_DIR=$LOGROOT/fallback
BRIC_COMMAND_LINK=$REPO/cluster/bin/bric
EOF_CONF
chmod 644 "$CONF"

ACT="$REPO/cluster/bin/bric-activate-user"
OUT="$ROOT/out"; ERR="$ROOT/err"

echo "=== activation under deliberately contaminated environment ==="
if BRIC_ROLE=tape BRIC_DB=/definitely/wrong BRIC_BUS_SIGN_KEY=/wrong \
   "$ACT" --config "$CONF" --user "$TEST_USER" --home "$HOME_TEST" >"$OUT" 2>"$ERR"; then
    ok "one command activated the user despite inherited BRIC contamination"
else
    cat "$OUT" "$ERR"; bad "activation failed"
fi

grep -q 'BRIC activation complete' "$OUT" || bad "completion summary missing"
KEY="$HOME_TEST/.bric/${TEST_USER}_user_key.txt"
[ -s "$KEY" ] || bad "home key missing"
[ "$(stat -c %a "$KEY")" = 600 ] || bad "home key permissions wrong"
head -n 1 "$HOME_TEST/.bric/env.sh" | grep -q '^# BRIC-MANAGED-FILE ' \
    || bad "managed environment marker missing"
case "$(sqlite3 "$DB" "SELECT key_escrow FROM users WHERE username='$TEST_USER';")" in v2:*) :;; *) bad "v2 escrow missing";; esac
ok "key, private home and authenticated escrow created"
ENVF="$HOME_TEST/.bric/env.sh"
CENTRAL="$LOGROOT/users/$TEST_USER"
grep -Fqx "export BRIC_LOG_DIR=$CENTRAL" "$ENVF" || bad "activation did not configure central user log primary"
grep -Fqx "export BRIC_LOG_FALLBACK_DIR=$HOME_TEST/.bric/log" "$ENVF" || bad "activation did not retain private log fallback"
[ "$(stat -c %u "$CENTRAL")" = "$U" ] || bad "activation central log owner wrong"
getfacl -cp "$CENTRAL" | grep -q '^group:root:r-x' || bad "activation central log admin ACL missing"
getfacl -cp "$CENTRAL" | grep -q '^group::---' || bad "activation central log owning-group isolation missing"
ok "central user logging provisioned with private fallback"

K1="$(sha256sum "$KEY" | awk '{print $1}')"
"$ACT" --config "$CONF" "$TEST_USER" --home "$HOME_TEST" >"$ROOT/out2" 2>"$ROOT/err2" \
    || { cat "$ROOT/out2" "$ROOT/err2"; bad "idempotent activation failed"; }
[ "$(sha256sum "$KEY" | awk '{print $1}')" = "$K1" ] || bad "idempotent activation rotated the key"
ok "idempotent rerun preserved the exact user key"

ACTIVATION_JOURNAL_BASE="${BRIC_RESTORE_JOURNAL_ROOT:-$ROOT/journal-base}"
mkdir -p "$ACTIVATION_JOURNAL_BASE"; chmod 1777 "$ACTIVATION_JOURNAL_BASE"
runuser -u "$TEST_USER" -- env -i BRIC_RESTORE_JOURNAL_ROOT="$ACTIVATION_JOURNAL_BASE" HOME="$HOME_TEST" USER="$TEST_USER" LOGNAME="$TEST_USER" \
    PATH=/usr/local/bin:/usr/bin:/bin "$REPO/cluster/bin/bric" status >/dev/null \
    || bad "activated user cannot run bric status"
ok "activated identity can use the BRIC CLI"

echo "PASS run_user_activation"
