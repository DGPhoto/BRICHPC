#!/bin/bash
# Review 31D: structured event paths rotate by event date, and event-only primary failures leave an
# explicit LOG_FAILOVER breadcrumb on the fallback without relying on raw stdout/stderr activity.
set -euo pipefail
export BRIC_CONFIG=none
REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
fail(){ echo "FAIL: $*" >&2; exit 1; }
export BRIC_ROLE=tape BRIC_TAPE_HOME="$ROOT/tape" BRIC_QNAP="$ROOT/qnap"
export BRIC_LOG_DIR="$ROOT/primary" BRIC_LOG_FALLBACK_DIR="$ROOT/fallback"
export BRIC_LOG_CAPTURE_STDIO=0 BRIC_REQUIRE_LOGGING=1 BRIC_LOG_COMPONENT=rotation-test
mkdir -p "$BRIC_LOG_DIR" "$BRIC_LOG_FALLBACK_DIR" "$BRIC_QNAP"
. "$REPO/tape/scripts/lib_common.sh"
DAYFILE="$ROOT/day"; echo 2026-09-05 >"$DAYFILE"
_bric_log_day(){ cat "$DAYFILE"; }
bric_log_init
bric_event INFO DAY_ONE first
STEM="${_BRIC_LOG_EVENT_STEM:-}"; [ -n "$STEM" ] || fail "event stem was not initialized"
echo 2026-09-07 >"$DAYFILE"
bric_event INFO DAY_TWO second
[ -f "$BRIC_LOG_DIR/events/2026-09-05/$(_bric_log_host)/$STEM" ] || fail "day-one event not filed under 2026-09-05"
[ -f "$BRIC_LOG_DIR/events/2026-09-07/$(_bric_log_host)/$STEM" ] || fail "day-two event not filed under 2026-09-07"
echo "  ok: long-running process rotates structured events by current event date"

# Structured-only failover: do not print raw stdout/stderr between primary failure and this event.
rm -rf "$BRIC_LOG_DIR"; : >"$BRIC_LOG_DIR"
bric_event WARN STRUCTURED_ONLY_AFTER_FAILOVER fallback-required
HOST="$(_bric_log_host)"
grep -Rqs '|STRUCTURED_ONLY_AFTER_FAILOVER|' "$BRIC_LOG_FALLBACK_DIR/events/2026-09-07/$HOST" \
  || fail "triggering structured event did not reach fallback"
grep -Rqs '|LOG_FAILOVER|' "$BRIC_LOG_FALLBACK_DIR/events/2026-09-07/$HOST" \
  || fail "structured-only failover breadcrumb missing"
echo "  ok: structured-only primary failure emits LOG_FAILOVER on fallback"

echo "PASS run_event_rotation"
