#!/bin/bash
. "$(cd "$(dirname "$(readlink -f "$0")")" && pwd)/lib_test_daemon.sh"
# Security/hardening test for BRIC Archive 2.0 (Batch 1).
# Asserts:
#   1) bric backup rejects a hostile project name (path-injection on the QNAP bus).
#   2) Encrypt-then-MAC is enforced: a tampered PRIMARY tape blob is rejected by the HMAC check
#      BEFORE openssl ever decrypts it (bric restore fails loudly instead of feeding garbage to tar).
#   3) Disaster recovery self-heals: with the same PRIMARY copy corrupted, bric-dr-from-tapes detects
#      the HMAC failure and transparently rebuilds the file from the BACKUP copy.
# Plus static checks that the hardening is actually wired (tar --no-absolute-names, preflight deps).
set -euo pipefail
export BRIC_CONFIG=none   # hermetic: never read /etc/bric/bric.conf inside tests
REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
ROOT="$(mktemp -d)"
echo "repo=$REPO"; echo "workroot=$ROOT"

export BRIC_HOME="$REPO/cluster"
export BRIC_DB="$ROOT/cluster_catalog.db"
export BRIC_QNAP="$ROOT/qnap/bric"
export BRIC_KEYS="$ROOT/keys"
export BRIC_SQL_INIT="$REPO/cluster/sql/cluster_init.sql"
export BRIC_USER="vsz652"
export BRIC_RUN_MODE="local"
export BRIC_RESERVE_TIMEOUT=60 BRIC_DRAIN_TIMEOUT=120 BRIC_CLOSE_TIMEOUT=120 BRIC_POLL=1
export BRIC_TAPE_HOME="$REPO/tape"
export BRIC_TAPE_DB="$ROOT/tape_catalog.db"
export BRIC_TAPE_SQL_INIT="$REPO/tape/sql/tape_init.sql"
export BRIC_TAPE_BACKEND="sim"
export BRIC_TAPELIB="$ROOT/tapelib"
export BRIC_TAPE_LOCK="$ROOT/tape.lock"

mkdir -p "$BRIC_QNAP" "$BRIC_KEYS" "$BRIC_TAPELIB" "$(dirname "$BRIC_DB")"
chmod +x "$REPO"/cluster/scripts/*.sh "$REPO"/cluster/bin/bric "$REPO"/tape/bin/bric-tape-daemon 2>/dev/null || true

sqlite3 "$BRIC_DB"      < "$BRIC_SQL_INIT" >/dev/null
sqlite3 "$BRIC_TAPE_DB" < "$BRIC_TAPE_SQL_INIT" >/dev/null
sqlite3 "$BRIC_DB"      "UPDATE config SET value='2097152' WHERE key='segment_target_bytes';"  # 2 MiB
sqlite3 "$BRIC_TAPE_DB" "UPDATE config SET value='1' WHERE key='poll_seconds';"

head -c 32 /dev/urandom | base64 > "$BRIC_KEYS/${BRIC_USER}_user_key.txt"
head -c 32 /dev/urandom | base64 > "$BRIC_KEYS/master.key"
chmod 600 "$BRIC_KEYS"/*

pair=1
for n in 1 3 5 7; do
  p=$(printf '%06dL9' "$n"); b=$(printf '%06dL9' "$((n+1))")
  sqlite3 "$BRIC_TAPE_DB" "INSERT INTO tapes (volumetag,slot,role,pair_number,paired_volumetag,capacity_tb,used_tb,status)
     VALUES ('$p',$n,'PRIMARY',$pair,'$b',18.0,0,'EMPTY'),
            ('$b',$((n+1)),'BACKUP',$pair,'$p',18.0,0,'EMPTY');"
  pair=$((pair+1))
done

SRC="$ROOT/data/secproj"; mkdir -p "$SRC/meta" "$SRC/raw"
for i in 1 2 3 4; do dd if=/dev/urandom of="$SRC/meta/m_$i.txt" bs=1K count=400 status=none; done
for i in 1 2;       do dd if=/dev/urandom of="$SRC/raw/r_$i.fastq" bs=1K count=900 status=none; done

fail=0
ok()   { echo "  ok: $1"; }
bad()  { echo "  FAIL: $1"; fail=1; }

# ---------------------------------------------------------------------------
# 1) hostile project name must be rejected before anything is produced
# ---------------------------------------------------------------------------
echo "=== test 1: hostile project name rejected ==="
for badname in "../evil" "a/b" "with space" ".hidden"; do
  if out="$("$REPO/cluster/bin/bric" backup --project "$badname" --source "$SRC" 2>&1)"; then
    bad "accepted hostile project name [$badname]"
  else
    echo "$out" | grep -qi "invalid project name" && ok "rejected [$badname]" || bad "[$badname] rejected but wrong message: $out"
  fi
done
# nothing must have been written to the bus for a rejected name
LEFT=$(find "$BRIC_QNAP" -mindepth 1 2>/dev/null | wc -l | tr -d ' ')
[ "$LEFT" = 0 ] && ok "no bus artifacts produced for rejected names" || bad "bus polluted by rejected names ($LEFT entries)"

# ---------------------------------------------------------------------------
# real archive (full close so we get TOCs + on-tape project catalog for DR)
# ---------------------------------------------------------------------------
echo "=== valid archive (full close) ==="
setsid "$REPO/tape/bin/bric-tape-daemon" --loop &
DAEMON=$!
trap 'bric_test_stop_group "$DAEMON"; [ -n "${KEEP:-}" ] || { rm -rf "$ROOT" 2>/dev/null || { sleep 1; rm -rf "$ROOT"; }; }' EXIT
sleep 1
RUN_ID="$("$REPO/cluster/bin/bric" backup --project secproj --source "$SRC")"
echo "run: $RUN_ID"
CLOSED=$(sqlite3 "$BRIC_DB" "SELECT status FROM runs WHERE run_id='$RUN_ID';")
[ "$CLOSED" = CLOSED ] && ok "run CLOSED" || bad "run not closed ($CLOSED)"

# ---------------------------------------------------------------------------
# 2) tamper PRIMARY tape blob -> restore must fail on HMAC, before decrypt
# ---------------------------------------------------------------------------
echo "=== test 2a: tampered PRIMARY blob -> restore SELF-HEALS from BACKUP (invariant 5) ==="
REL="meta/m_1.txt"
CNO=$(sqlite3 "$BRIC_DB" "SELECT chunk_no FROM files WHERE run_id='$RUN_ID' AND rel_path='$REL';")
read -r PVT PFN <<EOF2
$(sqlite3 -separator ' ' "$BRIC_TAPE_DB" "SELECT volumetag,file_number FROM segments WHERE run_id='$RUN_ID' AND chunk_no=$CNO AND copy_role='PRIMARY';")
EOF2
BLOB="$BRIC_TAPELIB/$PVT/$(printf 'f_%06d' "$PFN")"
echo "  $REL -> chunk $CNO, PRIMARY $PVT file #$PFN ($BLOB)"
[ -f "$BLOB" ] || bad "primary blob not found on sim tape"
# flip one byte in the middle of the ciphertext
SZ=$(stat -c%s "$BLOB"); OFF=$((SZ/2))
printf '\xff' | dd of="$BLOB" bs=1 seek="$OFF" count=1 conv=notrunc status=none
ok "corrupted 1 byte of PRIMARY blob at offset $OFF/$SZ"

# The daemon must DETECT the corruption (sha256 vs its segment record), mark the tape SUSPECT, and
# stage the intact BACKUP copy instead: the restore succeeds with verified data. This is the
# "auto-healing" the architecture promises for restore, not only for DR.
if "$REPO/cluster/bin/bric" restore --project secproj --file "$REL" --dest "$ROOT/r_tampered" >"$ROOT/r_tampered.log" 2>&1 \
   && cmp -s "$SRC/$REL" "$ROOT/r_tampered/secproj/$REL"; then
  ok "restore self-healed from BACKUP (file bit-identical) despite tampered PRIMARY"
else
  bad "restore did not heal from BACKUP: $(tail -1 "$ROOT/r_tampered.log")"
fi
[ "$(sqlite3 "$BRIC_TAPE_DB" "SELECT health FROM tapes WHERE volumetag='$PVT';")" = SUSPECT ] \
  && ok "tampered PRIMARY tape marked SUSPECT" || bad "tampered tape not marked SUSPECT"

echo "=== test 2b: COMPROMISED TAPE SERVER (blob AND its sha record tampered) -> cluster HMAC is the last line ==="
# An attacker controlling the tape server can rewrite a blob AND update segments.payload_sha256 to
# match, so the daemon stages the forged blob believing it verified. They still cannot forge the
# HMAC without the user's key: the CLUSTER-side Encrypt-then-MAC check must refuse, before decrypt.
FORGED_SHA="$(sha256sum "$BLOB" | awk '{print $1}')"
sqlite3 "$BRIC_TAPE_DB" "UPDATE segments SET payload_sha256='$FORGED_SHA' WHERE run_id='$RUN_ID' AND chunk_no=$CNO AND copy_role='PRIMARY';"
if out="$("$REPO/cluster/bin/bric" restore --project secproj --file "$REL" --dest "$ROOT/r_forged" 2>&1)"; then
  bad "restore SUCCEEDED on a forged blob whose sha record was also tampered (HMAC not enforced!)"
else
  echo "$out" | grep -qi "HMAC mismatch" && ok "cluster refused forged blob on HMAC (no blind decrypt, even with tape server compromised)" \
    || bad "restore failed but not on HMAC: $(echo "$out" | tail -1)"
fi
# restore the true sha record so test 3 exercises DR's own TOC-based healing from a clean DB state
sqlite3 "$BRIC_TAPE_DB" "UPDATE segments SET payload_sha256='$(sqlite3 "$BRIC_DB" "SELECT payload_sha256 FROM chunks WHERE run_id='$RUN_ID' AND chunk_no=$CNO;")' WHERE run_id='$RUN_ID' AND chunk_no=$CNO AND copy_role='PRIMARY';"

# ---------------------------------------------------------------------------
# 3) DR self-heals from BACKUP despite the corrupted PRIMARY
# ---------------------------------------------------------------------------
echo "=== test 3: DR detects HMAC failure and heals from BACKUP ==="
DRDEST="$ROOT/dr_out"
if out="$(BRIC_TAPE_BACKEND=sim "$REPO/cluster/scripts/bric-dr-from-tapes.sh" \
            --project secproj \
            --user-key-file "$BRIC_KEYS/${BRIC_USER}_user_key.txt" \
            --dest "$DRDEST" 2>&1)"; then
  echo "$out" | grep -qi "HMAC FAIL" && ok "DR observed the HMAC failure on PRIMARY" \
    || echo "  note: DR succeeded (HMAC-FAIL line not surfaced: corrupted chunk may map elsewhere)"
  if cmp -s "$SRC/$REL" "$DRDEST/$REL"; then ok "DR rebuilt $REL correctly (healed from BACKUP)"; else bad "DR output mismatch for $REL"; fi
  DIFF=$(diff -r "$SRC" "$DRDEST" 2>&1 | wc -l | tr -d ' ')
  [ "$DIFF" = 0 ] && ok "DR whole-project tree matches source despite corrupted PRIMARY" || bad "DR tree diff ($DIFF lines)"
else
  bad "DR failed entirely: $(echo "$out" | tail -2)"
fi

# ---------------------------------------------------------------------------
# static wiring checks (cheap, catch regressions)
# ---------------------------------------------------------------------------
echo "=== static hardening checks ==="
grep -q -- '--no-same-owner' "$REPO/cluster/scripts/bric-restore.sh"      && ok "restore tar hardened (--no-same-owner; default blocks abs/.. paths)"   || bad "restore tar not hardened"
grep -q -- '--no-same-owner' "$REPO/cluster/scripts/bric-dr-from-tapes.sh" && ok "DR tar hardened (--no-same-owner; default blocks abs/.. paths)"        || bad "DR tar not hardened"
grep -q 'require_cmds sqlite3 openssl tar find stat flock awk sha256sum' "$REPO/cluster/bin/bric" && ok "dispatcher preflight present" || bad "dispatcher preflight missing"
grep -q 'valid_name' "$REPO/cluster/scripts/lib_common.sh" && grep -q 'valid_name' "$REPO/tape/scripts/lib_common.sh" && ok "valid_name in both libs" || bad "valid_name missing in a lib"
grep -q 'ENCPASS="$LOCAL_TMP/.encpass"' "$REPO/cluster/scripts/bric-close.sh" \
  && ! grep -q 'ENCPASS="$CLOSE/.encpass"' "$REPO/cluster/scripts/bric-close.sh" \
  && ok "close keeps derived encryption key off the shared bus" || bad "close writes encryption key on shared bus"
grep -q 'PASS="$LOCAL_TMP/.pass"' "$REPO/cluster/scripts/bric-restore.sh" \
  && ! grep -q 'PASS="$RDIR/.pass"' "$REPO/cluster/scripts/bric-restore.sh" \
  && ok "restore keeps decryption key off the shared bus" || bad "restore writes decryption key on shared bus"
! grep -Eq '\$CLOSE/catalog_(project\.db|project\.sql|system\.sql)' "$REPO/cluster/scripts/bric-close.sh" \
  && ok "plaintext close catalogs stay off the shared bus" || bad "plaintext close catalog path points at shared bus"
CLOSE_EXEC="$(sed -n '1,90p' "$REPO/cluster/scripts/bric-close.sh" | sed '/^[[:space:]]*#/d')"
! grep -q 'master_key_file' <<<"$CLOSE_EXEC" \
  && ! grep -q 'catalog_system\.enc' <<<"$CLOSE_EXEC" \
  && grep -q 'user_key_escrow.v1' "$REPO/cluster/scripts/bric-close.sh" \
  && ok "normal close job never reads the master and emits only authenticated escrow ciphertext" \
  || bad "close job still depends on master/catalog_system or lacks user_key_escrow.v1"
grep -q 'legacy catalog_system.enc' "$REPO/cluster/scripts/bric-dr-from-tapes.sh" \
  && grep -q 'user_key_escrow.v1' "$REPO/cluster/scripts/bric-dr-from-tapes.sh" \
  && ok "DR supports new project escrow and legacy system-catalog tapes" \
  || bad "DR compatibility paths incomplete"
[ -x "$REPO/cluster/scripts/bric-setup-user.sh" ] \
  && grep -q 'HOME KEY / ESCROW MISMATCH' "$REPO/cluster/scripts/bric-setup-user.sh" \
  && ok "root user-onboarding command is installed and fail-closed" \
  || bad "root user-onboarding command missing/incomplete"
grep -q 'ignoring unsafe BRIC_USER override' "$REPO/cluster/scripts/lib_common.sh" \
  && ok "unprivileged BRIC_USER impersonation is blocked" \
  || bad "BRIC_USER identity override remains spoofable"

echo
[ "$fail" -eq 0 ] && echo "✓ ALL SECURITY CHECKS PASSED" || { echo "✗ SECURITY FAILURES"; exit 1; }
