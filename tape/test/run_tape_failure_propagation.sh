#!/bin/bash
# Review 30AC: failure propagation in the real-backend pair/release helpers must not be masked by
# a trailing success log event, even when the caller invokes the function in an if/|| context.
set -euo pipefail
export BRIC_CONFIG=none
REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
fail(){ echo "FAIL: $*" >&2; exit 1; }

export BRIC_TAPE_BACKEND=real
export BRIC_TAPE_DRIVES="0 1"
export BRIC_CHANGER_LOCK="$ROOT/changer.lock"
export BRIC_DRIVE_LOCK_PREFIX="$ROOT/drive.lock."
export BRIC_UNLOAD_ON_COMPLETE=1
EVENTS="$ROOT/events"
bric_event(){ printf '%s|%s|%s\n' "$1" "$2" "${3:-}" >>"$EVENTS"; }
log(){ :; }
die(){ echo "ERROR: $*" >&2; exit 1; }
. "$REPO/tape/scripts/lib_tape_io.sh"

: >"$EVENTS"
echo "== tape_prepare_pair propagates a child failure =="
if tape_prepare_pair 000001L9 000002L9 0 0 >/dev/null 2>&1; then
    fail "tape_prepare_pair returned success for duplicate drive elements"
fi
grep -q '|PAIR_PREPARE_FAILED|' "$EVENTS" || fail "PAIR_PREPARE_FAILED event missing"
! grep -q '|PAIR_PREPARE_END|' "$EVENTS" || fail "PAIR_PREPARE_END was emitted after failure"
echo "  ok: pair-prepare failure is returned and not logged as success"

# Force a status failure inside the release worker. The function is intentionally called from an
# `if` context, reproducing the Bash errexit suppression that caused Review 30AA to mask the error.
_status(){ die "forced changer status failure"; }
: >"$EVENTS"
echo "== tape_release_all propagates a child failure =="
if tape_release_all >/dev/null 2>&1; then
    fail "tape_release_all returned success after forced changer-status failure"
fi
grep -q '|MEDIA_RELEASE_FAILED|' "$EVENTS" || fail "MEDIA_RELEASE_FAILED event missing"
! grep -q '|MEDIA_RELEASE_DONE|' "$EVENTS" || fail "MEDIA_RELEASE_DONE was emitted after failure"
echo "  ok: media-release failure is returned and cannot masquerade as confirmed-empty"


# Defence in depth: all daemon pair-prepare call sites must keep the helper in a child process. This
# protects the main daemon even if a future edit reintroduces a direct `die/exit` before the helper's
# own internal worker subshell.
DAEMON="$REPO/tape/bin/bric-tape-daemon"
echo "== daemon pair-prepare call sites are process-isolated =="
wrapped="$(grep -Ec '^[[:space:]]*\([[:space:]]*tape_prepare_pair .*\)[[:space:]]*\|\|' "$DAEMON" || true)"
[ "$wrapped" -eq 3 ] || fail "expected 3 process-isolated tape_prepare_pair call sites, found $wrapped"
# Demonstrate the guarded-child pattern survives an unconditional die/exit from the helper.
tape_prepare_pair(){ die "forced direct helper exit"; }
probe_rc=0
( tape_prepare_pair A B 0 1 ) >/dev/null 2>&1 || probe_rc=$?
[ "$probe_rc" -ne 0 ] || fail "forced direct helper exit unexpectedly succeeded"
echo "  ok: all three call sites are wrapped and a direct helper exit cannot kill the caller"

echo "PASS run_tape_failure_propagation"
