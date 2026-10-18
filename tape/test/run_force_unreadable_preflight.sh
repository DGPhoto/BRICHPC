#!/bin/bash
# Review 32B4: default preflight logs every unreadable path and fails closed; --force logs every
# omission, emits a lossless exclusion manifest and sizes only the remaining readable scope.
set -euo pipefail
REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
CHECK="$REPO/cluster/scripts/bric-source-preflight.sh"
T="$(mktemp -d)"
trap 'chmod -R u+rwX "$T" 2>/dev/null || true; rm -rf "$T"; rm -f /tmp/bric-force-preflight.* 2>/dev/null || true' EXIT
fail(){ echo "FAIL: $*" >&2; exit 1; }

mkdir -p "$T/src"
chmod 755 "$T" "$T/src"
printf 'good-data' > "$T/src/good.txt"
chmod 644 "$T/src/good.txt"
for i in $(seq -w 1 55); do
    printf 'secret-%s' "$i" > "$T/src/bad$i.dat"
    chmod 600 "$T/src/bad$i.dat"
done

run_check(){
    if [ "$(id -u)" -eq 0 ] && command -v runuser >/dev/null 2>&1 && id nobody >/dev/null 2>&1; then
        runuser -u nobody -- env BRIC_CONFIG=none BRIC_LOCAL_TMPDIR=/tmp "$CHECK" "$@"
    else
        env BRIC_CONFIG=none BRIC_LOCAL_TMPDIR=/tmp "$CHECK" "$@"
    fi
}

# As non-root the bad files must be unreadable. On an unusual non-root test host where the current
# identity owns them, explicitly remove its read bit (already done above only when root created them).
if [ "$(id -u)" -ne 0 ]; then chmod 000 "$T/src"/bad*.dat; fi

set +e
run_check --source "$T/src" >"$T/default.out" 2>"$T/default.err"
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "default preflight accepted unreadable files"
# No 50-path truncation: both ends of a 55-item list must be present.
grep -q '\[WARN\].*bad01.dat' "$T/default.err" || fail "first unreadable path missing/wrong severity from default log"
grep -q '\[WARN\].*bad55.dat' "$T/default.err" || fail "55th unreadable path missing/wrong severity from default log"
! grep -q 'additional unreadable path' "$T/default.err" || fail "unreadable list was truncated"
grep -q '\[FAIL\] source integrity preflight failed' "$T/default.err" || fail "default unreadable scope did not terminate with FAIL"

# --exclude is a different contract: an operator-selected subtree is pruned before readability
# validation, is informational rather than a warning, and does not require --force.
mkdir -p "$T/src/planned_exclusion"
printf 'intentionally omitted' > "$T/src/planned_exclusion/secret.txt"
chmod 000 "$T/src/planned_exclusion"
set +e
run_check --source "$T/src" --exclude planned_exclusion >"$T/exclude.out" 2>"$T/exclude.err"
exclude_rc=$?
set -e
# The 55 other unreadable files still make this fail; but the deliberately excluded subtree itself
# must not be diagnosed as unreadable.
[ "$exclude_rc" -ne 0 ] || fail "exclude-only check unexpectedly passed while other unreadable files remain"
! grep -q 'planned_exclusion.*unreadable' "$T/exclude.err" || fail "declared --exclude was misclassified as unreadable"

MF="/tmp/bric-force-preflight.$$.$RANDOM"
out="$(run_check --source "$T/src" --exclude planned_exclusion --force --force-exclude-file "$MF" 2>"$T/force.err")"
IFS='|' read -r files logical allocated exclusions uid <<< "$out"
[ "$files" = 1 ] || fail "force scope should contain exactly the readable file, got files=$files"
[ "$logical" = 9 ] || fail "force logical bytes should describe only good.txt, got logical=$logical"
[ "$exclusions" = 56 ] || fail "total exclusion count should be 56 (1 user-declared + 55 forced), got $exclusions"
grep -q 'FORCE will skip source path: bad01.dat' "$T/force.err" || fail "first force omission not logged"
grep -q 'FORCE will skip source path: bad55.dat' "$T/force.err" || fail "55th force omission not logged"
grep -q 'FORCE summary: 55 unreadable path(s)' "$T/force.err" || fail "force omission summary missing"
grep -q 'declared exclusion: planned_exclusion' "$T/force.err" || fail "user-declared exclusion not reported distinctly"
! grep -q 'FORCE will skip source path: planned_exclusion' "$T/force.err" || fail "user-declared exclusion was conflated with force omission"

python3 - "$MF" <<'PY'
import sys
p=sys.argv[1]
data=open(p,'rb').read().split(b'\0')
if data and data[-1] == b'': data.pop()
assert len(data) == 110, len(data)
pairs=list(zip(data[0::2],data[1::2]))
paths={path for path,_ in pairs}
assert b'bad01.dat' in paths
assert b'bad55.dat' in paths
assert len(paths) == 55
assert all(reason == b'unreadable-file' for _,reason in pairs)
PY

echo "PASS run_force_unreadable_preflight"
