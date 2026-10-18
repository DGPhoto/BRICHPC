#!/bin/bash
set -euo pipefail
REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
H="$REPO/cluster/libexec/bric-tar-stream"
M="$REPO/cluster/libexec/bric-file-metadata"

[ -x "$H" ]
[ -x "$M" ]
"$M" --version | grep -Eq '^BRIC file-metadata 34(R2rc[123])?$'
"$H" --version | grep -q '^BRIC tar-stream '
file "$H" | grep -q 'ELF 64-bit'
if readelf -d "$H" 2>/dev/null | grep -q '(NEEDED)'; then
    echo "FAIL: tar-stream helper has dynamic library dependencies" >&2
    readelf -d "$H" >&2
    exit 1
fi
grep -q 'CGO_ENABLED=0' "$REPO/bric-setup.sh"
grep -Eq 'rebuilding( tar-stream helper)? .*static linux/' "$REPO/bric-setup.sh"
grep -q 'initial probe:' "$REPO/bric-setup.sh"
grep -q 'static local rebuild unavailable' "$REPO/bric-setup.sh"
grep -q '^ExecStart=/bin/bash /opt/bric2/tape/bin/bric-tape-daemon --loop$' "$REPO/tape/systemd/bric-tape-daemon.service"
grep -q '^ExecStartPre=/bin/bash -n /opt/bric2/tape/bin/bric-tape-daemon$' "$REPO/tape/systemd/bric-tape-daemon.service"
grep -q 'systemctl is-active --quiet bric-tape-daemon.service' "$REPO/bric-setup.sh"
if readelf -d "$M" 2>/dev/null | grep -q '(NEEDED)'; then echo 'FAIL: file-metadata helper has dynamic library dependencies' >&2; exit 1; fi
grep -q 'ensure_file_metadata_helper' "$REPO/bric-setup.sh"
echo '✓ static helpers, preserved diagnostics and systemd interpreter launch passed'
