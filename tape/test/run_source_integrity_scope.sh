#!/bin/bash
# Review 31: source readability is a pre-reservation invariant; exclusions are exact, explicit subtrees.
set -euo pipefail
REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
T="$(mktemp -d)"; trap 'chmod -R u+rwX "$T" 2>/dev/null || true; rm -rf "$T"' EXIT
mkdir -p "$T/src/good" "$T/src/private/sub"
printf good > "$T/src/good/a.txt"
printf secret > "$T/src/private/sub/hidden.txt"
chmod 755 "$T" "$T/src" "$T/src/good"
chmod 644 "$T/src/good/a.txt"
chmod 700 "$T/src/private" "$T/src/private/sub"
chmod 600 "$T/src/private/sub/hidden.txt"

CHECK="$REPO/cluster/scripts/bric-source-preflight.sh"
# Root bypasses mode-bit readability, so exercise the permission branch as an unprivileged identity when
# the suite itself is root (the production caller is likewise unprivileged).
if [ "$(id -u)" -eq 0 ] && command -v runuser >/dev/null 2>&1 && id nobody >/dev/null 2>&1; then
    set +e
    out="$(runuser -u nobody -- env BRIC_CONFIG=none BRIC_LOCAL_TMPDIR=/tmp "$CHECK" --source "$T/src" 2>"$T/bad.err")"
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || { echo "FAIL: unreadable subtree passed source integrity preflight" >&2; exit 1; }
    grep -q 'source path is not readable/traversable: private' "$T/bad.err" || { cat "$T/bad.err" >&2; echo "FAIL: unreadable subtree not identified" >&2; exit 1; }

    out="$(runuser -u nobody -- env BRIC_CONFIG=none BRIC_LOCAL_TMPDIR=/tmp "$CHECK" --source "$T/src" --exclude private 2>"$T/good.err")"
else
    # Non-root suite: make the private path unreadable to the current user directly.
    set +e
    out="$(env BRIC_CONFIG=none BRIC_LOCAL_TMPDIR=/tmp "$CHECK" --source "$T/src" 2>"$T/bad.err")"; rc=$?
    set -e
    [ "$rc" -ne 0 ] || { echo "FAIL: unreadable subtree passed source integrity preflight" >&2; exit 1; }
    out="$(env BRIC_CONFIG=none BRIC_LOCAL_TMPDIR=/tmp "$CHECK" --source "$T/src" --exclude private 2>"$T/good.err")"
fi
IFS='|' read -r files logical allocated exclusions uid <<< "$out"
[ "$files" = 1 ]
[ "$logical" = 4 ]
[ "$exclusions" = 1 ]
grep -q 'declared exclusion: private' "$T/good.err"

# A typo is not an exclusion: it is a fatal scope error.
set +e
env BRIC_CONFIG=none "$CHECK" --source "$T/src" --exclude does/not/exist >"$T/miss.out" 2>"$T/miss.err"
rc=$?
set -e
[ "$rc" -ne 0 ]
grep -q 'declared exclusion does not exist' "$T/miss.err"

# Grammar is intentionally exact-relative-subtree, not a glob/shell language.
for bad in /absolute ../escape ./../escape .; do
    set +e
    env BRIC_CONFIG=none "$CHECK" --source "$T/src" --exclude "$bad" >"$T/x.out" 2>"$T/x.err"
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || { echo "FAIL: invalid exclusion accepted: $bad" >&2; exit 1; }
done

echo "✓ source integrity preflight blocks unreadable scope and accepts only explicit existing exclusions"
