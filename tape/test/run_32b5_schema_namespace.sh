#!/bin/bash
# Review 32B5: additive schema/migration, logical-root validation/backfill and pre-reservation collision fence.
set -euo pipefail
IFS=$'\n\t'
ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
TMP="$(mktemp -d /tmp/bric-32b5-schema.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/log/primary" "$TMP/log/fallback" "$TMP/qnap" "$TMP/runstate" "$TMP/src/live" "$TMP/home/.bric"
export BRIC_CONFIG=none BRIC_ROLE=slurm BRIC_USER=vsz652 BRIC_ALLOW_USER_OVERRIDE=1
export BRIC_LOG_DIR="$TMP/log/primary" BRIC_LOG_FALLBACK_DIR="$TMP/log/fallback" BRIC_REQUIRE_LOGGING=1
export BRIC_QNAP="$TMP/qnap" BRIC_RUNSTATE="$TMP/runstate" HOME="$TMP/home"
export BRIC_HOME="$ROOT/cluster" BRIC_SQL_INIT="$ROOT/cluster/sql/cluster_init.sql"

fresh="$TMP/fresh.db"; legacy="$TMP/legacy.db"
sqlite3 "$fresh" < "$ROOT/cluster/sql/cluster_init.sql" >/dev/null
# Construct the precise pre-32B5 runs layout from the current schema by removing only the two additive columns.
sed '/^[[:space:]]*source_canonical_path TEXT,/d;/^[[:space:]]*logical_root[[:space:]]*TEXT,/d' \
  "$ROOT/cluster/sql/cluster_init.sql" | sqlite3 "$legacy" >/dev/null

live_src="$TMP/src/live"
missing_src="$TMP/src/gone/ghost"
sqlite3 "$legacy" "
INSERT INTO projects(project_name,owner,status) VALUES('p','vsz652','ACTIVE');
INSERT INTO runs(run_id,project_name,kind,source_path,submitted_by,owner,status,requested_at,closed_at)
VALUES('p__20260901T000000Z__0001','p','ARCHIVE','$live_src','vsz652','vsz652','CLOSED','2026-09-01 00:00:00','2026-09-01 00:01:00'),
      ('p__20260902T000000Z__0002','p','APPEND','$missing_src','vsz652','vsz652','CLOSED','2026-09-02 00:00:00','2026-09-02 00:01:00');
"

export BRIC_DB="$legacy"
# shellcheck source=/dev/null
. "$ROOT/cluster/scripts/lib_common.sh"
bric_ensure_v32b5_cluster_schema
cols_migrated="$(sqlite3 "$legacy" "SELECT group_concat(name,'|') FROM pragma_table_info('runs');")"
cols_fresh="$(sqlite3 "$fresh" "SELECT group_concat(name,'|') FROM pragma_table_info('runs');")"
[ "$cols_migrated" = "$cols_fresh" ] || { echo "FAIL: fresh/migrated runs column order differs" >&2; echo "$cols_migrated"; echo "$cols_fresh"; exit 1; }
[ "$(sqlite3 "$legacy" "SELECT logical_root FROM runs WHERE run_id='p__20260901T000000Z__0001';")" = live ]
[ "$(sqlite3 "$legacy" "SELECT source_canonical_path FROM runs WHERE run_id='p__20260901T000000Z__0001';")" = "$(readlink -f "$live_src")" ]
[ "$(sqlite3 "$legacy" "SELECT logical_root FROM runs WHERE run_id='p__20260902T000000Z__0002';")" = ghost ]
[ -z "$(sqlite3 "$legacy" "SELECT COALESCE(source_canonical_path,'') FROM runs WHERE run_id='p__20260902T000000Z__0002';")" ]
# Idempotency: a second migration changes neither schema nor metadata.
before="$(sqlite3 "$legacy" "SELECT run_id||'|'||COALESCE(source_canonical_path,'')||'|'||COALESCE(logical_root,'') FROM runs ORDER BY run_id;")"
bric_ensure_v32b5_cluster_schema
after="$(sqlite3 "$legacy" "SELECT run_id||'|'||COALESCE(source_canonical_path,'')||'|'||COALESCE(logical_root,'') FROM runs ORDER BY run_id;")"
[ "$before" = "$after" ]
[ "$cols_migrated" = "$(sqlite3 "$legacy" "SELECT group_concat(name,'|') FROM pragma_table_info('runs');")" ]

# Exercise the exact explicit runs-column copy contract used by bric-close against fresh 32B5 schema.
pdb="$TMP/project.db"; sqlite3 "$pdb" < "$ROOT/cluster/sql/cluster_init.sql" >/dev/null
sqlite3 "$pdb" "ATTACH DATABASE '$legacy' AS src;
INSERT OR REPLACE INTO projects SELECT * FROM src.projects WHERE project_name='p';
INSERT OR REPLACE INTO runs(run_id,project_name,kind,source_path,submitted_by,owner,slurm_array_job,n_chunks,total_bytes,status,error,requested_at,closed_at,source_canonical_path,logical_root)
SELECT run_id,project_name,kind,source_path,submitted_by,owner,slurm_array_job,n_chunks,total_bytes,status,error,requested_at,closed_at,source_canonical_path,logical_root FROM src.runs WHERE project_name='p';
DETACH DATABASE src;"
[ "$(sqlite3 "$pdb" "SELECT COUNT(*) FROM runs;")" -eq 2 ]
[ "$(sqlite3 "$pdb" "SELECT logical_root FROM runs WHERE run_id='p__20260902T000000Z__0002';")" = ghost ]

# Validator: one component, NFC, <=255 bytes, no traversal/control/slash.
[ "$(bric_validate_logical_root 'alpha-01')" = alpha-01 ]
nfc_name="$(printf 'caf\303\251')"
decomp_name="$(printf 'cafe\314\201')"
[ "$(bric_validate_logical_root "$nfc_name")" = "$nfc_name" ]
for bad in '.' '..' 'a/b' 'a,b' $'bad\nname' "$decomp_name"; do
  if bric_validate_logical_root "$bad" >/dev/null 2>&1; then echo "FAIL: invalid logical root accepted" >&2; exit 1; fi
done
long="$(printf 'x%.0s' {1..256})"
if bric_validate_logical_root "$long" >/dev/null 2>&1; then echo "FAIL: 256-byte logical root accepted" >&2; exit 1; fi

# bric-run rejects malformed --as before preflight/background job creation.
if BRIC_DB="$legacy" "$ROOT/cluster/bin/bric-run" backup p "$live_src" --as 'bad/name' >"$TMP/bad-as.out" 2>"$TMP/bad-as.err"; then
  echo 'FAIL: bric-run accepted malformed --as' >&2; exit 1
fi
grep -q 'invalid --as' "$TMP/bad-as.err"
[ ! -d "$HOME/.bric/pids" ] || ! find "$HOME/.bric/pids" -name '*.meta' -print -quit | grep -q .

# Unknown canonical path in a historical CLOSED run fences the same root before any reservation marker.
# Use a source whose canonical path is known now but force the colliding historical binding to NULL.
mkdir -p "$TMP/src/newsource"
sqlite3 "$legacy" "UPDATE runs SET logical_root='reserved-root',source_canonical_path=NULL WHERE run_id='p__20260902T000000Z__0002';"
pre_runs="$(sqlite3 "$legacy" "SELECT COUNT(*) FROM runs;")"
if BRIC_DB="$legacy" BRIC_RESERVE_TIMEOUT=1 "$ROOT/cluster/scripts/bric-stream-plan.sh" \
    --project p --source "$TMP/src/newsource" --as reserved-root --owner vsz652 >"$TMP/collision.out" 2>"$TMP/collision.err"; then
  echo 'FAIL: planner accepted a root whose historical canonical source is unknown' >&2; exit 1
fi
grep -q "logical root 'reserved-root' is already bound" "$TMP/collision.err"
[ "$(sqlite3 "$legacy" "SELECT COUNT(*) FROM runs;")" = "$pre_runs" ]
[ ! -e "$TMP/qnap/archive/p" ] || [ -z "$(find "$TMP/qnap/archive/p" -name run.RESERVE_REQUEST -print -quit 2>/dev/null)" ]

echo 'PASS: 32B5 fresh/migrated schema order, idempotent legacy backfill, validation and pre-reservation collision fence'
