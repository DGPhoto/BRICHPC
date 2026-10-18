#!/bin/bash
. "$(cd "$(dirname "$(readlink -f "$0")")" && pwd)/lib_test_daemon.sh"
# Disaster-recovery end-to-end: archive a project, then DESTROY both catalogs, the QNAP bus and all
# keys EXCEPT the user's own key, and reconstruct the whole project from the tapes alone.
set -euo pipefail
export BRIC_CONFIG=none   # hermetic: never read /etc/bric/bric.conf inside tests
REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
ROOT="$(mktemp -d)"
echo "workroot=$ROOT"

export BRIC_HOME="$REPO/cluster" BRIC_DB="$ROOT/cluster_catalog.db" BRIC_QNAP="$ROOT/qnap/bric"
export BRIC_KEYS="$ROOT/keys" BRIC_SQL_INIT="$REPO/cluster/sql/cluster_init.sql"
export BRIC_USER="vsz652" BRIC_RUN_MODE="local"
export BRIC_RESERVE_TIMEOUT=60 BRIC_DRAIN_TIMEOUT=120 BRIC_CLOSE_TIMEOUT=120 BRIC_POLL=1
export BRIC_TAPE_HOME="$REPO/tape" BRIC_TAPE_DB="$ROOT/tape_catalog.db" BRIC_TAPE_SQL_INIT="$REPO/tape/sql/tape_init.sql"
export BRIC_TAPE_BACKEND="sim" BRIC_TAPELIB="$ROOT/tapelib" BRIC_TAPE_LOCK="$ROOT/tape.lock"

mkdir -p "$BRIC_QNAP" "$BRIC_KEYS" "$BRIC_TAPELIB" "$(dirname "$BRIC_DB")"
chmod +x "$REPO"/cluster/scripts/*.sh "$REPO"/cluster/bin/bric "$REPO"/tape/bin/bric-tape-daemon 2>/dev/null || true
sqlite3 "$BRIC_DB" < "$BRIC_SQL_INIT" >/dev/null
sqlite3 "$BRIC_TAPE_DB" < "$BRIC_TAPE_SQL_INIT" >/dev/null
sqlite3 "$BRIC_DB" "UPDATE config SET value='4194304' WHERE key='segment_target_bytes';"   # 4 MiB
sqlite3 "$BRIC_TAPE_DB" "UPDATE config SET value='1' WHERE key='poll_seconds';"

head -c 32 /dev/urandom | base64 > "$BRIC_KEYS/${BRIC_USER}_user_key.txt"
head -c 32 /dev/urandom | base64 > "$BRIC_KEYS/master.key"
# The user keeps a copy of THEIR OWN key off-cluster (this is the only secret DR needs).
USERKEY_OFFSITE="$ROOT/my_user_key.txt"; cp "$BRIC_KEYS/${BRIC_USER}_user_key.txt" "$USERKEY_OFFSITE"

pair=1; for n in 1 3; do p=$(printf '%06dL9' "$n"); b=$(printf '%06dL9' "$((n+1))")
  sqlite3 "$BRIC_TAPE_DB" "INSERT INTO tapes(volumetag,slot,role,pair_number,paired_volumetag,capacity_tb,used_tb,status)
    VALUES('$p',$n,'PRIMARY',$pair,'$b',18,0,'EMPTY'),('$b',$((n+1)),'BACKUP',$pair,'$p',18,0,'EMPTY');"; pair=$((pair+1)); done

SRC="$ROOT/data/mouse_rnaseq"; mkdir -p "$SRC/raw" "$SRC/meta"
for i in 1 2 3 4; do dd if=/dev/urandom of="$SRC/raw/s_$i.fastq" bs=1M count=2 status=none; done
for i in 1 2; do dd if=/dev/urandom of="$SRC/meta/m_$i.txt" bs=1K count=128 status=none; done
dd if=/dev/urandom of="$SRC/raw/huge.bam" bs=1M count=10 status=none   # > 4 MiB -> 3 LARGE_FILE_CHUNK pieces
# NUL-safety (#6): filenames containing a newline and a pipe must survive disaster recovery intact.
# A small one packs into a TAR_PART; a large one (>target) drives the LARGE_FILE_CHUNK 'bigrel' path.
printf 'newline-named-payload' > "$SRC/meta/$(printf 'weird\nna|me.txt')"
dd if=/dev/urandom of="$SRC/raw/$(printf 'big\nfile.bam')" bs=1M count=6 status=none
# Restrictive directory holding a LARGE file. Review 33's strongest native path uses mode 000 when
# the suite runs as root, proving that verification/finalization no longer depends on traversing the
# archive-final directory. A non-root suite uses 500 so the source remains readable for backup while
# still denying writes after metadata finalization.
mkdir -p "$SRC/frozen"
dd if=/dev/urandom of="$SRC/frozen/locked.bam" bs=1M count=6 status=none
if [ "$(id -u)" = 0 ]; then chmod 000 "$SRC/frozen"; FROZEN_FINAL_MODE=0; else chmod 500 "$SRC/frozen"; FROZEN_FINAL_MODE=500; fi

setsid "$REPO/tape/bin/bric-tape-daemon" --loop & DAEMON=$!
trap 'bric_test_stop_group "$DAEMON"; [ -n "${KEEP:-}" ] || { chmod -R u+w "$ROOT" 2>/dev/null || true; rm -rf "$ROOT" 2>/dev/null || { sleep 1; rm -rf "$ROOT"; }; }' EXIT
sleep 1
echo "=== archive ==="
RUN_ID="$("$REPO/cluster/bin/bric" backup --project mouse_rnaseq --source "$SRC" 2>/dev/null)"
echo "archived run: $RUN_ID"
bric_test_stop_group "$DAEMON"

# #5 invariant: the plaintext TAPE_TOC must never contain a user file path (those live encrypted in
# catalog_project.enc). Even though we archived files whose names contain a newline and a pipe, no TOC
# may reference them — otherwise a newline would split a TOC record and the pattern parser could misread.
TOCS="$(grep -rl 'BRIC tape TOC v1' "$BRIC_TAPELIB" 2>/dev/null || true)"
if [ -n "$TOCS" ] && ! grep -lE 'me\.txt|file\.bam' $TOCS >/dev/null 2>&1; then
    echo "  ok: TAPE_TOC carries no user path (newline-named files absent from the plaintext index)"
else
    echo "  FAIL: a user filename leaked into the plaintext TAPE_TOC (or no TOC found)"; exit 1
fi

echo "=== SIMULATING DISASTER: deleting both catalogs, the QNAP bus, and all keys but the user's ==="
rm -f "$BRIC_DB"*               # cluster catalog gone
rm -f "$BRIC_TAPE_DB"*          # tape catalog gone
rm -rf "$BRIC_QNAP"             # staging bus gone
rm -rf "$BRIC_KEYS"             # master key + on-cluster user key gone
echo "remaining: only $BRIC_TAPELIB/ (the tapes) and the user's own key copy"
ls "$BRIC_TAPELIB"

# Regression (TOC backward scan): simulate a LATER run in flight when disaster struck — several chunk
# blobs appended AFTER the last TOC on EVERY tape. A fixed scan window used to make such tapes (and
# thus the whole project) invisible to DR; the scan must now walk back to the latest valid TOC.
for vt in "$BRIC_TAPELIB"/*/; do
    vt="${vt%/}"
    for j in 1 2 3 4 5 6; do
        n=$(ls "$vt" | wc -l)
        dd if=/dev/urandom of="$vt/$(printf 'f_%06d' $((n+1)))" bs=64K count=1 status=none
    done
done
echo "appended 6 junk blobs after the last TOC on every tape (in-flight later run)"

echo "=== reconstruct from tapes alone ==="
DR="$ROOT/recovered"
"$REPO/cluster/scripts/bric-dr-from-tapes.sh" --tapelib "$BRIC_TAPELIB" --project mouse_rnaseq \
    --user-key-file "$USERKEY_OFFSITE" --dest "$DR"

echo "=== verify recovered tree == original ==="
if diff -r "$SRC" "$DR" >/dev/null 2>&1; then
    echo "✓ DISASTER RECOVERY PASSED: full project reconstructed from tapes + user key only"
    got_mode="$(stat -c '%a' "$DR/frozen")"
    [ "$got_mode" = "$FROZEN_FINAL_MODE" ] || { echo "✗ restrictive directory final mode mismatch: got=$got_mode want=$FROZEN_FINAL_MODE"; exit 1; }
    echo "✓ Review 33 restrictive directory finalized only after payload verification (mode=$got_mode)"
else
    echo "✗ DR FAILED — differences:"; diff -r "$SRC" "$DR" | head; exit 1
fi

# Regression (extraction order): DR must also succeed WITHOUT root privileges, i.e. the restrictive
# metadata chunk (frozen/ restrictive final mode) must be applied AFTER the large files are written. Root ignores
# permission bits, so when running as root we re-run DR as an unprivileged user to exercise it.
if [ "$(id -u)" = 0 ] && command -v runuser >/dev/null 2>&1 && id nobody >/dev/null 2>&1; then
    DRN="$ROOT/recovered_nobody"; mkdir -p "$DRN"; chmod 777 "$DRN"
    chmod a+x "$ROOT" 2>/dev/null || true   # mktemp -d creates 0700: allow traversal into the workroot
    chmod -R a+rX "$BRIC_TAPELIB" "$USERKEY_OFFSITE" 2>/dev/null || true
    # Run a COPY of the DR script from the workroot: the repo may live under a 0700 home directory
    # (e.g. /home/<operator>/bric2) that 'nobody' cannot traverse — executing from the repo would
    # fail with EACCES before DR even starts. The DR script sources ../../tape/scripts/lib_tape_io.sh
    # relative to itself, so the copy preserves that layout.
    install -D -m 755 "$REPO/cluster/scripts/bric-dr-from-tapes.sh" "$ROOT/drcopy/cluster/scripts/bric-dr-from-tapes.sh"
    install -D -m 644 "$REPO/cluster/scripts/lib_restore_txn.sh"     "$ROOT/drcopy/cluster/scripts/lib_restore_txn.sh"
install -D -m 755 "$REPO/cluster/libexec/bric-file-metadata"       "$ROOT/drcopy/cluster/libexec/bric-file-metadata"
    install -D -m 644 "$REPO/tape/scripts/lib_tape_io.sh"            "$ROOT/drcopy/tape/scripts/lib_tape_io.sh"
    chmod -R a+rX "$ROOT/drcopy"
    if runuser -u nobody -- "$ROOT/drcopy/cluster/scripts/bric-dr-from-tapes.sh" --tapelib "$BRIC_TAPELIB" \
         --project mouse_rnaseq --user-key-file "$USERKEY_OFFSITE" --dest "$DRN/out" >"$ROOT/dr_nobody.log" 2>&1 \
       && diff -r "$SRC" "$DRN/out" >/dev/null 2>&1; then
        echo "✓ unprivileged DR PASSED (read-only frozen/ dir restored after its large file)"
    else
        echo "✗ unprivileged DR FAILED (metadata chunk ordering? EACCES on read-only dir?)"
        echo "--- last lines of the unprivileged DR log:"; tail -5 "$ROOT/dr_nobody.log" 2>/dev/null
        exit 1
    fi
else
    echo "  (skipping unprivileged-DR check: not root or no runuser/nobody)"
fi

echo "=== single-file DR (--file): one TAR_PART file and one LARGE_FILE_CHUNK file ==="
DR1="$ROOT/recovered_one"
"$REPO/cluster/scripts/bric-dr-from-tapes.sh" --tapelib "$BRIC_TAPELIB" --project mouse_rnaseq \
    --user-key-file "$USERKEY_OFFSITE" --dest "$DR1" --file "meta/m_1.txt"
"$REPO/cluster/scripts/bric-dr-from-tapes.sh" --tapelib "$BRIC_TAPELIB" --project mouse_rnaseq \
    --user-key-file "$USERKEY_OFFSITE" --dest "$DR1" --file "raw/huge.bam"
[ "$(sha256sum "$DR1/meta/m_1.txt" | awk '{print $1}')" = "$(sha256sum "$SRC/meta/m_1.txt" | awk '{print $1}')" ] || { echo "✗ single TAR_PART file DR mismatch"; exit 1; }
[ "$(sha256sum "$DR1/raw/huge.bam" | awk '{print $1}')" = "$(sha256sum "$SRC/raw/huge.bam" | awk '{print $1}')" ] || { echo "✗ single LARGE_FILE_CHUNK file DR mismatch"; exit 1; }
[ -f "$DR1/raw/s_1.fastq" ] && { echo "✗ --file leaked other files into the destination"; exit 1; }
echo "✓ single-file DR PASSED (TAR_PART member + reassembled large file, nothing else restored)"
exit 0
