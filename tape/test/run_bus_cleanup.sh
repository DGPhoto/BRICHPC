#!/bin/bash
set -euo pipefail
IFS=$'\n\t'
REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
export BRIC_CONFIG=none BRIC_ROLE=slurm BRIC_HOME="$REPO/cluster" BRIC_DB="$ROOT/cluster.db"
export BRIC_QNAP="$ROOT/qnap" BRIC_REQUIRE_NFS_BUS=0 BRIC_KEEP_TERMINAL_BUS=0
export BRIC_LOG_DIR="$ROOT/log" BRIC_LOG_FALLBACK_DIR="$ROOT/log2" BRIC_REQUIRE_LOGGING=0
mkdir -p "$BRIC_QNAP/archive/p" "$BRIC_QNAP/restore/p" "$BRIC_LOG_DIR" "$BRIC_LOG_FALLBACK_DIR"
sqlite3 "$BRIC_DB" < "$REPO/cluster/sql/cluster_init.sql" >/dev/null
sqlite3 "$BRIC_DB" <<'SQL'
INSERT INTO projects(project_name,owner) VALUES('p','tester');
INSERT INTO runs(run_id,project_name,kind,submitted_by,owner,status) VALUES
 ('p__20260731T000000Z__0001','p','ARCHIVE','tester','tester','CLOSED'),
 ('p__20260731T000000Z__0002','p','ARCHIVE','tester','tester','DENIED'),
 ('p__20260731T000000Z__0003','p','ARCHIVE','tester','tester','FAILED'),
 ('p__20260731T000000Z__0004','p','ARCHIVE','tester','tester','PRODUCING');
SQL
for n in 1 2 3 4; do d="$BRIC_QNAP/archive/p/p__20260731T000000Z__$(printf '%04d' "$n")"; mkdir -p "$d"; printf payload > "$d/chunk_0001.enc"; done
: > "$BRIC_QNAP/archive/p/p__20260731T000000Z__0001/run.CLOSED"
: > "$BRIC_QNAP/archive/p/p__20260731T000000Z__0002/run.DENIED"
# FAILED intentionally lacks ABORT_DONE on first pass.

set +e
BRIC_KEEP_TERMINAL_BUS=0 "$REPO/cluster/bin/bric-bus-cleanup" --dry-run >"$ROOT/dry" 2>&1
rc=$?
set -e
[ "$rc" -eq 1 ] || { echo "FAIL: dry-run should report deferred FAILED run"; exit 1; }
grep -q 'REMOVE CLOSED' "$ROOT/dry"
grep -q 'REMOVE DENIED' "$ROOT/dry"
grep -q 'DEFER FAILED' "$ROOT/dry"
grep -q 'KEEP  active/non-terminal PRODUCING' "$ROOT/dry"
[ -e "$BRIC_QNAP/archive/p/p__20260731T000000Z__0001/chunk_0001.enc" ] || { echo "FAIL: dry-run removed data"; exit 1; }

: > "$BRIC_QNAP/archive/p/p__20260731T000000Z__0003/run.ABORT_DONE"
BRIC_KEEP_TERMINAL_BUS=0 "$REPO/cluster/bin/bric-bus-cleanup" >"$ROOT/apply"
for n in 1 2 3; do [ ! -e "$BRIC_QNAP/archive/p/p__20260731T000000Z__$(printf '%04d' "$n")" ] || { echo "FAIL: terminal run $n remains"; exit 1; }; done
[ -d "$BRIC_QNAP/archive/p/p__20260731T000000Z__0004" ] || { echo "FAIL: active run removed"; exit 1; }
[ ! -d "$BRIC_QNAP/restore/p" ] || { echo "FAIL: empty restore project dir remains"; exit 1; }

# Helper respects retention escape hatch.
. "$REPO/cluster/scripts/lib_common.sh"
mkdir -p "$BRIC_QNAP/archive/p/p__20260731T000000Z__0001"; : > "$BRIC_QNAP/archive/p/p__20260731T000000Z__0001/run.CLOSED"
BRIC_KEEP_TERMINAL_BUS=1 bus_cleanup_run_dir p p__20260731T000000Z__0001 CLOSED
[ -d "$BRIC_QNAP/archive/p/p__20260731T000000Z__0001" ] || { echo "FAIL: retention override ignored"; exit 1; }
BRIC_KEEP_TERMINAL_BUS=0 bus_cleanup_run_dir p p__20260731T000000Z__0001 CLOSED
[ ! -e "$BRIC_QNAP/archive/p/p__20260731T000000Z__0001" ] || { echo "FAIL: helper did not remove CLOSED run"; exit 1; }

echo "PASS: terminal QNAP bus cleanup is receipt-gated, preserves active runs, supports dry-run and prunes empty restore directories"
