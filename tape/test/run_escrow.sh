#!/bin/bash
. "$(cd "$(dirname "$(readlink -f "$0")")" && pwd)/lib_test_daemon.sh"
# Key-escrow + admin break-glass test for BRIC Archive 2.0 (Batch 3).
# Asserts:
#   1) bric register-user escrows the user key with the master key (recoverable, self-checked).
#   2) require_user_escrow=1 refuses to plan a run for an un-escrowed owner.
#   3) the user-key DR path still works (regression).
#   4) ADMIN break-glass: with ONLY the master key (no user key file at all), an admin reconstructs
#      the project's data from tapes — recovering the owner key from user_key_escrow.v1.
#   5) a WRONG master key cannot decrypt the escrow (no silent garbage).
set -euo pipefail
export BRIC_CONFIG=none   # hermetic: never read /etc/bric/bric.conf inside tests
REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
ROOT="$(mktemp -d)"
echo "repo=$REPO"; echo "workroot=$ROOT"

export BRIC_HOME="$REPO/cluster" BRIC_DB="$ROOT/cluster_catalog.db" BRIC_QNAP="$ROOT/qnap/bric"
export BRIC_KEYS="$ROOT/keys" BRIC_RUNSTATE="$ROOT/runstate"
export BRIC_SQL_INIT="$REPO/cluster/sql/cluster_init.sql" BRIC_USER="vsz652" BRIC_RUN_MODE="local"
export BRIC_RESERVE_TIMEOUT=60 BRIC_DRAIN_TIMEOUT=120 BRIC_CLOSE_TIMEOUT=120 BRIC_POLL=1
export BRIC_TAPE_HOME="$REPO/tape" BRIC_TAPE_DB="$ROOT/tape_catalog.db"
export BRIC_TAPE_SQL_INIT="$REPO/tape/sql/tape_init.sql" BRIC_TAPE_BACKEND="sim"
export BRIC_TAPELIB="$ROOT/tapelib" BRIC_TAPE_LOCK="$ROOT/tape.lock"

mkdir -p "$BRIC_QNAP" "$BRIC_KEYS" "$BRIC_TAPELIB" "$(dirname "$BRIC_DB")"
chmod +x "$REPO"/cluster/scripts/*.sh "$REPO"/cluster/bin/bric "$REPO"/tape/bin/bric-tape-daemon 2>/dev/null || true
sqlite3 "$BRIC_DB"      < "$BRIC_SQL_INIT"      >/dev/null
sqlite3 "$BRIC_TAPE_DB" < "$BRIC_TAPE_SQL_INIT" >/dev/null
sqlite3 "$BRIC_DB"      "UPDATE config SET value='5242880' WHERE key='segment_target_bytes';"
sqlite3 "$BRIC_TAPE_DB" "UPDATE config SET value='1' WHERE key='poll_seconds';"
# the institution master key (held by admin + CEO); NO user key file yet — registration makes it.
head -c 32 /dev/urandom | base64 > "$BRIC_KEYS/master.key"; chmod 600 "$BRIC_KEYS/master.key"
pair=1; for n in 1 3 5 7; do p=$(printf '%06dL9' "$n"); b=$(printf '%06dL9' "$((n+1))")
  sqlite3 "$BRIC_TAPE_DB" "INSERT INTO tapes (volumetag,slot,role,pair_number,paired_volumetag,capacity_tb,used_tb,status) VALUES ('$p',$n,'PRIMARY',$pair,'$b',18.0,0,'EMPTY'),('$b',$((n+1)),'BACKUP',$pair,'$p',18.0,0,'EMPTY');"; pair=$((pair+1)); done

fail=0; ok(){ echo "  ok: $1"; }; bad(){ echo "  FAIL: $1"; fail=1; }

SRC="$ROOT/data/genome"; mkdir -p "$SRC/raw" "$SRC/meta"
for i in 1 2 3 4; do dd if=/dev/urandom of="$SRC/raw/r_$i.fastq" bs=1K count=700 status=none; done
echo "metadata" > "$SRC/meta/info.txt"

# ---------------------------------------------------------------------------
# 1) require_user_escrow=1 must block planning before registration
# ---------------------------------------------------------------------------
echo "=== test: escrow policy blocks un-escrowed owner ==="
sqlite3 "$BRIC_DB" "UPDATE config SET value='1' WHERE key='require_user_escrow';"
if out="$("$REPO/cluster/bin/bric" backup --project genome --source "$SRC" 2>&1)"; then
  bad "planning succeeded without escrow under require_user_escrow=1"
else
  echo "$out" | grep -qi "no key escrow" && ok "planning refused: owner not escrowed" || bad "refused but wrong reason: $(echo "$out" | tail -1)"
fi
[ -z "$(find "$BRIC_QNAP" -mindepth 1 2>/dev/null)" ] && ok "nothing produced for the blocked run" || bad "bus polluted by blocked run"

# ---------------------------------------------------------------------------
# 2) register-user escrows the key (and generates one, since none exists yet)
# ---------------------------------------------------------------------------
echo "=== test: register-user escrows the key ==="
"$REPO/cluster/bin/bric" register-user --user "$BRIC_USER" 2>"$ROOT/reg.err" || { cat "$ROOT/reg.err"; bad "register-user failed"; }
[ -f "$BRIC_KEYS/${BRIC_USER}_user_key.txt" ] && ok "user key file created" || bad "user key file missing"
ESC="$(sqlite3 "$BRIC_DB" "SELECT key_escrow FROM users WHERE username='$BRIC_USER';")"
[ -n "$ESC" ] && ok "escrow row present in catalog" || bad "no escrow row"
# escrow must NOT be plaintext; must be authenticated (v2:<hmac>:<ct>) and unwrap to the real key
RAW="$(cat "$BRIC_KEYS/${BRIC_USER}_user_key.txt")"
[ "$ESC" != "$RAW" ] && ok "escrow is not plaintext" || bad "escrow stored in plaintext!"
case "$ESC" in v2:*) ok "escrow is authenticated (Encrypt-then-MAC v2)";; *) bad "escrow is not in authenticated v2 format";; esac
EBODY="${ESC#v2:}"; EHMAC="${EBODY%%:*}"; ECT="${EBODY#*:}"
MHK="$(printf '%s:escrow-auth' "$(cat "$BRIC_KEYS/master.key")" | sha256sum | awk '{print $1}')"
WANT="$(printf '%s' "$ECT" | openssl dgst -sha256 -hmac "$MHK" | awk '{print $NF}')"
[ "$EHMAC" = "$WANT" ] && ok "escrow HMAC matches" || bad "escrow HMAC does not match"
UNW="$(printf '%s' "$ECT" | openssl enc -d -aes-256-cbc -pbkdf2 -iter 10000 -a -A -pass file:"$BRIC_KEYS/master.key" 2>/dev/null || true)"
[ "$UNW" = "$RAW" ] && ok "escrow unwraps with master key to the real user key" || bad "escrow does not unwrap correctly"
# A WRONG master key must be rejected deterministically by the authenticated v2 unwrap path.
# Do NOT test raw AES-CBC decryption here: a wrong key can rarely produce valid PKCS#7 padding and
# make `openssl enc -d` return rc=0 even though the plaintext is garbage.  The BRIC contract is the
# Encrypt-then-MAC envelope, so exercise master_unwrap exactly as production DR does.
echo "not-the-master" > "$ROOT/wrong.key"
if printf '%s' "$ESC" | BRIC_CONFIG=none BRIC_DB="$BRIC_DB" BRIC_KEYS="$BRIC_KEYS" \
     bash -c '. "'$REPO'/cluster/scripts/lib_common.sh"; master_unwrap "'$ROOT'/wrong.key"' \
     >/dev/null 2>&1; then
  bad "authenticated escrow accepted the WRONG master key"
else ok "wrong master key rejected by authenticated escrow before decrypt"; fi
# #2: a tampered wrapped key must be caught by the HMAC (not surface as garbage at break-glass)
ECT_BAD="$(printf '%s' "$ECT" | sed 's/./X/1')"   # flip the first base64 char
WANT_BAD="$(printf '%s' "$ECT_BAD" | openssl dgst -sha256 -hmac "$MHK" | awk '{print $NF}')"
[ "$WANT_BAD" != "$EHMAC" ] && ok "tampering the wrapped key invalidates the stored HMAC (break-glass would refuse it)" || bad "tampered escrow still matched the HMAC"

# ---------------------------------------------------------------------------
# archive + close (now allowed: owner is escrowed). Remove the master BEFORE the user-owned close:
# Review 30F must prove that no normal archive job needs or can read it.
# ---------------------------------------------------------------------------
echo "=== archive (full close, master absent from user runtime) ==="
ADMINKEYS="$ROOT/adminkeys"; mkdir -p "$ADMINKEYS"; cp "$BRIC_KEYS/master.key" "$ADMINKEYS/master.key"
rm -f "$BRIC_KEYS/master.key"
setsid "$REPO/tape/bin/bric-tape-daemon" --loop & DAEMON=$!
trap 'bric_test_stop_group "$DAEMON"; [ -n "${KEEP:-}" ] || { rm -rf "$ROOT" 2>/dev/null || { sleep 1; rm -rf "$ROOT"; }; }' EXIT
sleep 1
RUN_ID="$("$REPO/cluster/bin/bric" backup --project genome --source "$SRC")"
CLOSED=$(sqlite3 "$BRIC_DB" "SELECT status FROM runs WHERE run_id='$RUN_ID';")
[ "$CLOSED" = CLOSED ] && ok "run CLOSED (escrowed owner, no master in user runtime)" || bad "run not closed ($CLOSED)"
TOCFILE="$(find "$BRIC_TAPELIB" -type f -name 'f_*' -print0 | xargs -0 grep -l '^# BRIC tape TOC v1$' 2>/dev/null | head -1 || true)"
[ -n "$TOCFILE" ] && grep -q 'user_key_escrow.v1' "$TOCFILE"   && ok "project-bound escrow artifact is present on tape" || bad "user_key_escrow.v1 missing from tape TOC"
if [ -n "$TOCFILE" ] && grep -q 'catalog_system.enc' "$TOCFILE"; then bad "new close still wrote catalog_system.enc"
else ok "new close did not require/write a master-encrypted system catalog"; fi

# ---------------------------------------------------------------------------
# 3) regression: user-key DR still works
# ---------------------------------------------------------------------------
echo "=== test: user-key DR (regression) ==="
DRU="$ROOT/dr_user"
if BRIC_TAPE_BACKEND=sim "$REPO/cluster/scripts/bric-dr-from-tapes.sh" --project genome \
      --user-key-file "$BRIC_KEYS/${BRIC_USER}_user_key.txt" --dest "$DRU" >/dev/null 2>&1; then
  diff -r "$SRC" "$DRU" >/dev/null 2>&1 && ok "user-key DR reconstructed the project" || bad "user-key DR tree mismatch"
else bad "user-key DR failed"; fi

# ---------------------------------------------------------------------------
# 4) ADMIN break-glass: ONLY the master key, no user key file anywhere
# ---------------------------------------------------------------------------
echo "=== test: ADMIN break-glass recovery with master key only ==="
# prove independence from the user key file: the admin directory has ONLY the master key copied
# before the close; the user runtime no longer has any master file.
DRA="$ROOT/dr_admin"
if out="$(BRIC_TAPE_BACKEND=sim "$REPO/cluster/scripts/bric-dr-from-tapes.sh" --project genome \
      --master-key-file "$ADMINKEYS/master.key" --dest "$DRA" 2>&1)"; then
  echo "$out" | grep -qi "break-glass: recovered owner" && ok "admin recovered owner key from escrow via master" || bad "no break-glass recovery log line"
  diff -r "$SRC" "$DRA" >/dev/null 2>&1 && ok "ADMIN rebuilt the FULL project from tapes with only the master key" || bad "admin DR tree mismatch"
else
  bad "admin break-glass DR failed: $(echo "$out" | tail -2)"
fi

# ---------------------------------------------------------------------------
# 5) wrong master key must not silently recover
# ---------------------------------------------------------------------------
echo "=== test: wrong master key is rejected by admin DR ==="
cp "$ROOT/wrong.key" "$ADMINKEYS/master.key"
if BRIC_TAPE_BACKEND=sim "$REPO/cluster/scripts/bric-dr-from-tapes.sh" --project genome \
      --master-key-file "$ADMINKEYS/master.key" --dest "$ROOT/dr_wrong" >/dev/null 2>&1; then
  bad "admin DR SUCCEEDED with the wrong master key"
else ok "admin DR refused the wrong master key"; fi

echo
[ "$fail" -eq 0 ] && echo "✓ ALL ESCROW / BREAK-GLASS CHECKS PASSED" || { echo "✗ ESCROW FAILURES"; exit 1; }
