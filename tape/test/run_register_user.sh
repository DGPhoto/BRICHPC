#!/bin/bash
. "$(cd "$(dirname "$(readlink -f "$0")")" && pwd)/lib_test_daemon.sh"
# User key generation via the ONE canonical path (bric-register-user):
#   A) fresh registration: key generated (mode 600, 44-char base64), escrow row present, and the
#      escrow SELF-UNWRAPS with the master key back to the exact key
#   B) handout sheet produced (mode 600), contains the key line and the DR instructions
#   C) idempotent re-run: the key does NOT change, escrow is refreshed
#   D) batch --users-file: N users registered, comments/blanks ignored, each with escrow + handout
#   E) --no-handout suppresses the sheet
#   F) end-to-end proof: a key generated here archives AND disaster-recovers a project
set -uo pipefail
export BRIC_CONFIG=none   # hermetic: never read /etc/bric/bric.conf inside tests
REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
ROOT="$(mktemp -d)"
echo "workroot=$ROOT"
fail=0; ok() { echo "  ok: $*"; }; bad() { echo "  FAIL: $*"; fail=1; }

export BRIC_HOME="$REPO/cluster" BRIC_DB="$ROOT/c.db" BRIC_QNAP="$ROOT/qnap/bric"
export BRIC_KEYS="$ROOT/keys" BRIC_SQL_INIT="$REPO/cluster/sql/cluster_init.sql"
export BRIC_USER="alice1" BRIC_RUN_MODE="local"
export BRIC_RESERVE_TIMEOUT=40 BRIC_DRAIN_TIMEOUT=60 BRIC_CLOSE_TIMEOUT=60 BRIC_POLL=1
export BRIC_TAPE_HOME="$REPO/tape" BRIC_TAPE_DB="$ROOT/t.db" BRIC_TAPE_SQL_INIT="$REPO/tape/sql/tape_init.sql"
export BRIC_TAPE_BACKEND="sim" BRIC_TAPELIB="$ROOT/tapelib" BRIC_TAPE_LOCK="$ROOT/tape.lock"

mkdir -p "$BRIC_QNAP" "$BRIC_KEYS" "$BRIC_TAPELIB"
chmod +x "$REPO"/cluster/scripts/*.sh "$REPO"/cluster/bin/bric "$REPO"/tape/bin/bric-tape-daemon 2>/dev/null || true
sqlite3 "$BRIC_DB" < "$BRIC_SQL_INIT" >/dev/null
sqlite3 "$BRIC_TAPE_DB" < "$BRIC_TAPE_SQL_INIT" >/dev/null
sqlite3 "$BRIC_DB" "UPDATE config SET value='4194304' WHERE key='segment_target_bytes';"
sqlite3 "$BRIC_TAPE_DB" "UPDATE config SET value='1' WHERE key='poll_seconds';"
head -c 32 /dev/urandom | base64 > "$BRIC_KEYS/master.key"; chmod 600 "$BRIC_KEYS/master.key"
sqlite3 "$BRIC_TAPE_DB" "INSERT INTO tapes(volumetag,slot,role,pair_number,paired_volumetag,capacity_tb,used_tb,status)
  VALUES('000000L9',1,'PRIMARY',1,'000001L9',18,0,'EMPTY'),('000001L9',2,'BACKUP',1,'000000L9',18,0,'EMPTY');"
REG="$REPO/cluster/scripts/bric-register-user.sh"
trap 'bric_test_stop_group "${DAEMON:-0}"; [ -n "${KEEP:-}" ] || bric_test_rmrf_retry "$ROOT"' EXIT

echo "=== A) fresh registration ==="
"$REG" --user alice1 >/dev/null 2>&1 || bad "registration failed"
UKF="$BRIC_KEYS/alice1_user_key.txt"
[ -f "$UKF" ] && ok "key file created" || bad "key file missing"
[ "$(stat -c %a "$UKF")" = 600 ] && ok "key file mode 600" || bad "key mode $(stat -c %a "$UKF")"
K="$(cat "$UKF")"
[ "${#K}" = 44 ] && printf '%s' "$K" | base64 -d >/dev/null 2>&1 && ok "key is 32 random bytes, base64 (44 chars)" || bad "key format unexpected: ${#K} chars"
ESC="$(sqlite3 "$BRIC_DB" "SELECT key_escrow FROM users WHERE username='alice1';")"
case "$ESC" in v2:*:*) ok "escrow row present in v2 authenticated format";; *) bad "escrow missing or wrong format";; esac
# independent unwrap with the documented recipe (not via the tool)
HK="$(printf '%s:escrow-auth' "$(cat "$BRIC_KEYS/master.key")" | sha256sum | awk '{print $1}')"
HM="${ESC#v2:}"; HM="${HM%%:*}"; CT="${ESC#v2:*:}"
[ "$(printf '%s' "$CT" | openssl dgst -sha256 -hmac "$HK" | awk '{print $NF}')" = "$HM" ] && ok "escrow HMAC verifies" || bad "escrow HMAC mismatch"
GOT="$(printf '%s' "$CT" | openssl enc -d -aes-256-cbc -pbkdf2 -iter 10000 -a -A -pass file:"$BRIC_KEYS/master.key")"
[ "$GOT" = "$K" ] && ok "escrow unwraps to the exact key with the master key alone" || bad "escrow does not round-trip"

echo "=== B) handout sheet ==="
HOF="$BRIC_KEYS/handouts/alice1_key_handout.txt"
[ -f "$HOF" ] && ok "handout written" || bad "handout missing"
[ "$(stat -c %a "$HOF")" = 600 ] && ok "handout mode 600" || bad "handout mode $(stat -c %a "$HOF")"
grep -qF "$K" "$HOF" && ok "handout contains the key line" || bad "key not in handout"
grep -q "bric-dr-from-tapes.sh" "$HOF" && grep -q "NEVER send it by email" "$HOF" && ok "handout carries DR instructions and storage rules" || bad "handout content incomplete"

echo "=== C) idempotent re-run ==="
"$REG" --user alice1 >/dev/null 2>&1 || bad "re-run failed"
[ "$(cat "$UKF")" = "$K" ] && ok "key UNCHANGED on re-run (no silent rotation)" || bad "KEY CHANGED on re-run!"

echo "=== D) batch --users-file ==="
cat > "$ROOT/users.txt" <<EOF
# team
bob002
   carol3
EOF
"$REG" --users-file "$ROOT/users.txt" >/dev/null 2>&1 || bad "batch registration failed"
for u in bob002 carol3; do
    [ -f "$BRIC_KEYS/${u}_user_key.txt" ] && [ -n "$(sqlite3 "$BRIC_DB" "SELECT key_escrow FROM users WHERE username='$u';")" ] \
        && [ -f "$BRIC_KEYS/handouts/${u}_key_handout.txt" ] \
        && ok "batch: $u registered with escrow + handout" || bad "batch: $u incomplete"
done
[ "$(sqlite3 "$BRIC_DB" "SELECT COUNT(*) FROM users;")" = 3 ] && ok "exactly 3 users (comments/blanks ignored)" || bad "user count wrong"

echo "=== E) --no-handout ==="
"$REG" --user dave44 --no-handout >/dev/null 2>&1 || bad "no-handout registration failed"
[ ! -f "$BRIC_KEYS/handouts/dave44_key_handout.txt" ] && ok "handout suppressed on request" || bad "handout written despite --no-handout"

echo "=== F) the generated key actually archives and disaster-recovers ==="
setsid "$REPO/tape/bin/bric-tape-daemon" --loop >"$ROOT/daemon.log" 2>&1 & DAEMON=$!
sleep 1
SRC="$ROOT/data/alicedata"; mkdir -p "$SRC"; dd if=/dev/urandom of="$SRC/g.dat" bs=1M count=2 status=none
"$REPO/cluster/bin/bric" backup --project alicedata --source "$SRC" >/dev/null || bad "backup with generated key failed"
bric_test_stop_group "$DAEMON"
"$REPO/cluster/scripts/bric-dr-from-tapes.sh" --tapelib "$BRIC_TAPELIB" --project alicedata \
    --user-key-file "$UKF" --dest "$ROOT/dr" >/dev/null 2>&1 \
    && diff -r "$SRC" "$ROOT/dr" >/dev/null 2>&1 \
    && ok "DR from tapes + the generated key alone: bit-identical" || bad "DR with generated key failed"

echo
[ "$fail" -eq 0 ] && echo "✓ USER REGISTRATION CHECKS PASSED" || { echo "✗ USER REGISTRATION FAILURES"; exit 1; }
