#!/bin/bash
# In-place updater: changed-files only, mutable-state preservation, version commit marker.
set -euo pipefail
IFS=$'\n\t'

REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
EXPECTED_REVIEW="$(sed -n 's/^review=//p' "$REPO/RELEASE")"
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
TARGET="$ROOT/installed"
BACKUPS="$ROOT/backups"
mkdir -p "$TARGET"
CONFIG="$ROOT/bric.conf"
printf 'BRIC_ROLE=slurm\nBRIC_DB=%s\n' "$TARGET/cluster/db/cluster_catalog.db" > "$CONFIG"
cp -a "$REPO/." "$TARGET/"
rm -f "$TARGET/RELEASE" "$TARGET/MANIFEST.sha256"

# Simulate a mixed legacy install and runtime state that must never be touched.
printf 'old readme\n' > "$TARGET/README.md"
printf 'obsolete\n' > "$TARGET/obsolete-managed.txt"
printf '%s  %s\n' "$(sha256sum "$TARGET/obsolete-managed.txt" | awk '{print $1}')" obsolete-managed.txt \
  > "$TARGET/.bric-managed-files"
mkdir -p "$TARGET/cluster/db" "$TARGET/cluster/log/private" "$TARGET/tape/db" "$TARGET/cluster/keys"
printf 'CLUSTER-DB-SENTINEL\n' > "$TARGET/cluster/db/cluster_catalog.db"
printf 'LOG-SENTINEL\n' > "$TARGET/cluster/log/private/event.log"
printf 'TAPE-DB-SENTINEL\n' > "$TARGET/tape/db/tape_catalog.db"
printf 'KEY-SENTINEL\n' > "$TARGET/cluster/keys/private.pem"

touch -t 200101010101 "$TARGET/ARCHITECTURE.md"
before_mtime="$(stat -c %Y "$TARGET/ARCHITECTURE.md")"

"$REPO/bric-update" --config "$CONFIG" --target "$TARGET" \
  --backup-dir "$BACKUPS" --skip-integrations --skip-active-check > "$ROOT/update.log"

grep -q "^review=${EXPECTED_REVIEW}$" "$TARGET/RELEASE"
cmp -s "$REPO/README.md" "$TARGET/README.md"
[ "$(stat -c %Y "$TARGET/ARCHITECTURE.md")" = "$before_mtime" ]
[ ! -e "$TARGET/obsolete-managed.txt" ]
grep -q 'CLUSTER-DB-SENTINEL' "$TARGET/cluster/db/cluster_catalog.db"
grep -q 'LOG-SENTINEL' "$TARGET/cluster/log/private/event.log"
grep -q 'TAPE-DB-SENTINEL' "$TARGET/tape/db/tape_catalog.db"
grep -q 'KEY-SENTINEL' "$TARGET/cluster/keys/private.pem"
find "$BACKUPS" -path '*/files/README.md' -type f | grep -q .
find "$BACKUPS" -path '*/files/obsolete-managed.txt' -type f | grep -q .
"$TARGET/cluster/bin/bric-run" version | grep -q "^review=${EXPECTED_REVIEW}$"
"$REPO/bric-update" --current --target "$TARGET" | grep -q "^review=${EXPECTED_REVIEW}$"

# Second execution must be idempotent and still preserve mutable state.
"$REPO/bric-update" --config "$CONFIG" --target "$TARGET" \
  --backup-dir "$BACKUPS" --skip-integrations --skip-active-check > "$ROOT/update2.log"
grep -q 'updated:   0 file(s)' "$ROOT/update2.log"
grep -q 'CLUSTER-DB-SENTINEL' "$TARGET/cluster/db/cluster_catalog.db"

grep -q 'BRIC_TAPE_BACKEND=real requires BRIC_BARCODES_FILE' "$REPO/bric-setup.sh"

# CONFIG is authoritative: a conflicting manual role is rejected before changes.
if "$REPO/bric-update" --config "$CONFIG" --role tape --target "$TARGET" \
     --backup-dir "$BACKUPS" --skip-integrations --skip-active-check >"$ROOT/conflict.log" 2>&1; then
    echo "FAIL: conflicting --role tape was accepted against BRIC_ROLE=slurm" >&2; exit 1
fi
grep -q 'conflicts with BRIC_ROLE=slurm' "$ROOT/conflict.log"

# Without a config, explicit --role remains available for offline/test installs.
"$REPO/bric-update" --config "$ROOT/absent.conf" --role slurm --target "$TARGET" \
  --backup-dir "$BACKUPS" --skip-integrations --skip-active-check > "$ROOT/update3.log"
grep -q 'role:       slurm (command-line (config absent))' "$ROOT/update3.log"

echo "PASS: checksum-delta update, config-derived role safety, state preservation, backup, idempotency and release versioning"
