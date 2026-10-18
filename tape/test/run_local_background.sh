#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
TMP="$(mktemp -d /tmp/bric-bg.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/scripts" "$TMP/home/.bric" "$TMP/home/.bric/log/jobs" "$TMP/home/.bric/pids" "$TMP/central/$(id -un)/jobs"
cp "$ROOT/cluster/bin/bric-run" "$TMP/bin/bric-run"
cat > "$TMP/bin/bric" <<'CORE'
#!/bin/bash
printf 'core-start pid=%s args=%s\n' "$$" "$*"
sleep "${BRIC_TEST_SLEEP:-1}"
printf 'core-end pid=%s\n' "$$"
CORE
chmod +x "$TMP/bin/bric" "$TMP/bin/bric-run"
cat > "$TMP/bin/openssl" <<'OPENSSL'
#!/bin/bash
[ "${1:-}" = version ] && { echo 'OpenSSL 3.0.0 hermetic-test'; exit 0; }
exec /usr/bin/openssl "$@"
OPENSSL
chmod +x "$TMP/bin/openssl"
export PATH="$TMP/bin:$PATH"
cat > "$TMP/scripts/lib_common.sh" <<'LIB'
bric_log_process_start(){ :; }
require_role(){ :; }
bric_openssl_version(){ openssl version 2>/dev/null | awk 'NR==1 {print $2}'; }
bric_openssl_version_ok(){ case "$(bric_openssl_version)" in 3.*|4.*|5.*|6.*|7.*|8.*|9.*) return 0;; *) return 1;; esac; }
bric_ensure_openssl3(){ bric_openssl_version_ok; }
bric_validate_logical_root(){
    local root="${1:-}"
    [ -n "$root" ] && [ "$root" != "." ] && [ "$root" != ".." ] || return 1
    case "$root" in */*) return 1;; esac
    printf '%s\n' "$root"
}
bric_default_logical_root(){
    local p="${1:-}" root
    [ -n "$p" ] || return 1
    while [ "${p%/}" != "$p" ] && [ "$p" != "/" ]; do p="${p%/}"; done
    root="${p##*/}"
    bric_validate_logical_root "$root"
}
die(){ echo "ERROR: $*" >&2; exit 1; }
LIB
cat > "$TMP/home/.bric/env.sh" <<EOF_ENV
export BRIC_RUN_MODE=local
export BRIC_PID_DIR=$TMP/home/.bric/pids
export BRIC_USER_LOG_ROOT=$TMP/central
export BRIC_LOG_DIR=$TMP/central/$(id -un)
export BRIC_LOG_FALLBACK_DIR=$TMP/home/.bric/log
export BRIC_BACKGROUND_LOGDIR=$TMP/central/$(id -un)/jobs
EOF_ENV
chmod 600 "$TMP/home/.bric/env.sh"
if command -v setfacl >/dev/null 2>&1 && command -v getfacl >/dev/null 2>&1; then
    setfacl -m 'u::rwx,g::---,g:root:r-x,m::r-x,o::---' "$TMP/central/$(id -un)" "$TMP/central/$(id -un)/jobs"
    setfacl -d -m 'u::rwx,g::---,g:root:r-x,m::r-x,o::---' "$TMP/central/$(id -un)" "$TMP/central/$(id -un)/jobs"
    export BRIC_LOG_GROUP=root
fi
export HOME="$TMP/home" BRIC_TEST_SLEEP=1
OUT="$($TMP/bin/bric-run --skip-preflight backup bgtest /source/path)"
echo "$OUT"
JOB="$(printf '%s\n' "$OUT" | awk '/^  job:/{print $2}')"
PID="$(printf '%s\n' "$OUT" | awk '/^  PID:/{print $2}')"
LOG="$(printf '%s\n' "$OUT" | awk '/^  log:/{print $2}')"
[ -n "$JOB" ] && [ -n "$PID" ] && [ -n "$LOG" ]
[ -s "$TMP/home/.bric/pids/$JOB.meta" ]
kill -0 "$PID" 2>/dev/null
for _ in $(seq 1 100); do
    [ ! -e "$TMP/home/.bric/pids/$JOB.pid" ] && break
    sleep 0.05
done
[ ! -e "$TMP/home/.bric/pids/$JOB.pid" ]
grep -q '^state=FINISHED$' "$TMP/home/.bric/pids/$JOB.meta"
grep -q 'core-start' "$LOG"
grep -q 'core-end' "$LOG"
case "$LOG" in "$TMP/central/$(id -un)/jobs/"*) :;; *) echo "FAIL: background log did not use central primary: $LOG" >&2; exit 1;; esac
if command -v getfacl >/dev/null 2>&1 && [ "${BRIC_LOG_GROUP:-}" = root ]; then
    getfacl -cp "$LOG" | awk -F: '$1=="group" && $2=="" && $3=="---" {ok=1} END{exit !ok}' \
      || { echo "FAIL: central background log owning-group ACL is not isolated" >&2; exit 1; }
    getfacl -cp "$LOG" | awk -F: '$1=="group" && $2=="root" && $3 ~ /^r--/ {ok=1} END{exit !ok}' \
      || { echo "FAIL: central background log lacks admin read ACL" >&2; exit 1; }
fi
# Make the configured central jobs path structurally unusable even to root; BRIC must switch to the
# private home fallback instead of refusing to start the detached operation.
rm -rf "$TMP/central/$(id -un)/jobs"; : > "$TMP/central/$(id -un)/jobs"
OUT_FB="$($TMP/bin/bric-run --skip-preflight backup fallbacktest /source/path 2>"$TMP/fallback.err")"
LOG_FB="$(printf '%s\n' "$OUT_FB" | awk '/^  log:/{print $2}')"
case "$LOG_FB" in "$TMP/home/.bric/log/jobs/"*) :;; *) echo "FAIL: background log fallback path wrong: $LOG_FB" >&2; exit 1;; esac
grep -qi 'background log failover' "$TMP/fallback.err"
for _ in $(seq 1 100); do grep -q 'core-end' "$LOG_FB" 2>/dev/null && break; sleep 0.05; done
grep -q 'core-end' "$LOG_FB"
# Restore central path for the remaining lifecycle/cancellation checks.
rm -f "$TMP/central/$(id -un)/jobs"; mkdir -p "$TMP/central/$(id -un)/jobs"
# --wait must preserve foreground behavior and avoid creating another metadata record.
BEFORE="$(find "$TMP/home/.bric/pids" -name '*.meta' | wc -l)"
$TMP/bin/bric-run --skip-preflight backup fgtest /source/path --wait >/dev/null
AFTER="$(find "$TMP/home/.bric/pids" -name '*.meta' | wc -l)"
[ "$BEFORE" = "$AFTER" ]
# Cancellation of the process group must still let the supervisor record completion and remove PID.
export BRIC_TEST_SLEEP=30
OUT2="$($TMP/bin/bric-run --skip-preflight backup canceltest /source/path)"
JOB2="$(printf '%s\n' "$OUT2" | awk '/^  job:/{print $2}')"
PID2="$(printf '%s\n' "$OUT2" | awk '/^  PID:/{print $2}')"
kill -TERM -- "-$PID2"
for _ in $(seq 1 100); do
    [ ! -e "$TMP/home/.bric/pids/$JOB2.pid" ] && break
    sleep 0.05
done
[ ! -e "$TMP/home/.bric/pids/$JOB2.pid" ]
grep -q '^state=FAILED$' "$TMP/home/.bric/pids/$JOB2.meta"
echo 'PASS: local backup uses central job logs with private fallback, detaches cleanly, and --wait stays foreground'
