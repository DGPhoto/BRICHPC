#!/bin/bash
# Review 32A: parallel QNAP occupancy includes .enc.part and free-space gate fails before reservation.
set -euo pipefail
REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export BRIC_CONFIG=none BRIC_ROLE=slurm BRIC_HOME="$REPO/cluster" BRIC_DB="$T/catalog.db"
export BRIC_QNAP="$T/qnap/bric" BRIC_QNAP_MNT="$T/qnap" BRIC_REQUIRE_NFS_BUS=0
export BRIC_REQUIRE_LOGGING=0 BRIC_LOG_CAPTURE_STDIO=0
mkdir -p "$BRIC_QNAP/archive/p/r" "$BRIC_QNAP_MNT"
. "$REPO/cluster/scripts/lib_common.sh"

truncate -s 1000000 "$BRIC_QNAP/archive/p/r/chunk_0001.enc"
truncate -s 2000000 "$BRIC_QNAP/archive/p/r/chunk_0002.enc.part"
printf x > "$BRIC_QNAP/archive/p/r/chunk_0002.enc.sha256"
bytes="$(qnap_inflight_bytes)"
[ "$bytes" = 3000000 ] || { echo "FAIL: qnap_inflight_bytes=$bytes expected=3000000"; exit 1; }

free="$(qnap_free_bytes)"
case "$free" in ''|*[!0-9]*|0) echo "FAIL: invalid qnap_free_bytes=$free"; exit 1;; esac
# Small scope must pass on the temporary filesystem.
qnap_parallel_preflight 1000000 4 245000 8 >/dev/null
# Construct a requirement definitely larger than current free space. Two slots at target=free plus 5%.
set +e
( qnap_parallel_preflight "$((free*2))" 1 "$free" 1 ) >/dev/null 2>"$T/fail.err"
rc=$?
set -e
[ "$rc" -ne 0 ] || { echo "FAIL: over-capacity QNAP preflight unexpectedly passed"; exit 1; }
grep -q 'insufficient QNAP staging space before reservation' "$T/fail.err" || { cat "$T/fail.err"; echo "FAIL: expected capacity diagnostic missing"; exit 1; }
echo "PASS parallel QNAP capacity: inflight counts .enc+.enc.part and free-space preflight fails closed"
