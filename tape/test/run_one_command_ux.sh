#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
TMP="$(mktemp -d /tmp/bric-one-command.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/scripts" "$TMP/home/.bric"
cp "$ROOT/cluster/bin/bric-run" "$TMP/bin/bric-run"
cat > "$TMP/bin/bric" <<'EOF'
#!/bin/bash
printf '%s\n' "ENV=${BRIC_TEST_AUTOSOURCE:-missing}" > "$BRIC_CAPTURE"
printf 'ARG=%s\n' "$@" >> "$BRIC_CAPTURE"
EOF
chmod +x "$TMP/bin/bric" "$TMP/bin/bric-run"
cat > "$TMP/bin/openssl" <<'OPENSSL'
#!/bin/bash
[ "${1:-}" = version ] && { echo 'OpenSSL 3.0.0 hermetic-test'; exit 0; }
exec /usr/bin/openssl "$@"
OPENSSL
chmod +x "$TMP/bin/openssl"
export PATH="$TMP/bin:$PATH"
cat > "$TMP/scripts/lib_common.sh" <<'EOF'
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
EOF
cat > "$TMP/home/.bric/env.sh" <<'EOF'
export BRIC_TEST_AUTOSOURCE=loaded
EOF
chmod 600 "$TMP/home/.bric/env.sh"

export HOME="$TMP/home" BRIC_CAPTURE="$TMP/capture"
"$TMP/bin/bric-run" --skip-preflight backup projectA /source/path --wait >/dev/null
grep -qx 'ENV=loaded' "$BRIC_CAPTURE"
grep -qx 'ARG=backup' "$BRIC_CAPTURE"
grep -qx 'ARG=--project' "$BRIC_CAPTURE"
grep -qx 'ARG=projectA' "$BRIC_CAPTURE"
grep -qx 'ARG=--source' "$BRIC_CAPTURE"
grep -qx 'ARG=/source/path' "$BRIC_CAPTURE"
grep -qx 'ARG=--wait' "$BRIC_CAPTURE"

: > "$BRIC_CAPTURE"
"$TMP/bin/bric-run" --skip-preflight restore projectA /restore/path --run run42 --wait >/dev/null
grep -qx 'ARG=restore' "$BRIC_CAPTURE"
grep -qx 'ARG=--project' "$BRIC_CAPTURE"
grep -qx 'ARG=projectA' "$BRIC_CAPTURE"
grep -qx 'ARG=--dest' "$BRIC_CAPTURE"
grep -qx 'ARG=/restore/path' "$BRIC_CAPTURE"
grep -qx 'ARG=--run' "$BRIC_CAPTURE"
grep -qx 'ARG=run42' "$BRIC_CAPTURE"

: > "$BRIC_CAPTURE"
"$TMP/bin/bric-run" status --project projectA >/dev/null
grep -qx 'ARG=status' "$BRIC_CAPTURE"
grep -qx 'ARG=--project' "$BRIC_CAPTURE"
grep -qx 'ARG=projectA' "$BRIC_CAPTURE"

grep -q 'ln -sfn' "$ROOT/bric-setup.sh"
grep -q 'BRIC_COMMAND_LINK:=/usr/local/bin/bric' "$ROOT/bric-setup.sh"
! grep -A8 '^User commands' "$ROOT/cluster/scripts/bric-setup-user.sh" | grep -q 'module load'
! grep -A8 '^User commands' "$ROOT/cluster/scripts/bric-setup-user.sh" | grep -q '^  source '

echo 'PASS: one-command UX, shorthand normalization and automatic user env loading'
