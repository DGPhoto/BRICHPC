#!/bin/bash
. "$(cd "$(dirname "$(readlink -f "$0")")" && pwd)/lib_test_daemon.sh"
# Review 31C: updater must fail closed if any bric-tape-daemon --loop survives systemd stop.
set -euo pipefail
IFS=$'\n\t'
REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
ROOT="$(mktemp -d)"
LEGACY_PID=""
cleanup() {
    bric_test_stop_group "${LEGACY_PID:-0}"
    bric_test_rmrf_retry "$ROOT"
}
trap cleanup EXIT
TARGET="$ROOT/installed"; BACKUPS="$ROOT/backups"; CFG="$ROOT/bric.conf"; BIN="$ROOT/bin"; OLD="$ROOT/oldtree/tape/bin"
mkdir -p "$TARGET" "$BIN" "$OLD"
printf 'BRIC Archive 2.0\nreview=31B1\nrelease_id=2.0-review31B1\nbuild_date=2026-09-04\nupdate_format=1\ndatabase_migration=additive-lazy-v31b1-source-consistency\non_tape_format=BRIC-FORMAT-V1\nbuild_state=complete\n' > "$TARGET/RELEASE"
printf 'DO-NOT-TOUCH\n' > "$TARGET/README.md"
printf 'BRIC_ROLE=tape\nBRIC_TAPE_DB=%s\n' "$TARGET/tape/db/tape_catalog.db" > "$CFG"

cat > "$BIN/systemctl" <<'S'
#!/bin/bash
set -e
case "${1:-}" in
  list-unit-files) [ "${TEST_UNIT_PRESENT:-1}" = 1 ] && exit 0 || exit 1;;
  is-active) exit 0;;
  stop) touch "${TEST_STOP_MARKER:?}"; exit 0;;
  start|restart) touch "${TEST_RESTART_MARKER:?}"; exit 0;;
  *) exit 0;;
esac
S
chmod +x "$BIN/systemctl"
cat > "$OLD/bric-tape-daemon" <<'D'
#!/bin/bash
trap 'exit 0' TERM INT
while :; do sleep 30 & wait $!; done
D
chmod +x "$OLD/bric-tape-daemon"
setsid "$OLD/bric-tape-daemon" --loop & LEGACY_PID=$!
sleep 0.1
kill -0 "$LEGACY_PID"
export TEST_STOP_MARKER="$ROOT/stopped" TEST_RESTART_MARKER="$ROOT/restarted" TEST_UNIT_PRESENT=1
PATH="$BIN:$PATH"
export PATH

before="$(sha256sum "$TARGET/README.md" "$TARGET/RELEASE")"
if "$REPO/bric-update" --config "$CFG" --target "$TARGET" --backup-dir "$BACKUPS" \
     --skip-integrations --skip-active-check >"$ROOT/update.out" 2>&1; then
    echo 'FAIL: update accepted a foreign legacy tape daemon' >&2; exit 1
fi
[ -e "$ROOT/stopped" ] || { echo 'FAIL: updater did not stop systemd service first' >&2; exit 1; }
[ ! -e "$ROOT/restarted" ] || { echo 'FAIL: updater restarted systemd after foreign daemon detection' >&2; exit 1; }
after="$(sha256sum "$TARGET/README.md" "$TARGET/RELEASE")"
[ "$before" = "$after" ] || { echo 'FAIL: target changed before legacy-daemon abort' >&2; exit 1; }
[ ! -e "$BACKUPS" ] || { echo 'FAIL: backup/update tree created before legacy-daemon abort' >&2; exit 1; }
grep -q 'update aborted before file changes' "$ROOT/update.out"
grep -q "foreign/legacy bric-tape-daemon detected" "$ROOT/update.out"
grep -q "$LEGACY_PID" "$ROOT/update.out"
kill -0 "$LEGACY_PID"

# Detection is independent of systemd: an offline/manual tape installation with no unit must still
# refuse an extracted-tree daemon before touching the target.
rm -f "$ROOT/stopped" "$ROOT/restarted"
export TEST_UNIT_PRESENT=0
if "$REPO/bric-update" --config "$CFG" --target "$TARGET" --backup-dir "$BACKUPS" \
     --skip-integrations --skip-active-check >"$ROOT/update-no-unit.out" 2>&1; then
    echo 'FAIL: update without a systemd unit accepted a foreign legacy tape daemon' >&2; exit 1
fi
[ ! -e "$ROOT/stopped" ] || { echo 'FAIL: no-unit case unexpectedly called systemctl stop' >&2; exit 1; }
[ ! -e "$ROOT/restarted" ] || { echo 'FAIL: no-unit case unexpectedly restarted systemd' >&2; exit 1; }
[ "$before" = "$(sha256sum "$TARGET/README.md" "$TARGET/RELEASE")" ] || { echo 'FAIL: no-unit case changed target' >&2; exit 1; }
grep -q 'foreign/legacy bric-tape-daemon detected' "$ROOT/update-no-unit.out"
grep -q "$LEGACY_PID" "$ROOT/update-no-unit.out"

echo 'PASS: updater refuses extracted-tree daemon with or without systemd, leaves target untouched, and deliberately does not restart systemd'
