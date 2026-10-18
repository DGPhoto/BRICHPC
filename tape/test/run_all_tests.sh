#!/bin/bash
# run_all_tests.sh — run the full BRIC test suite (simulation backend; no tape hardware needed).
#
# This is the FULL RELEASE VALIDATION entry point. Run it from a complete extracted release tree
# (not from a role-filtered /opt/bric2 installation) to prove the host environment (bash, sqlite3, openssl, coreutils, permissions) supports
# every code path — backup, restore, DR, crash recovery, fault injection, notifications, config.
#
# Usage:
#   test/run_all_tests.sh                 # everything (~10-20 min)
#   test/run_all_tests.sh --only dr       # only tests whose name matches the pattern
#   test/run_all_tests.sh --timeout 600   # per-test timeout in seconds (default 600)
#
# Deliberately EXCLUDED: run_real_tape_smoke.sh (writes a real scratch tape; hardware phase only,
# run it explicitly with --vt BARCODE). Every included test is hermetic: it ignores
# /etc/bric/bric.conf, uses its own temp workroot, and cleans up after itself.
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
PATTERN=""; TMO=600
while [ "$#" -gt 0 ]; do case "$1" in
    --only)    PATTERN="${2:-}"; shift 2;;
    --timeout) TMO="${2:-600}"; shift 2;;
    -h|--help) sed -n '2,15p' "$0"; exit 0;;
    *) echo "unknown option: $1" >&2; exit 2;; esac; done

# Capture the only suite-level BRIC knob before constructing a clean child environment.
# Production hosts commonly export BRIC_ROLE, catalog paths, signing keys, backend selection, etc.
# Those values MUST NOT leak into tests: config precedence is env > file > defaults, so merely
# setting BRIC_CONFIG=none is not enough.  Clear every inherited BRIC_/_BRIC_ variable and then add
# back only the private per-test logging paths plus BRIC_CONFIG=none.
LOGDIR="${BRIC_TEST_LOGDIR:-$(mktemp -d /tmp/bric_suite.XXXXXX)}"
JOURNAL_SUITE_ROOT="$(mktemp -d /tmp/bric_suite_journal.XXXXXX)"
chmod 1777 "$JOURNAL_SUITE_ROOT"
trap 'rm -rf -- "$JOURNAL_SUITE_ROOT"' EXIT
CLEAN_ENV=(env)
SANITIZED=0
while IFS= read -r _name; do
    case "$_name" in
        BRIC_*|_BRIC_*) CLEAN_ENV+=(-u "$_name"); SANITIZED=$((SANITIZED+1));;
    esac
done < <(compgen -e)
unset _name

ROOT="$(cd "$HERE/.." && pwd)"
if [ "${BRIC_TEST_ALLOW_INCOMPLETE_TREE:-0}" != 1 ] && [ -r "$ROOT/MANIFEST.sha256" ]; then
    if ! ( cd "$ROOT" && sha256sum -c MANIFEST.sha256 >/dev/null 2>&1 ); then
        echo "ERROR: full BRIC suite requires a complete, manifest-clean release tree." >&2
        echo "       Do not run it from a role-filtered /opt/bric2 installation." >&2
        echo "       Extract the release tarball and run test/run_all_tests.sh there." >&2
        echo "       Set BRIC_TEST_ALLOW_INCOMPLETE_TREE=1 only for deliberate developer worktrees." >&2
        exit 2
    fi
fi

TESTS=()
for t in "$HERE"/run_*.sh; do
    b="$(basename "$t")"
    [ "$b" = "run_all_tests.sh" ] && continue
    [ "$b" = "run_real_tape_smoke.sh" ] && continue      # hardware phase, explicit only
    [ -n "$PATTERN" ] && case "$b" in *"$PATTERN"*) ;; *) continue;; esac
    TESTS+=("$t")
done
TOTAL=${#TESTS[@]}
[ "$TOTAL" -gt 0 ] || { echo "ERROR: no tests selected" >&2; exit 2; }

mkdir -p "$LOGDIR"
echo "== BRIC test suite == logs: $LOGDIR"
echo "== hermetic environment: cleared $SANITIZED inherited BRIC variable(s); BRIC_CONFIG=none =="
echo "== selected tests: $TOTAL =="
PASS=0; FAIL=0; FAILED=""; INDEX=0
# Human-friendly status colors. Preserve plain text when stdout is redirected, TERM is dumb,
# or NO_COLOR is set. The words OK/FAIL remain machine-readable in either mode.
GREEN=""; RED=""; RESET=""
if [ -t 1 ] && [ "${TERM:-dumb}" != dumb ] && [ -z "${NO_COLOR:-}" ]; then
    GREEN=$'\033[32m'; RED=$'\033[31m'; RESET=$'\033[0m'
fi
START=$(date +%s)
for t in "${TESTS[@]}"; do
    INDEX=$((INDEX+1))
    b="$(basename "$t")"
    t0=$(date +%s)
    TEST_RUNTIME_LOG="$LOGDIR/runtime/$b"
    TEST_JOURNAL_BASE="$JOURNAL_SUITE_ROOT/$INDEX-$b"
    mkdir -p "$TEST_RUNTIME_LOG/primary" "$TEST_RUNTIME_LOG/fallback" "$TEST_JOURNAL_BASE"
    chmod 1777 "$TEST_JOURNAL_BASE"
    printf '[%d/%d] RUN  %s\n' "$INDEX" "$TOTAL" "$b"
    if "${CLEAN_ENV[@]}" \
       BRIC_CONFIG=none \
       BRIC_LOG_DIR="$TEST_RUNTIME_LOG/primary" \
       BRIC_LOG_FALLBACK_DIR="$TEST_RUNTIME_LOG/fallback" \
       BRIC_RESTORE_JOURNAL_ROOT="$TEST_JOURNAL_BASE" \
       BRIC_REQUIRE_LOGGING=1 \
       BRIC_KEEP_TERMINAL_BUS=1 \
       timeout "$TMO" bash "$t" > "$LOGDIR/$b.log" 2>&1; then
        PASS=$((PASS+1)); printf '[%d/%d] %sOK%s   %-38s (%ss)\n' "$INDEX" "$TOTAL" "$GREEN" "$RESET" "$b" "$(( $(date +%s) - t0 ))"
    else
        FAIL=$((FAIL+1)); FAILED="$FAILED $b"
        printf '[%d/%d] %sFAIL%s %-38s (%ss)  -> %s\n' "$INDEX" "$TOTAL" "$RED" "$RESET" "$b" "$(( $(date +%s) - t0 ))" "$LOGDIR/$b.log"
        grep -E "FAIL:|✗" "$LOGDIR/$b.log" | head -3 | sed 's/^/       /'
    fi
done
if [ "$FAIL" -gt 0 ]; then
    printf '== %s%d OK%s, %s%d FAIL%s in %ss ==\n' "$GREEN" "$PASS" "$RESET" "$RED" "$FAIL" "$RESET" "$(( $(date +%s) - START ))"
else
    printf '== %s%d OK%s, 0 FAIL in %ss ==\n' "$GREEN" "$PASS" "$RESET" "$(( $(date +%s) - START ))"
fi
if [ "$FAIL" -gt 0 ]; then
    echo "failed:$FAILED"
    printf "%s✗ SUITE FAILED%s — do not proceed with production; inspect the logs above.\n" "$RED" "$RESET"
    exit 1
fi
printf "%s✓ SUITE PASSED%s — software environment validated.\n" "$GREEN" "$RESET"
exit 0
