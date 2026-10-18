#!/bin/bash
# Role-specific config regression: gate commands must refuse tape role and tape commands must refuse
# slurm role before touching SQLite/devices.  The shipped examples must select the intended host.
set -euo pipefail
REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
fail(){ echo "FAIL: $*" >&2; exit 1; }

cp "$REPO/config/bric-slurm.conf.example" "$ROOT/slurm.conf"
cp "$REPO/config/bric-tape.conf.example" "$ROOT/tape.conf"

role="$(BRIC_CONFIG="$ROOT/slurm.conf" bash -c '. "$1/cluster/scripts/lib_common.sh"; printf %s "$BRIC_ROLE"' _ "$REPO")"
[ "$role" = slurm ] || fail "slurm config produced role '$role'"
role="$(BRIC_CONFIG="$ROOT/tape.conf" bash -c '. "$1/tape/scripts/lib_common.sh"; printf %s "$BRIC_ROLE"' _ "$REPO")"
[ "$role" = tape ] || fail "tape config produced role '$role'"

drives="$(BRIC_CONFIG="$ROOT/tape.conf" bash -c '. "$1/tape/scripts/lib_common.sh"; printf %s "$BRIC_TAPE_DRIVES"' _ "$REPO")"
[ "$drives" = '0 1' ] || fail "tape config did not select both drives ('$drives')"
parallel="$(BRIC_CONFIG="$ROOT/tape.conf" bash -c '. "$1/tape/scripts/lib_common.sh"; printf %s "$BRIC_PARALLEL_DRIVES"' _ "$REPO")"
[ "$parallel" = 2 ] || fail "tape config did not enable two-drive writes ('$parallel')"

if BRIC_CONFIG=none BRIC_ROLE=tape "$REPO/cluster/bin/bric" --help >"$ROOT/gate.err" 2>&1; then
    fail "cluster CLI accepted BRIC_ROLE=tape"
fi
grep -q 'requires BRIC_ROLE=slurm' "$ROOT/gate.err" || fail "cluster role refusal was not explicit"

if BRIC_CONFIG=none BRIC_ROLE=slurm "$REPO/tape/bin/bric-tape-daemon" --once >"$ROOT/tape.err" 2>&1; then
    fail "tape daemon accepted BRIC_ROLE=slurm"
fi
grep -q 'requires BRIC_ROLE=tape' "$ROOT/tape.err" || fail "tape role refusal was not explicit"

for f in orchestrate.sbatch archive_array.sbatch finalize_close.sbatch restore.sbatch; do
    p="$REPO/cluster/slurm/$f"
    grep -q 'bric_ensure_openssl3 purge' "$p" || fail "$f does not use the shared OpenSSL resolver"
    grep -q 'trap _cleanup_modules EXIT' "$p" || fail "$f has no module cleanup trap"
done

echo "  ok: role configs select slurm/tape, tape config selects drives 0+1"
echo "  ok: cross-role execution is refused before catalog/hardware access"
echo "  ok: every archive/restore sbatch dynamically resolves and cleans up OpenSSL"
echo "PASS run_host_roles"
