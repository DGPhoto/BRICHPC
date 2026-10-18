#!/bin/bash
# Root onboarding regression: real NSS user, user-owned home key, authenticated escrow, idempotency,
# repair from escrow, and fail-closed mismatch detection. No real user's home is touched.
set -euo pipefail
IFS=$'\n\t'
REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
fail=0
ok(){ echo "  ok: $*"; }
bad(){ echo "  FAIL: $*"; fail=1; }

if [ "$(id -u)" -ne 0 ]; then
    echo "  ok: root-only user onboarding test skipped for non-root suite invocation"
    exit 0
fi
command -v runuser >/dev/null 2>&1 || { echo "  ok: runuser unavailable; onboarding test skipped"; exit 0; }
TEST_USER="${BRIC_TEST_OS_USER:-nobody}"
PW="$(getent passwd "$TEST_USER" || true)"
[ -n "$PW" ] || { echo "  ok: test NSS user '$TEST_USER' unavailable; onboarding test skipped"; exit 0; }
IFS=: read -r _ _ U G _ _ _ <<EOF_PW
$PW
EOF_PW
[ "$U" != 0 ] || { echo "  ok: refusing uid0 onboarding test"; exit 0; }

ROOT="$(mktemp -d)"; chmod 711 "$ROOT"; trap 'rm -rf "$ROOT"' EXIT
HOME_TEST="$ROOT/home"; mkdir -p "$HOME_TEST"; chown "$U:$G" "$HOME_TEST"; chmod 700 "$HOME_TEST"
printf 'USER_SHELL_SENTINEL=unchanged\n' > "$HOME_TEST/.bashrc"
chown "$U:$G" "$HOME_TEST/.bashrc"; chmod 600 "$HOME_TEST/.bashrc"
BASHRC_HASH="$(sha256sum "$HOME_TEST/.bashrc" | awk '{print $1}')"
export BRIC_CONFIG=none BRIC_ROLE=slurm BRIC_HOME="$REPO/cluster"
export BRIC_DB="$ROOT/cluster.db" BRIC_ADMIN_KEYS="$ROOT/admin" BRIC_KEYS="$ROOT/admin"
export BRIC_MASTER_KEY_FILE="$ROOT/admin/master.key" BRIC_REQUIRE_LOGGING=0
export BRIC_LOG_DIR="$ROOT/system-log" BRIC_USER_LOG_ROOT="$ROOT/central-users" BRIC_LOG_ADMIN_GROUP=root BRIC_LOG_GROUP=root
export BRIC_LOCAL_LOCK_ROOT="$ROOT/local-lock-root"
export BRIC_QNAP="$ROOT/qnap/bric" BRIC_REQUIRE_NFS_BUS=0
mkdir -p "$BRIC_ADMIN_KEYS" "$BRIC_QNAP" "$BRIC_LOG_DIR"
chown "$U:$G" "$ROOT/qnap" "$BRIC_QNAP"
chmod 700 "$ROOT/qnap" "$BRIC_QNAP"
sqlite3 "$BRIC_DB" < "$REPO/cluster/sql/cluster_init.sql" >/dev/null
head -c 32 /dev/urandom | base64 > "$BRIC_MASTER_KEY_FILE"; chmod 400 "$BRIC_MASTER_KEY_FILE"
SETUP="$REPO/cluster/scripts/bric-setup-user.sh"

run_setup(){ "$SETUP" --user "$TEST_USER" --home "$HOME_TEST" --no-handout >"$ROOT/setup.out" 2>"$ROOT/setup.err"; }
KEY="$HOME_TEST/.bric/${TEST_USER}_user_key.txt"
ENVF="$HOME_TEST/.bric/env.sh"

echo "=== initial root onboarding ==="
run_setup || { cat "$ROOT/setup.err"; bad "initial onboarding failed"; }
[ -e "$(dirname "$BRIC_DB")/.bric-user-setup.lock" ] && ok "catalog-scoped onboarding lock created" || bad "onboarding lock missing"
[ -s "$KEY" ] && ok "personal key installed in the overridden user home" || bad "personal key missing"
[ -s "$ENVF" ] && ok "per-user environment file installed" || bad "user env missing"
head -n 1 "$ENVF" | grep -q '^# BRIC-MANAGED-FILE ' \
  && ok "user environment is explicitly BRIC-managed" || bad "managed-file marker missing"
[ "$(sha256sum "$HOME_TEST/.bashrc" | awk '{print $1}')" = "$BASHRC_HASH" ] \
  && ok "onboarding did not modify the user shell profile" || bad "user .bashrc changed"
CENTRAL="$BRIC_USER_LOG_ROOT/$TEST_USER"
FALLBACK="$HOME_TEST/.bric/log"
[ -d "$CENTRAL" ] && [ "$(stat -c %u "$CENTRAL")" = "$U" ] \
  && ok "isolated central per-user log root created" || bad "central user log root missing/unsafe"
getfacl -cp "$CENTRAL" | awk -F: '$1=="group" && $2=="" && $3=="---" {ok=1} END{exit !ok}' \
  && getfacl -cp "$CENTRAL" | awk -F: '$1=="group" && $2=="root" && $3 ~ /^r-x/ {ok=1} END{exit !ok}' \
  && getfacl -cp "$CENTRAL" | awk -F: '$1=="default" && $2=="group" && $3=="root" && $4 ~ /^r-x/ {ok=1} END{exit !ok}' \
  && ok "central ACL denies the broad owning group and grants inherited admin read" || bad "central ACL isolation/admin contract wrong"
[ -d "$BRIC_USER_LOG_ROOT" ] && [ "$(stat -c %a "$BRIC_USER_LOG_ROOT")" = 751 ] \
  && ok "central users root is admin-listable but ordinary-user non-listable" || bad "central users root mode wrong"
[ -d "$FALLBACK" ] && [ "$(stat -c %a "$FALLBACK")" = 700 ] \
  && ok "private home fallback created" || bad "private fallback missing/unsafe"
grep -Fqx "export BRIC_LOG_DIR=$CENTRAL" "$ENVF" \
  && grep -Fqx "export BRIC_LOG_FALLBACK_DIR=$FALLBACK" "$ENVF" \
  && grep -Fqx 'export BRIC_LOG_GROUP=root' "$ENVF" \
  && grep -Fqx "export BRIC_BACKGROUND_LOGDIR=$CENTRAL/jobs" "$ENVF" \
  && ok "user env selects central primary and private fallback" || bad "user env logging contract wrong"
LOCAL_LOCK="$BRIC_LOCAL_LOCK_ROOT/$TEST_USER"
grep -Fqx "export BRIC_LOCAL_LOCK_DIR=$LOCAL_LOCK" "$ENVF" \
  && [ -d "$LOCAL_LOCK" ] && [ "$(stat -c %u "$LOCAL_LOCK")" = "$U" ] && [ "$(stat -c %a "$LOCAL_LOCK")" = 700 ] \
  && ok "allocator lock directory is dedicated, user-owned and independent from logging" || bad "local allocator lock deployment contract wrong"
case "$(stat -f -c %T "$LOCAL_LOCK")" in nfs|nfs4|cifs|smb2|9p|fuse.sshfs) bad "allocator lock directory is on a network filesystem";; *) ok "allocator lock directory is host-local";; esac
case "$LOCAL_LOCK/" in "$CENTRAL/"*) bad "allocator lock directory incorrectly derives from central logs";; *) ok "allocator lock path is independent from BRIC_USER_LOG_ROOT";; esac

cat > "$ROOT/user-log-child.sh" <<'CHILD_LOG'
#!/bin/bash
set -euo pipefail
. "$1"
export BRIC_ROLE=slurm BRIC_REQUIRE_LOGGING=1 BRIC_LOG_CAPTURE_STDIO=1
. "$2"
bric_log_process_start user-central-primary
bric_event INFO USER_CENTRAL_PRIMARY 'central user log is primary'
printf '%s|%s\n' "${_BRIC_LOG_LOCATION:-}" "${_BRIC_LOG_CURRENT_ROOT:-}"
CHILD_LOG
chmod 755 "$ROOT/user-log-child.sh"
runuser -u "$TEST_USER" -- "$ROOT/user-log-child.sh" "$ENVF" "$REPO/cluster/scripts/lib_common.sh" \
  >"$ROOT/user-log.out" 2>"$ROOT/user-log.err" || bad "central user logging failed"
grep -Fxq "primary|$CENTRAL" "$ROOT/user-log.out" \
  && ok "user logger selects central per-user primary" || bad "user logger did not select central primary"
! grep -qi 'failover' "$ROOT/user-log.err" || bad "healthy central logging emitted failover"
grep -Rqs '|USER_CENTRAL_PRIMARY|' "$CENTRAL/events" \
  && ok "structured user event written centrally" || bad "central structured event missing"
EVENT_FILE="$(find "$CENTRAL/events" -type f -name '*.events.v1.log' | head -1)"
[ -n "$EVENT_FILE" ] || bad "cannot locate central event file"
cat "$EVENT_FILE" >/dev/null && ok "root/admin can read central user log" || bad "root cannot read central user log"
getfacl -cp "$EVENT_FILE" | awk -F: '$1=="group" && $2=="" && $3=="---" {ok=1} END{exit !ok}' \
  && getfacl -cp "$EVENT_FILE" | awk -F: '$1=="group" && $2=="root" && $3 ~ /^r--/ {ok=1} END{exit !ok}' \
  && getfacl -cp "$EVENT_FILE" | awk -F: '$1=="other" && $2=="" && $3=="---" {ok=1} END{exit !ok}' \
  && ok "actual central event file denies owning group and grants admin read ACL" \
  || bad "actual central event file ACL contract wrong"
for _ in $(seq 1 50); do
  PROCESS_FILE="$(find "$CENTRAL/processes" -type f -name '*.stdout.log' 2>/dev/null | head -1 || true)"
  [ -n "$PROCESS_FILE" ] && break
  sleep 0.02
done
[ -n "${PROCESS_FILE:-}" ] || bad "cannot locate central process stdout log"
if [ -n "${PROCESS_FILE:-}" ]; then
  getfacl -cp "$PROCESS_FILE" | awk -F: '$1=="group" && $2=="" && $3=="---" {ok=1} END{exit !ok}' \
    && getfacl -cp "$PROCESS_FILE" | awk -F: '$1=="group" && $2=="root" && $3 ~ /^r--/ {ok=1} END{exit !ok}' \
    && getfacl -cp "$PROCESS_FILE" | awk -F: '$1=="other" && $2=="" && $3=="---" {ok=1} END{exit !ok}' \
    && ok "actual central process file denies owning group and grants admin read ACL" \
    || bad "actual central process file ACL contract wrong"
fi
OTHER_USER=daemon
if getent passwd "$OTHER_USER" >/dev/null 2>&1 && [ "$(id -u "$OTHER_USER")" != "$U" ]; then
  if runuser -u "$OTHER_USER" -- cat "$EVENT_FILE" >/dev/null 2>&1; then
    bad "another unprivileged user can read $TEST_USER central logs"
  else
    ok "central user logs are isolated from other users"
  fi
fi

# Review 31E5: distinguish a repairable user-leaf mode drift from a real central-root outage.
# The central per-user directory is owned by the archive user, so 31E4+ is expected to repair a
# chmod-only drift by re-applying its ACL contract. Such a repair MUST NOT trigger fallback.
chmod 0550 "$CENTRAL"
runuser -u "$TEST_USER" -- "$ROOT/user-log-child.sh" "$ENVF" "$REPO/cluster/scripts/lib_common.sh" \
  >"$ROOT/selfheal-log.out" 2>"$ROOT/selfheal-log.err" || bad "central ACL self-heal logging failed"
grep -Fxq "primary|$CENTRAL" "$ROOT/selfheal-log.out" \
  && ok "repairable central leaf drift is self-healed and remains primary" || bad "repairable central leaf drift selected fallback"
! grep -qi 'failover' "$ROOT/selfheal-log.err" || bad "repairable central leaf drift emitted failover"
getfacl -cp "$CENTRAL" | awk -F: '$1=="group" && $2=="" && $3=="---" {ok=1} END{exit !ok}' \
  && getfacl -cp "$CENTRAL" | awk -F: '$1=="group" && $2=="root" && $3 ~ /^r-x/ {ok=1} END{exit !ok}' \
  && ok "central leaf ACL contract repaired by runtime" || bad "central leaf ACL self-heal did not restore contract"

# Force a REAL central-primary failure at the root-owned collection directory. The archive user does
# not own BRIC_USER_LOG_ROOT and therefore cannot repair/traverse this outage. The private home tree
# must become fallback and emit both stderr and structured LOG_FAILOVER breadcrumbs.
chmod 0700 "$BRIC_USER_LOG_ROOT"
runuser -u "$TEST_USER" -- "$ROOT/user-log-child.sh" "$ENVF" "$REPO/cluster/scripts/lib_common.sh" \
  >"$ROOT/fallback-log.out" 2>"$ROOT/fallback-log.err" || bad "private fallback logging failed"
grep -Fxq "fallback|$FALLBACK" "$ROOT/fallback-log.out" \
  && ok "private home log activates when root-owned central collection is unavailable" || bad "fallback was not selected"
grep -qi 'failover' "$ROOT/fallback-log.err" || bad "real central failure emitted no failover warning"
grep -Rqs '|USER_CENTRAL_PRIMARY|' "$FALLBACK/events" || bad "fallback structured event missing"
grep -Rqs '|LOG_FAILOVER|' "$FALLBACK/events" \
  && ok "real central failure emitted structured failover breadcrumb" || bad "structured failover breadcrumb missing"
chmod 0751 "$BRIC_USER_LOG_ROOT"

# Legacy pre-31E1 env: only a home fallback existed. Both cluster logging libraries must derive the
# root-provisioned central path from the effective OS identity and retain the home path as fallback.
for LIB in "$REPO/cluster/scripts/lib_common.sh" "$REPO/cluster/scripts/lib_logging.sh"; do
  LEGACY_LOG="$ROOT/legacy-user-log-$(basename "$LIB")"
  mkdir -p "$LEGACY_LOG"; chown "$U:$G" "$LEGACY_LOG"; chmod 700 "$LEGACY_LOG"
  runuser -u "$TEST_USER" -- env -u BRIC_LOG_DIR BRIC_LOG_FALLBACK_DIR="$LEGACY_LOG" BRIC_USER_LOG_ROOT="$BRIC_USER_LOG_ROOT" \
    BRIC_CONFIG=none BRIC_ROLE=slurm BRIC_REQUIRE_LOGGING=1 BRIC_LOG_CAPTURE_STDIO=0 \
    bash -c '. "$1"; bric_log_init; printf "%s|%s|%s\n" "${_BRIC_LOG_LOCATION:-}" "${_BRIC_LOG_CURRENT_ROOT:-}" "${_BRIC_LOG_FALLBACK_ROOT:-}"' _ "$LIB" \
    >"$ROOT/legacy-log.out" 2>"$ROOT/legacy-log.err" || bad "legacy central-log inference failed for $(basename "$LIB")"
  grep -Fxq "primary|$CENTRAL|$LEGACY_LOG" "$ROOT/legacy-log.out" || bad "legacy env did not infer central primary for $(basename "$LIB")"
  ! grep -qi 'failover' "$ROOT/legacy-log.err" || bad "healthy legacy central inference emitted failover for $(basename "$LIB")"
done
ok "pre-31E1 user env infers central primary while preserving private fallback"

[ "$(stat -c %u "$KEY")" = "$U" ] && [ "$(stat -c %g "$KEY")" = "$G" ] && ok "key owned by the real NSS user" || bad "wrong key ownership"
[ "$(stat -c %a "$HOME_TEST/.bric")" = 700 ] && [ "$(stat -c %a "$KEY")" = 600 ] && ok "home key permissions are 0700/0600" || bad "unsafe user key permissions"
[ ! -e "$HOME_TEST/.bric/master.key" ] && ok "master key was not copied to the user" || bad "master key leaked into user home"
! grep -q 'MASTER\|master.key' "$ENVF" && ok "user env contains paths only and no master reference" || bad "user env references the master"
[ ! -e "$BRIC_ADMIN_KEYS/handouts/${TEST_USER}_key_handout.txt" ] && ok "no second plaintext admin handout by default" || bad "default onboarding left an admin plaintext handout"
ESC="$(sqlite3 "$BRIC_DB" "SELECT key_escrow FROM users WHERE username='$TEST_USER';")"
case "$ESC" in v2:*) ok "authenticated v2 escrow written";; *) bad "escrow missing/not v2";; esac
[ "$(sqlite3 "$BRIC_DB" "SELECT value FROM config WHERE key='require_user_escrow';")" = 1 ] && ok "require_user_escrow enabled" || bad "escrow policy not enabled"
K1="$(sha256sum "$KEY" | awk '{print $1}')"

# prove escrow and home key are exactly the same secret
UNW="$(printf '%s' "$ESC" | BRIC_CONFIG=none BRIC_DB="$BRIC_DB" BRIC_KEYS="$BRIC_ADMIN_KEYS" BRIC_MASTER_KEY_FILE="$BRIC_MASTER_KEY_FILE" bash -c '. "'$REPO'/cluster/scripts/lib_common.sh"; master_unwrap "$BRIC_MASTER_KEY_FILE"')"
[ "$(printf '%s\n' "$UNW" | sha256sum | awk '{print $1}')" = "$K1" ] && ok "escrow unwrap matches the home key" || bad "escrow/home mismatch"

# Simulate one pre-31E4 central log file created with the old 0640/primary-group-only policy.
LEGACY_CENTRAL_FILE="$CENTRAL/events/pre31e4-legacy.log"
mkdir -p "$(dirname "$LEGACY_CENTRAL_FILE")"
: > "$LEGACY_CENTRAL_FILE"
chown "$U:$G" "$LEGACY_CENTRAL_FILE"
setfacl -b "$LEGACY_CENTRAL_FILE"
chmod 0640 "$LEGACY_CENTRAL_FILE"

echo "=== idempotent re-run ==="
ENV1="$(sha256sum "$ENVF" | awk '{print $1}')"
BACKUPS1="$(find "$HOME_TEST/.bric" -maxdepth 1 -name 'env.sh.bak.*' | wc -l | tr -d ' ')"
run_setup || bad "idempotent rerun failed"
[ "$(sha256sum "$KEY" | awk '{print $1}')" = "$K1" ] && ok "rerun did not rotate the key" || bad "key changed on rerun"
[ "$(sha256sum "$ENVF" | awk '{print $1}')" = "$ENV1" ] && ok "unchanged managed environment was not rewritten" || bad "idempotent rerun changed env.sh"
[ "$(find "$HOME_TEST/.bric" -maxdepth 1 -name 'env.sh.bak.*' | wc -l | tr -d ' ')" = "$BACKUPS1" ] \
  && ok "unchanged environment created no needless backup" || bad "idempotent rerun created an env backup"
[ "$(sha256sum "$HOME_TEST/.bashrc" | awk '{print $1}')" = "$BASHRC_HASH" ] \
  && ok "rerun still left shell settings untouched" || bad "rerun changed .bashrc"
getfacl -cp "$LEGACY_CENTRAL_FILE" | awk -F: '$1=="group" && $2=="" && $3=="---" {ok=1} END{exit !ok}' \
  && getfacl -cp "$LEGACY_CENTRAL_FILE" | awk -F: '$1=="group" && $2=="root" && $3 ~ /^r--/ {ok=1} END{exit !ok}' \
  && ok "rerun repairs pre-31E4 single-link central log ACLs" || bad "rerun did not repair legacy central log ACL"

echo "=== managed env changes are backed up ==="
runuser -u "$TEST_USER" -- bash -c 'printf "\n# local note preserved in backup\n" >> "$1"' _ "$ENVF"
run_setup || bad "managed env refresh failed"
BACKUP_FILE="$(find "$HOME_TEST/.bric" -maxdepth 1 -name 'env.sh.bak.*' -type f | sort | tail -1)"
[ -n "$BACKUP_FILE" ] && grep -q 'local note preserved in backup' "$BACKUP_FILE" \
  && ok "changed managed env was backed up before refresh" || bad "managed env backup missing user edit"
! grep -q 'local note preserved in backup' "$ENVF" || bad "generated env retained unmanaged content"

echo "=== unmanaged env is never overwritten ==="
cp "$ENVF" "$ROOT/generated-env"
runuser -u "$TEST_USER" -- bash -c 'printf "export PERSONAL_SETTING=keep_me\n" > "$1"' _ "$ENVF"
UNMANAGED_HASH="$(sha256sum "$ENVF" | awk '{print $1}')"
if run_setup; then
  bad "setup overwrote an unmanaged env.sh"
else
  grep -q 'refusing to overwrite unmanaged user file' "$ROOT/setup.err" \
    && ok "unmanaged env.sh refused before overwrite" || bad "unmanaged env refusal lacked diagnosis"
fi
[ "$(sha256sum "$ENVF" | awk '{print $1}')" = "$UNMANAGED_HASH" ] \
  && ok "unmanaged env.sh remained byte-for-byte unchanged" || bad "unmanaged env.sh was modified"
[ "$(sha256sum "$KEY" | awk '{print $1}')" = "$K1" ] \
  && ok "unmanaged env refusal did not rotate the key" || bad "key changed during refused activation"
runuser -u "$TEST_USER" -- bash -c 'cat > "$1"; chmod 600 "$1"' _ "$ENVF" < "$ROOT/generated-env"

echo "=== repair missing home key from escrow ==="
runuser -u "$TEST_USER" -- rm -f "$KEY"
run_setup || bad "repair from escrow failed"
[ "$(sha256sum "$KEY" | awk '{print $1}')" = "$K1" ] && ok "same key restored from escrow" || bad "repair restored a different key"

echo "=== mismatch fails closed ==="
head -c 32 /dev/urandom | base64 > "$ROOT/other.key"
runuser -u "$TEST_USER" -- bash -c 'cat > "$1"' _ "$KEY" < "$ROOT/other.key"
if run_setup; then bad "setup accepted a home key different from escrow"
else grep -q 'HOME KEY / ESCROW MISMATCH' "$ROOT/setup.err" && ok "mismatch refused explicitly" || bad "mismatch failed without expected diagnostic"; fi

# restore the valid key before runtime-gate checks
printf '%s' "$ESC" | BRIC_CONFIG=none BRIC_DB="$BRIC_DB" BRIC_KEYS="$BRIC_ADMIN_KEYS" BRIC_MASTER_KEY_FILE="$BRIC_MASTER_KEY_FILE"   bash -c '. "'$REPO'/cluster/scripts/lib_common.sh"; master_unwrap "$BRIC_MASTER_KEY_FILE"' > "$ROOT/valid.key"
runuser -u "$TEST_USER" -- bash -c 'cat > "$1"; chmod 600 "$1"' _ "$KEY" < "$ROOT/valid.key"

echo "=== runtime access warning vs strict gate ==="
chmod 500 "$BRIC_QNAP"
if run_setup; then grep -q 'cannot currently write' "$ROOT/setup.err" && ok "transient runtime access issue is warned by default" || bad "runtime warning not surfaced"
else bad "default onboarding failed on a transient runtime access issue"; fi
if "$SETUP" --user "$TEST_USER" --home "$HOME_TEST" --no-handout --strict-runtime-checks >"$ROOT/strict.out" 2>"$ROOT/strict.err"; then
  bad "strict runtime gate accepted an unwritable QNAP bus"
else grep -q 'cannot currently write' "$ROOT/strict.err" && ok "strict runtime checks fail closed" || bad "strict runtime failure lacked diagnostic"; fi
chmod 700 "$BRIC_QNAP"


echo "=== unprivileged identity override is ignored ==="
WHO="$(runuser -u "$TEST_USER" -- env BRIC_CONFIG=none BRIC_REQUIRE_LOGGING=0 BRIC_USER=someone_else     bash -c '. "'$REPO'/cluster/scripts/lib_common.sh"; bric_whoami' 2>/dev/null)"
[ "$WHO" = "$TEST_USER" ] && ok "normal user cannot impersonate another archive owner with BRIC_USER"     || bad "unsafe identity override accepted (reported '$WHO')"

echo
[ "$fail" -eq 0 ] && echo "✓ USER ONBOARDING CHECKS PASSED" || { echo "✗ USER ONBOARDING FAILURES"; exit 1; }
