#!/bin/bash
# Review 31B: tar rc=1 is acceptable only for file-changed-only diagnostics under explicit record policy.
set -euo pipefail
REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
DB="$T/catalog.db"
sqlite3 "$DB" < "$REPO/cluster/sql/cluster_init.sql"
export BRIC_DB="$DB" BRIC_CONFIG=none BRIC_LOG_DIR="$T/log" BRIC_LOG_FALLBACK_DIR="$T/log2"
mkdir -p "$BRIC_LOG_DIR" "$BRIC_LOG_FALLBACK_DIR"
HELPER="$REPO/cluster/scripts/bric-source-consistency.sh"

sqlite3 "$DB" "
INSERT INTO projects(project_name,owner) VALUES('p','u');
INSERT INTO runs(run_id,project_name,source_path,submitted_by,owner,status) VALUES('r_strict','p','/src','u','u','PRODUCING');
INSERT INTO runs(run_id,project_name,source_path,submitted_by,owner,status) VALUES('r_record','p','/src','u','u','PRODUCING');
INSERT INTO runs(run_id,project_name,source_path,submitted_by,owner,status) VALUES('r_mixed','p','/src','u','u','PRODUCING');
INSERT INTO runs(run_id,project_name,source_path,submitted_by,owner,status) VALUES('r_fatal','p','/src','u','u','PRODUCING');
INSERT INTO run_source_semantics(run_id,source_change_policy) VALUES('r_strict','strict'),('r_record','record'),('r_mixed','record'),('r_fatal','strict');
"
cat > "$T/changed.err" <<'EOT'
tar: ./python/pkg/a.py: file changed as we read it
tar: ./python/pkg/b:with:colon.py: file changed as we read it
EOT

set +e
"$HELPER" --run r_strict --policy strict --tar-rc 1 --stderr "$T/changed.err" >"$T/s.out" 2>"$T/s.err"
rc=$?
set -e
[ "$rc" -eq 10 ] || { echo "FAIL: strict file-changed rc expected 10, got $rc" >&2; cat "$T/s.err" >&2; exit 1; }
[ "$(sqlite3 "$DB" "SELECT source_changed_count||'|'||source_consistency||'|'||tar_exit_code FROM run_source_semantics WHERE run_id='r_strict';")" = '2|changed-during-read|1' ]
[ "$(sqlite3 "$DB" "SELECT COUNT(*) FROM run_source_changes WHERE run_id='r_strict';")" -eq 2 ]
[ "$(sqlite3 "$DB" "SELECT path_text FROM run_source_changes WHERE run_id='r_strict' AND ordinal=2;")" = 'python/pkg/b:with:colon.py' ]

echo "✓ strict policy catalogs file-changed diagnostics then refuses the non-quiescent run"

"$HELPER" --run r_record --policy record --tar-rc 1 --stderr "$T/changed.err" >"$T/r.out" 2>"$T/r.err"
[ "$(sqlite3 "$DB" "SELECT source_changed_count||'|'||source_consistency||'|'||source_change_policy FROM run_source_semantics WHERE run_id='r_record';")" = '2|changed-during-read|record' ]
[ "$(sqlite3 "$DB" "SELECT COUNT(*) FROM run_source_changes WHERE run_id='r_record';")" -eq 2 ]
grep -q 'record policy accepts the archived bytes' "$T/r.err"
echo "✓ record policy accepts tar rc=1 only when every diagnostic is FILE_CHANGED_DURING_READ"

cat > "$T/mixed.err" <<'EOT'
tar: ./a.py: file changed as we read it
tar: ./missing: Cannot stat: No such file or directory
EOT
set +e
"$HELPER" --run r_mixed --policy record --tar-rc 1 --stderr "$T/mixed.err" >"$T/m.out" 2>"$T/m.err"
rc=$?
set -e
[ "$rc" -eq 11 ] || { echo "FAIL: mixed tar rc=1 diagnostics were accepted" >&2; exit 1; }
[ "$(sqlite3 "$DB" "SELECT source_consistency FROM run_source_semantics WHERE run_id='r_mixed';")" = 'unclassified-tar-warning' ]
[ "$(sqlite3 "$DB" "SELECT COUNT(*) FROM run_source_changes WHERE run_id='r_mixed';")" -eq 0 ]
echo "✓ record policy remains fail-closed on mixed/unclassified tar rc=1 diagnostics"

: > "$T/empty.err"
set +e
"$HELPER" --run r_fatal --policy strict --tar-rc 2 --stderr "$T/empty.err" >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 11 ]
[ "$(sqlite3 "$DB" "SELECT source_consistency||'|'||tar_exit_code FROM run_source_semantics WHERE run_id='r_fatal';")" = 'fatal-tar-error|2' ]
echo "✓ tar rc>=2 is never downgraded"

# Review 31B1: catalog the direction of allocation-topology uncertainty explicitly.
[ "$(sqlite3 "$DB" "SELECT allocation_topology||'|'||restore_allocation_effect FROM run_source_semantics WHERE run_id='r_record';")" = 'not-guaranteed|zero-ranges-may-restore-as-holes' ]
echo "✓ restore allocation effect is explicit in run_source_semantics"
