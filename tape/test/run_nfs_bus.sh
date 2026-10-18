#!/bin/bash
# Strict NFS-bus contract: production refuses an absent or non-NFS mount, while hermetic/local mode
# may explicitly leave BRIC_REQUIRE_NFS_BUS=0.
set -euo pipefail
export BRIC_CONFIG=none BRIC_ROLE=slurm BRIC_LOG_CAPTURE_STDIO=0
REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
mkdir -p "$ROOT/bin" "$ROOT/mnt/bric" "$ROOT/log1" "$ROOT/log2"
cat > "$ROOT/bin/mountpoint" <<'M'
#!/bin/bash
[ "${MOCK_MOUNTED:-1}" = 1 ]
M
cat > "$ROOT/bin/findmnt" <<'F'
#!/bin/bash
printf '%s\n' "${MOCK_FSTYPE:-nfs4}"
F
chmod +x "$ROOT/bin"/*

run_check(){
  PATH="$ROOT/bin:$PATH" MOCK_MOUNTED="${1}" MOCK_FSTYPE="${2}" \
  BRIC_QNAP="$ROOT/mnt/bric" BRIC_QNAP_MNT="$ROOT/mnt" BRIC_REQUIRE_NFS_BUS="${3}" \
  BRIC_LOG_DIR="$ROOT/log1" BRIC_LOG_FALLBACK_DIR="$ROOT/log2" \
  bash -c '. "$0/cluster/scripts/lib_common.sh"; bric_require_nfs_bus' "$REPO"
}
run_check 1 nfs4 1
echo '  ok: strict production mode accepts an NFS mount'
if run_check 1 cifs 1 >/dev/null 2>&1; then echo 'FAIL: strict mode accepted CIFS' >&2; exit 1; fi
echo '  ok: strict production mode rejects non-NFS filesystems'
if run_check 0 nfs4 1 >/dev/null 2>&1; then echo 'FAIL: strict mode accepted an absent mount' >&2; exit 1; fi
echo '  ok: strict production mode rejects an absent mount'
run_check 1 cifs 0
echo '  ok: hermetic/local mode can explicitly disable the NFS contract'

# A tape-side log fallback under BRIC_QNAP must not be materialized as a local directory when the
# NFS mount is absent. Otherwise a mount loss could split both bus state and logs across hosts.
rm -rf "$ROOT/mnt/bric/.system"
PATH="$ROOT/bin:$PATH" MOCK_MOUNTED=0 MOCK_FSTYPE=nfs4 BRIC_ROLE=tape BRIC_QNAP="$ROOT/mnt/bric" BRIC_QNAP_MNT="$ROOT/mnt" BRIC_REQUIRE_NFS_BUS=1 BRIC_LOG_DIR=/proc/bric-unwritable BRIC_LOG_FALLBACK_DIR="$ROOT/mnt/bric/.system/log/tape" BRIC_REQUIRE_LOGGING=0 bash -c '. "$0/tape/scripts/lib_common.sh"; bric_log_init; [ -z "${_BRIC_LOG_CURRENT_ROOT:-}" ]' "$REPO"
[ ! -e "$ROOT/mnt/bric/.system" ] || { echo 'FAIL: logger created a local QNAP fallback while NFS was absent' >&2; exit 1; }
echo '  ok: logging cannot create a false local QNAP fallback after NFS mount loss'
echo 'PASS run_nfs_bus'
