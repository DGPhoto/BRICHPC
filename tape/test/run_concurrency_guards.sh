#!/bin/bash
# Concurrency guards (review points #2 and #3):
#   #2 new_run_id() increments the counter atomically -> never reused under rapid succession.
#   #3 bric-plan refuses a new run for a project that already has an active run (one active run/project),
#      but allows a new run once prior runs are terminal (CLOSED/FAILED/...).
set -euo pipefail
export BRIC_CONFIG=none   # hermetic: never read /etc/bric/bric.conf inside tests
IFS=$'\n\t'
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
ROOT="$(dirname "$HERE")"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export BRIC_DB="$TMP/cluster_catalog.db"
export BRIC_QNAP="$TMP/qnap"; mkdir -p "$BRIC_QNAP"
export BRIC_USER="tester"
sqlite3 "$BRIC_DB" < "$ROOT/cluster/sql/cluster_init.sql" >/dev/null
. "$ROOT/cluster/scripts/lib_common.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "  ok: $*"; }

echo "== #2 new_run_id is atomic: 60 rapid ids are all unique and strictly increasing =="
prev=0; n=60
for i in $(seq 1 "$n"); do
    id="$(new_run_id proj)"
    c="${id##*__}"                       # trailing zero-padded counter
    c=$((10#$c))                         # strip leading zeros
    [ "$c" -gt "$prev" ] || fail "counter not strictly increasing: $c after $prev"
    prev="$c"
done
[ "$prev" -ge "$n" ] || fail "expected counter >= $n, got $prev"
ok "$n ids unique + monotone (final counter=$prev)"

echo "== #3 one active run per project: plan refused while a run is active =="
SRC="$TMP/src"; mkdir -p "$SRC"; echo data > "$SRC/f.txt"
# Seed an ACTIVE run for project P (any of the active states must block).
sql "INSERT INTO projects (project_name,owner) VALUES ('P','tester');"
sql "INSERT INTO runs (run_id,project_name,kind,submitted_by,owner,status,requested_at)
     VALUES ('P__seed__0001','P','ARCHIVE','tester','tester','PRODUCING',datetime('now'));"
if "$ROOT/cluster/scripts/bric-plan.sh" --project P --source "$SRC" >/dev/null 2>"$TMP/err"; then
    fail "bric-plan should have refused a second active run for P"
fi
grep -q "already active for project" "$TMP/err" || fail "wrong refusal reason: $(cat "$TMP/err")"
# No extra run row should have been created.
[ "$(sql "SELECT COUNT(*) FROM runs WHERE project_name='P';")" = 1 ] || fail "a blocked plan must not insert a run row"
ok "second concurrent run refused, no row inserted"

echo "== #3 a new run is allowed once the prior run is terminal =="
sql "UPDATE runs SET status='CLOSED' WHERE run_id='P__seed__0001';"
# bric-plan would proceed to plan + block on the (daemon-served) reservation; we only need to prove it
# got PAST the active-run guard, i.e. it inserted a fresh PLANNING run. Run briefly, then stop it.
timeout 6 "$ROOT/cluster/scripts/bric-plan.sh" --project P --source "$SRC" >/dev/null 2>&1 || true
NEW="$(sql "SELECT COUNT(*) FROM runs WHERE project_name='P' AND run_id<>'P__seed__0001';")"
[ "${NEW:-0}" -ge 1 ] || fail "a new run should be allowed after the prior run closed (guard passed)"
ok "new run admitted after prior run reached a terminal state"

echo "PASS run_concurrency_guards"
