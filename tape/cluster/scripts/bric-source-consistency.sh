#!/bin/bash
# Review 31B: classify GNU tar source-consistency diagnostics after a successful chunker pass.
# Exit 0: acceptable (clean, or record-policy file-changed-only rc=1)
# Exit 10: file-changed-only diagnostics under strict policy
# Exit 11: tar failure/diagnostics are not safely classifiable
set -euo pipefail
IFS=$'\n\t'
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
. "$HERE/lib_common.sh"

RUN_ID=""; POLICY=""; TAR_RC=""; ERRFILE=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --run) RUN_ID="${2:-}"; shift 2;;
        --policy) POLICY="${2:-}"; shift 2;;
        --tar-rc) TAR_RC="${2:-}"; shift 2;;
        --stderr) ERRFILE="${2:-}"; shift 2;;
        *) die "source consistency: unknown option $1";;
    esac
done
[ -n "$RUN_ID" ] && [ -n "$POLICY" ] && [ -n "$TAR_RC" ] && [ -n "$ERRFILE" ] \
    || die "usage: bric-source-consistency --run RUN_ID --policy strict|record --tar-rc N --stderr FILE"
case "$POLICY" in strict|record) :;; *) die "invalid source change policy '$POLICY' (expected strict|record)";; esac
case "$TAR_RC" in ''|*[!0-9]*) die "invalid tar rc '$TAR_RC'";; esac
[ -f "$ERRFILE" ] || die "tar stderr file not found: $ERRFILE"

bric_ensure_v31b_cluster_schema
# A helper can be exercised against a synthetic run in tests, but production must always have a run row.
[ "$(sql "SELECT COUNT(*) FROM runs WHERE run_id='$(sql_quote "$RUN_ID")';")" -eq 1 ] || die "run not found: $RUN_ID"

sql "INSERT OR IGNORE INTO run_source_semantics(run_id,source_change_policy) VALUES('$(sql_quote "$RUN_ID")','$(sql_quote "$POLICY")');"

# tar rc >=2 is never downgraded. rc=1 is only potentially acceptable when EVERY non-empty diagnostic
# is the exact locale-pinned GNU tar FILE_CHANGED_DURING_READ form. No generic 'ignore failed read'.
if [ "$TAR_RC" -ge 2 ]; then
    sql "DELETE FROM run_source_changes WHERE run_id='$(sql_quote "$RUN_ID")'; UPDATE run_source_semantics SET source_changed_count=0,tar_exit_code=$TAR_RC,source_consistency='fatal-tar-error',updated_at=datetime('now') WHERE run_id='$(sql_quote "$RUN_ID")';"
    exit 11
fi

changed=0
other=0
SQLX="DELETE FROM run_source_changes WHERE run_id='$(sql_quote "$RUN_ID")';"
while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    if [[ "$line" =~ ^tar:\ (.*):\ file\ changed\ as\ we\ read\ it$ ]]; then
        changed=$((changed+1))
        shown="${BASH_REMATCH[1]}"
        [[ "$shown" == ./* ]] && shown="${shown#./}"
        SQLX+="INSERT INTO run_source_changes(run_id,ordinal,kind,path_text,path_encoding,diagnostic) VALUES('$(sql_quote "$RUN_ID")',$changed,'FILE_CHANGED_DURING_READ','$(sql_quote "$shown")','gnu-tar-escape','$(sql_quote "$line")');"
    else
        other=$((other+1))
    fi
done < "$ERRFILE"

if [ "$TAR_RC" -eq 1 ]; then
    if [ "$changed" -eq 0 ] || [ "$other" -ne 0 ]; then
        sql "DELETE FROM run_source_changes WHERE run_id='$(sql_quote "$RUN_ID")'; UPDATE run_source_semantics SET source_changed_count=0,tar_exit_code=1,source_consistency='unclassified-tar-warning',updated_at=datetime('now') WHERE run_id='$(sql_quote "$RUN_ID")';"
        exit 11
    fi
    sqlite3 -batch -cmd '.timeout 60000' "$BRIC_DB" <<SQL
BEGIN IMMEDIATE;
$SQLX
UPDATE run_source_semantics
   SET source_change_policy='$(sql_quote "$POLICY")',source_consistency='changed-during-read',
       source_changed_count=$changed,tar_exit_code=1,updated_at=datetime('now')
 WHERE run_id='$(sql_quote "$RUN_ID")';
COMMIT;
SQL
    if [ "$POLICY" = strict ]; then
        printf 'source consistency: %d path(s) changed while GNU tar read them; strict policy refuses a non-quiescent archive\n' "$changed" >&2
        exit 10
    fi
    printf 'source consistency: %d path(s) changed while GNU tar read them; record policy accepts the archived bytes and catalogs every diagnostic\n' "$changed" >&2
    exit 0
fi

# rc=0: ordinary informational stderr remains non-fatal as in prior releases. File-changed diagnostics
# with rc=0 would be internally inconsistent, so record them and still mark the run non-quiescent.
if [ "$changed" -gt 0 ]; then
    sqlite3 -batch -cmd '.timeout 60000' "$BRIC_DB" <<SQL
BEGIN IMMEDIATE;
$SQLX
UPDATE run_source_semantics
   SET source_change_policy='$(sql_quote "$POLICY")',source_consistency='changed-during-read',
       source_changed_count=$changed,tar_exit_code=0,updated_at=datetime('now')
 WHERE run_id='$(sql_quote "$RUN_ID")';
COMMIT;
SQL
    [ "$POLICY" = record ] && exit 0
    exit 10
fi
sql "DELETE FROM run_source_changes WHERE run_id='$(sql_quote "$RUN_ID")'; UPDATE run_source_semantics SET source_change_policy='$(sql_quote "$POLICY")',source_consistency='clean',source_changed_count=0,tar_exit_code=0,updated_at=datetime('now') WHERE run_id='$(sql_quote "$RUN_ID")';"
exit 0
