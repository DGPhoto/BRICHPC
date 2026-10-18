#!/bin/bash
# Unit test for the global producer admission gate (producer_slot_acquire).
# The gate lives on the cluster side and is arbitrated purely in cluster_catalog.db, so it can be
# tested directly without SLURM: we drive runs through the RESERVED -> PRODUCING -> DRAINING states
# and assert that at most `max_concurrent_producers` runs are ever PRODUCING at once.
set -euo pipefail
export BRIC_CONFIG=none   # hermetic: never read /etc/bric/bric.conf inside tests
IFS=$'\n\t'
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
ROOT="$(dirname "$HERE")"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export BRIC_DB="$TMP/cluster_catalog.db"
sqlite3 "$BRIC_DB" < "$ROOT/cluster/sql/cluster_init.sql" >/dev/null

# Pull in just the helpers we need. lib_common.sh is source-safe (defines functions, no side effects).
. "$ROOT/cluster/scripts/lib_common.sh"

mkrun() { # run_id status
    sql "INSERT OR IGNORE INTO projects(project_name,owner) VALUES('p','u');
         INSERT INTO runs (run_id,project_name,kind,submitted_by,owner,n_chunks,total_bytes,status,requested_at)
         VALUES ('$1','p','ARCHIVE','u','u',1,1,'$2',datetime('now'));"
}
st() { sql "SELECT status FROM runs WHERE run_id='$1';"; }
producing_count() { sql "SELECT COUNT(*) FROM runs WHERE status='PRODUCING';"; }

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "  ok: $*"; }

echo "== producer slot: fresh default max=1 =="
[ "$(sql "SELECT value FROM config WHERE key='max_concurrent_producers';")" = 1 ] || fail "fresh default should be 1"
ok "fresh default is 1 (single run uses internal workers)"

echo "== producer slot: forced max=1 mutual exclusion =="
sql "UPDATE config SET value='1' WHERE key='max_concurrent_producers';"
mkrun A RESERVED; mkrun B RESERVED

# A acquires immediately (slot free).
BRIC_PRODUCER_WAIT=5 producer_slot_acquire A
[ "$(st A)" = PRODUCING ] || fail "A should be PRODUCING"
[ "$(producing_count)" = 1 ] || fail "exactly one producer expected"
ok "A acquired the slot"

# B must NOT be able to acquire while A holds it. Probe in a subshell (the helper `die`s on give-up,
# which is correct in production but would otherwise exit this test) with an instant give-up window.
if ( BRIC_PRODUCER_WAIT=0 producer_slot_acquire B ) 2>/dev/null; then
    fail "B acquired the slot while A was PRODUCING (mutual exclusion broken)"
fi
[ "$(st B)" = RESERVED ] || fail "B should still be RESERVED after failing to acquire"
[ "$(producing_count)" = 1 ] || fail "still exactly one producer expected"
ok "B correctly blocked while A produces"

# A finishes producing -> finalize moves it to DRAINING (slot released). Tape write of A can now run
# concurrently with B producing; here we just assert the handoff.
sql "UPDATE runs SET status='DRAINING' WHERE run_id='A';"
[ "$(producing_count)" = 0 ] || fail "slot should be free after A -> DRAINING"
BRIC_PRODUCER_WAIT=5 producer_slot_acquire B
[ "$(st B)" = PRODUCING ] || fail "B should acquire after A released"
[ "$(st A)" = DRAINING ] || fail "A should remain DRAINING (draining to tape) while B produces"
[ "$(producing_count)" = 1 ] || fail "exactly one producer expected after handoff"
ok "handoff: B produces while A drains to tape (overlap)"

echo "== producer slot: max=2 allows two =="
sql "UPDATE config SET value='2' WHERE key='max_concurrent_producers';"
# reset
sql "DELETE FROM runs;"
mkrun C RESERVED; mkrun D RESERVED; mkrun E RESERVED
BRIC_PRODUCER_WAIT=5 producer_slot_acquire C
BRIC_PRODUCER_WAIT=5 producer_slot_acquire D
[ "$(producing_count)" = 2 ] || fail "two producers expected with max=2"
ok "C and D both acquired (max=2)"
if ( BRIC_PRODUCER_WAIT=0 producer_slot_acquire E ) 2>/dev/null; then
    fail "E acquired a 3rd slot with max=2"
fi
[ "$(producing_count)" = 2 ] || fail "still two producers expected"
ok "E correctly blocked beyond max=2"

echo "PASS run_producer_slot"
