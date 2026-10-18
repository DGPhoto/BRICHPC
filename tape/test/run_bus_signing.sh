#!/bin/bash
. "$(cd "$(dirname "$(readlink -f "$0")")" && pwd)/lib_test_daemon.sh"
# Bus authentication test (symmetric ECDSA P-256). Cluster and tape server each sign what they publish and
# verify the peer. Asserts:
#   1) signed flow works both directions; markers carry .sig; tape RECEIPTS (DONE/CLOSED) are signed too;
#   2) forged UNSIGNED chunk refused before claim/write;
#   3) chunk signed with the WRONG (attacker) key refused;
#   4) forged UNSIGNED reservation refused;
#   5) replay/relocation: a VALID signed READY+meta copied into a foreign run dir is refused (path binding).
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
head -c 32 /dev/urandom | base64 > "$BRIC_KEYS/${BRIC_USER}_user_key.txt"
head -c 32 /dev/urandom | base64 > "$BRIC_KEYS/master.key"; chmod 600 "$BRIC_KEYS"/*
pair=1; for n in 1 3 5 7; do p=$(printf '%06dL9' "$n"); b=$(printf '%06dL9' "$((n+1))")
  sqlite3 "$BRIC_TAPE_DB" "INSERT INTO tapes (volumetag,slot,role,pair_number,paired_volumetag,capacity_tb,used_tb,status) VALUES ('$p',$n,'PRIMARY',$pair,'$b',18.0,0,'EMPTY'),('$b',$((n+1)),'BACKUP',$pair,'$p',18.0,0,'EMPTY');"; pair=$((pair+1)); done

fail=0; ok(){ echo "  ok: $1"; }; bad(){ echo "  FAIL: $1"; fail=1; }

echo "=== bus keygen (two key pairs) ==="
"$REPO/cluster/scripts/bric-bus-keygen.sh" >/dev/null 2>&1
for k in cluster_bus_ecdsa_p256.pem cluster_bus_ecdsa_p256.pub tape_bus_ecdsa_p256.pem tape_bus_ecdsa_p256.pub; do
  [ -f "$BRIC_KEYS/$k" ] || bad "keygen missing $k"; done
# Existence is NOT enough: this used to report "ok" on a host where OpenSSL could create the key
# but could not USE it (too old for ECDSA P-256, FIPS mode, ...), so the real failure surfaced much
# later as an undiagnosable "bus signing failed". Prove a sign+verify round trip here instead, and
# print OpenSSL's own error when it fails.
printf 'roundtrip probe' > "$ROOT/probe.bin"
# Use the SAME primitive the production code uses (openssl dgst -sha256 -sign/-verify). The earlier
# version of this probe used `pkeyutl -rawin`, which does not exist on OpenSSL 1.1.1 — so it
# reported the keys "not usable" on supekgate even though marker_set_signed (which uses dgst) signs
# fine there. A capability probe must exercise the real signing path, not a different one.
if openssl dgst -sha256 -sign "$BRIC_KEYS/cluster_bus_ecdsa_p256.pem" -out "$ROOT/probe.sig" "$ROOT/probe.bin" 2>"$ROOT/probe.err" \
   && openssl dgst -sha256 -verify "$BRIC_KEYS/cluster_bus_ecdsa_p256.pub" -signature "$ROOT/probe.sig" "$ROOT/probe.bin" >/dev/null 2>&1; then
    [ "$fail" = 0 ] && ok "both ECDSA P-256 key pairs generated AND usable (sign+verify round trip)"
else
    bad "ECDSA P-256 keys exist but are NOT usable on this host — $(openssl version 2>/dev/null): $(tr '\n' ' ' < "$ROOT/probe.err" 2>/dev/null)"
    echo "       (bus signing cannot work here; require_bus_signing=1 would block every run)"
fi
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$ROOT/attacker.pem" 2>/dev/null

SRC="$ROOT/data/genome"; mkdir -p "$SRC/raw"
for i in 1 2 3; do dd if=/dev/urandom of="$SRC/raw/r_$i.fastq" bs=1K count=700 status=none; done

# DAEMON gets the TAPE private key + CLUSTER public key (captured at fork). Cluster commands below get
# the CLUSTER private key + TAPE public key via the exported env.
DLOG="$ROOT/daemon.log"
BRIC_BUS_SIGN_KEY="$BRIC_KEYS/tape_bus_ecdsa_p256.pem" BRIC_BUS_VERIFY_KEY="$BRIC_KEYS/cluster_bus_ecdsa_p256.pub" \
  setsid "$REPO/tape/bin/bric-tape-daemon" --loop >"$DLOG" 2>&1 & DAEMON=$!
trap 'bric_test_stop_group "$DAEMON"; [ -n "${KEEP:-}" ] || { rm -rf "$ROOT" 2>/dev/null || { sleep 1; rm -rf "$ROOT"; }; }' EXIT
export BRIC_BUS_SIGN_KEY="$BRIC_KEYS/cluster_bus_ecdsa_p256.pem" BRIC_BUS_VERIFY_KEY="$BRIC_KEYS/tape_bus_ecdsa_p256.pub"
sleep 1
grep -qi "verifying cluster markers" "$DLOG" && grep -qi "signing tape receipts" "$DLOG" && ok "daemon signs receipts AND verifies cluster markers" || bad "daemon did not enable symmetric bus auth"

echo "=== test 1: signed archive + restore round trip (both directions) ==="
RUN_ID="$("$REPO/cluster/bin/bric" backup --project genome --source "$SRC")"
CLOSED=$(sqlite3 "$BRIC_DB" "SELECT status FROM runs WHERE run_id='$RUN_ID';")
[ "$CLOSED" = CLOSED ] && ok "signed run reached CLOSED" || bad "signed run not closed ($CLOSED)"
RUN_DIR="$BRIC_QNAP/archive/genome/$RUN_ID"
[ "$(find "$RUN_DIR" -name '*.sig' | wc -l)" -gt 0 ] && ok "bus markers carry signatures" || bad "no .sig on the bus"
# tape->cluster receipts must be signed by the tape key
[ -f "$RUN_DIR/run.CLOSED.sig" ] && ok "tape receipt run.CLOSED is signed" || bad "run.CLOSED not signed by tape server"
ls "$RUN_DIR"/chunk_*.DONE.sig >/dev/null 2>&1 && ok "tape receipt chunk DONE is signed" || bad "chunk DONE not signed by tape server"
# close manifest present + every artifact VERIFIED on every tape
grep -q '^artifact|catalog_project.enc|CATALOG|' "$RUN_DIR/run.CLOSE_CATALOGS" && ok "signed close manifest present" || bad "no signed close manifest"
NT=$(sqlite3 "$BRIC_TAPE_DB" "SELECT COUNT(DISTINCT volumetag) FROM segments WHERE project_name='genome';")
NBAD=$(sqlite3 "$BRIC_TAPE_DB" "SELECT COUNT(*) FROM (SELECT volumetag,COUNT(*) c FROM tape_artifacts WHERE project_name='genome' AND kind!='TOC' AND state='VERIFIED' GROUP BY volumetag HAVING c<4);")
[ "$NBAD" = 0 ] && [ "$NT" -gt 0 ] && ok "all 4 catalog/script artifacts VERIFIED on every tape" || bad "close artifacts incomplete on some tape"
DEST="$ROOT/restore"; "$REPO/cluster/bin/bric" restore --project genome --dest "$DEST" >/dev/null 2>&1
diff -r "$SRC" "$DEST" >/dev/null 2>&1 && ok "signed restore reconstructed the data" || bad "restore mismatch under signing"

echo "=== test 2: forged unsigned chunk refused ==="
FRD="$BRIC_QNAP/archive/forgery/forgery__20260101T000000Z__0001"; mkdir -p "$FRD"
dd if=/dev/urandom of="$FRD/chunk_0001.enc" bs=1K count=64 status=none
FSHA=$(sha256sum "$FRD/chunk_0001.enc" | awk '{print $1}')
printf 'run_id=forgery__20260101T000000Z__0001\nproject=forgery\nowner=%s\nchunk_no=1\ntype=TAR_PART\nsize_bytes=65536\npayload_sha256=%s\n' "$BRIC_USER" "$FSHA" > "$FRD/chunk_0001.meta"
printf 'sha256=%s\nsize_bytes=65536\n' "$FSHA" > "$FRD/chunk_0001.READY"
sleep 4
[ ! -e "$FRD/chunk_0001.CLAIMED" ] && ok "forged READY never claimed" || bad "daemon claimed a forged chunk"
grep -qi "REFUSED chunk_0001.READY" "$DLOG" && ok "daemon logged the refusal (no signature)" || bad "no refusal logged for forged chunk"

echo "=== test 3: chunk signed with attacker key refused ==="
FRD2="$BRIC_QNAP/archive/forgery/forgery__20260101T000000Z__0002"; mkdir -p "$FRD2"
dd if=/dev/urandom of="$FRD2/chunk_0001.enc" bs=1K count=64 status=none
FSHA2=$(sha256sum "$FRD2/chunk_0001.enc" | awk '{print $1}')
printf 'sha256=%s\nsize_bytes=65536\n' "$FSHA2" > "$FRD2/chunk_0001.READY"
openssl dgst -sha256 -sign "$ROOT/attacker.pem" "$FRD2/chunk_0001.READY" 2>/dev/null | openssl base64 -A > "$FRD2/chunk_0001.READY.sig"
sleep 4
[ ! -e "$FRD2/chunk_0001.CLAIMED" ] && ok "attacker-signed READY never claimed" || bad "daemon claimed an attacker-signed chunk"
grep -qi "BAD signature" "$DLOG" && ok "daemon logged BAD signature for the wrong key" || bad "no BAD-signature log for attacker key"

echo "=== test 4: forged unsigned reservation refused ==="
RRD="$BRIC_QNAP/archive/forgery/forgery__20260101T000000Z__0003"; mkdir -p "$RRD"
printf 'run_id=forgery__20260101T000000Z__0003\nproject=forgery\nowner=%s\nrequested_bytes=1024\nn_chunks=1\n' "$BRIC_USER" > "$RRD/run.RESERVE_REQUEST"
sleep 4
{ [ ! -e "$RRD/run.RESERVED" ] && [ ! -e "$RRD/run.DENIED" ]; } && ok "forged reservation neither granted nor answered" || bad "daemon acted on a forged reservation"

echo "=== test 5: replay/relocation refused (path binding) ==="
# take the genome run's first chunk meta+sig+READY (legit, validly signed) and drop them into a
# DIFFERENT run dir; the signature is valid but no longer matches the path -> must be refused.
VRD="$BRIC_QNAP/archive/genome/genome__20260101T000000Z__9999"; mkdir -p "$VRD"
SRC_CB="$(ls "$RUN_DIR"/chunk_*.meta 2>/dev/null | head -1 | xargs -r basename | sed 's/\.meta$//')"
if [ -n "$SRC_CB" ] && [ -f "$RUN_DIR/$SRC_CB.meta.sig" ]; then
  cp "$RUN_DIR/$SRC_CB.meta" "$RUN_DIR/$SRC_CB.meta.sig" "$VRD/"
  # also need a READY to trigger handle_chunk; reuse the same chunk's READY if present, else fabricate name
  cp "$RUN_DIR/$SRC_CB.READY" "$VRD/" 2>/dev/null || printf 'sha256=x\nsize_bytes=1\n' > "$VRD/$SRC_CB.READY"
  cp "$RUN_DIR/$SRC_CB.READY.sig" "$VRD/" 2>/dev/null || true
  : > "$VRD/$SRC_CB.enc"
  sleep 4
  { [ ! -e "$VRD/$SRC_CB.DONE" ]; } && ok "relocated valid-signed chunk not honored in foreign run dir" || bad "relocation/replay accepted"
  grep -qiE "not bound to its path|BAD signature|REFUSED" "$DLOG" && ok "daemon logged path-binding/sig refusal for relocation" || bad "no refusal logged for relocation"
else
  ok "skipped relocation (no signed meta found to relocate)"
fi

echo "=== test 6: domain separation — a valid .sig is non-transferable across location/name ==="
# A marker with NO path-bound fields, signed in dir A, then its (marker + .sig) copied verbatim into a
# DIFFERENT run dir. Field-binding cannot catch this (there are no fields); only the signed envelope
# (BRIC-MARKER-V1\n<project>/<run>/<name>) does. marker_verify must accept it in A and refuse it in B.
(
  export BRIC_BUS_SIGN_KEY="$BRIC_KEYS/cluster_bus_ecdsa_p256.pem"
  export BRIC_BUS_VERIFY_KEY="$BRIC_KEYS/cluster_bus_ecdsa_p256.pub"
  . "$REPO/cluster/scripts/lib_common.sh"
  A="$BRIC_QNAP/archive/genome/genome__20260101T000000Z__7001"
  B="$BRIC_QNAP/archive/genome/genome__20260101T000000Z__7002"
  Cp="$BRIC_QNAP/archive/otherproj/genome__20260101T000000Z__7001"
  mkdir -p "$A" "$B" "$Cp"
  marker_set_signed "$A" note.MARK "hello=world"
  marker_verify "$A" note.MARK   # rc 0 expected
  vA=$?
  cp "$A/note.MARK" "$A/note.MARK.sig" "$B/"          # same name, different run dir
  cp "$A/note.MARK" "$A/note.MARK.sig" "$Cp/"         # same name+run basename, different PROJECT
  marker_verify "$B"  note.MARK; vB=$?
  marker_verify "$Cp" note.MARK; vC=$?
  cp "$A/note.MARK" "$A/other.MARK"
  cp "$A/note.MARK.sig" "$A/other.MARK.sig"
  marker_verify "$A" other.MARK; vN=$?   # same dir, different NAME
  [ "$vA" = 0 ] && echo "  ok: original marker verifies in its own location" || echo "  FAIL: original did not verify"
  [ "$vB" != 0 ] && echo "  ok: relocation to a different run dir is refused (BAD signature)" || echo "  FAIL: relocation across run dir accepted"
  [ "$vC" != 0 ] && echo "  ok: relocation to a different project is refused" || echo "  FAIL: cross-project relocation accepted"
  [ "$vN" != 0 ] && echo "  ok: re-binding the sig to a different marker name is refused" || echo "  FAIL: name swap accepted"
  [ "$vA" = 0 ] && [ "$vB" != 0 ] && [ "$vC" != 0 ] && [ "$vN" != 0 ]
) || fail=1

echo
[ "$fail" -eq 0 ] && echo "✓ ALL BUS-SIGNING CHECKS PASSED" || { echo "✗ BUS-SIGNING FAILURES"; exit 1; }
