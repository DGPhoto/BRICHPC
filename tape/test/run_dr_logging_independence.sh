#!/bin/bash
# The DR path must never depend on the operational logger being present or writable.
set -euo pipefail
export BRIC_CONFIG=none
REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
mkdir -p "$ROOT/cluster/scripts" "$ROOT/tape/scripts" "$ROOT/bin"
cp "$REPO/cluster/scripts/bric-dr-from-tapes.sh" "$ROOT/cluster/scripts/"
cp "$REPO/tape/scripts/lib_tape_io.sh" "$ROOT/tape/scripts/"
chmod +x "$ROOT/cluster/scripts/bric-dr-from-tapes.sh"
# Deliberately do not copy lib_logging.sh. An unwritable primary/fallback must not block DR startup.
set +e
out="$(BRIC_LOG_DIR=/proc/bric-nope BRIC_LOG_FALLBACK_DIR=/proc/bric-nope \
       "$ROOT/cluster/scripts/bric-dr-from-tapes.sh" --project p --dest "$ROOT/out" \
       --user-key-file "$ROOT/missing.key" --tapelib "$ROOT/tapes" 2>&1)"
rc=$?
set -e
# It must get past logger initialization. A missing key/tape is expected; command-not-found or rc=70 is not.
[ "$rc" -ne 70 ] || { echo "FAIL: DR still depends on writable logging" >&2; exit 1; }
printf '%s\n' "$out" | grep -q 'bric_log_process_start: command not found' && { echo "FAIL: logger function undefined" >&2; exit 1; }
printf '%s\n' "$out" | grep -Eq 'catalog_project.enc not found|need |No such file|ERROR:' || {
  echo "FAIL: DR did not reach its normal validation path" >&2; printf '%s\n' "$out" >&2; exit 1;
}
echo 'PASS run_dr_logging_independence'
