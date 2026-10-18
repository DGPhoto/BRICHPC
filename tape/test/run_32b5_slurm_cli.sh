#!/bin/bash
# Review 32B5R2 regression: Slurm backup/restore values travel through env while --export contains
# only allow-listed names; comma logical roots are rejected; --wait uses requested_at.
set -euo pipefail
export BRIC_CONFIG=none
ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
TMP="$(mktemp -d /tmp/bric-32b5r2-slurm.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/qnap" "$TMP/src" "$TMP/slurm-log" "$TMP/log" "$TMP/fallback"
export BRIC_ROLE=slurm
export BRIC_HOME="$ROOT/cluster"
export BRIC_DB="$TMP/catalog.db"
export BRIC_QNAP="$TMP/qnap"
export BRIC_REQUIRE_NFS_BUS=0
export BRIC_RUN_MODE=slurm
export BRIC_SLURM_LOGDIR="$TMP/slurm-log"
export BRIC_LOG_DIR="$TMP/log"
export BRIC_LOG_FALLBACK_DIR="$TMP/fallback"
export BRIC_REQUIRE_LOGGING=0
export BRIC_USER="$(id -un)"
export BRIC_TEST_CAPTURE="$TMP/sbatch.capture"
export STRAY_SECRET='must-not-be-exported-to-job'

sqlite3 "$BRIC_DB" < "$ROOT/cluster/sql/cluster_init.sql" >/dev/null
sqlite3 "$BRIC_DB" "INSERT INTO projects(project_name,owner) VALUES('slurmproj','$(id -un)');"

cat > "$TMP/bin/sbatch" <<'STUB'
#!/bin/bash
set -euo pipefail
{
  printf 'ROOT=%s\n' "${BRIC_LOGICAL_ROOT-}"
  printf 'SOURCE=%s\n' "${BRIC_SOURCE-}"
  printf 'DECLARED=%s\n' "${BRIC_SOURCE_DECLARED-}"
  printf 'RESTORE_PROJECT=%s\n' "${BRIC_RESTORE_PROJECT-}"
  printf 'RESTORE_DEST=%s\n' "${BRIC_RESTORE_DEST-}"
  printf 'RESTORE_FILE=%s\n' "${BRIC_RESTORE_FILE-}"
  printf 'RESTORE_REQUIRE=%s\n' "${BRIC_RESTORE_REQUIRE_DEST_VERIFY-}"
  printf 'ARGS='; printf '%q ' "$@"; printf '\n'
  for arg in "$@"; do case "$arg" in --export=*) printf 'EXPORT_ARG=%s\n' "$arg";; esac; done
} > "$BRIC_TEST_CAPTURE"
# Backup --wait expects a newly submitted run to exist. Restore does not.
case " $* " in
  *"/orchestrate.sbatch"*)
    run='slurmproj__20990101T000000Z__0001'
    sqlite3 "$BRIC_DB" "INSERT OR IGNORE INTO runs(run_id,project_name,kind,source_path,submitted_by,owner,status,requested_at,source_canonical_path,logical_root) VALUES('$run','slurmproj','ARCHIVE','${BRIC_SOURCE//\'/\'\'}','$(id -un)','$(id -un)','CLOSED','2099-01-01 00:00:00','${BRIC_SOURCE//\'/\'\'}','${BRIC_LOGICAL_ROOT//\'/\'\'}');"
    ;;
esac
printf '4242\n'
STUB
chmod +x "$TMP/bin/sbatch"
export PATH="$TMP/bin:$PATH"

# Comma is rejected at the namespace boundary, before any Slurm submission.
if "$ROOT/cluster/bin/bric" backup --project slurmproj --source "$TMP/src" --as 'data,2024' >"$TMP/comma.out" 2>"$TMP/comma.err"; then
  echo 'FAIL: comma logical root accepted' >&2; exit 1
fi
grep -q 'invalid --as' "$TMP/comma.err"

# '=' remains valid and must travel byte-exact via process environment; values never enter --export.
logical='data=2024'
out="$("$ROOT/cluster/bin/bric" backup --project slurmproj --source "$TMP/src" --as "$logical" --wait)"
grep -qx "ROOT=$logical" "$BRIC_TEST_CAPTURE"
grep -qx "SOURCE=$TMP/src" "$BRIC_TEST_CAPTURE"
grep -qx "DECLARED=$TMP/src" "$BRIC_TEST_CAPTURE"
export_arg="$(grep '^EXPORT_ARG=' "$BRIC_TEST_CAPTURE" | cut -d= -f2-)"
case "$export_arg" in
  --export=ALL|*',ALL,'*|*',ALL'|--export=ALL,*) echo 'FAIL: blanket ALL export used' >&2; exit 1;;
esac
printf '%s\n' "$export_arg" | grep -q 'BRIC_PROJECT'
printf '%s\n' "$export_arg" | grep -q 'BRIC_LOGICAL_ROOT'
if printf '%s\n' "$export_arg" | grep -q 'STRAY_SECRET'; then echo 'FAIL: unrelated variable exported' >&2; exit 1; fi
if grep '^ARGS=' "$BRIC_TEST_CAPTURE" | grep -Fq "$logical"; then echo 'FAIL: backup value serialized in argv' >&2; exit 1; fi
printf '%s\n' "$out" | grep -q 'slurmproj__20990101T000000Z__0001'
[ "$(sqlite3 "$BRIC_DB" "SELECT logical_root FROM runs WHERE run_id='slurmproj__20990101T000000Z__0001';")" = "$logical" ]

# Restore values may legitimately contain commas below the root, and DEST may contain commas too.
# They must also travel through env with a names-only export list.
restore_dest="$TMP/restore,dest"
restore_file='data=2024/sample,1.fastq'
"$ROOT/cluster/bin/bric" restore --project slurmproj --dest "$restore_dest" --file "$restore_file" --require-destination-verify >/dev/null
grep -qx 'RESTORE_PROJECT=slurmproj' "$BRIC_TEST_CAPTURE"
grep -qx "RESTORE_DEST=$restore_dest" "$BRIC_TEST_CAPTURE"
grep -qx "RESTORE_FILE=$restore_file" "$BRIC_TEST_CAPTURE"
grep -qx "RESTORE_REQUIRE=1" "$BRIC_TEST_CAPTURE"
export_arg="$(grep '^EXPORT_ARG=' "$BRIC_TEST_CAPTURE" | cut -d= -f2-)"
case "$export_arg" in
  --export=ALL|*',ALL,'*|*',ALL'|--export=ALL,*) echo 'FAIL: restore used blanket ALL export' >&2; exit 1;;
esac
printf '%s\n' "$export_arg" | grep -q 'BRIC_RESTORE_PROJECT'
printf '%s\n' "$export_arg" | grep -q 'BRIC_RESTORE_DEST'
printf '%s\n' "$export_arg" | grep -q 'BRIC_RESTORE_FILE'
printf '%s\n' "$export_arg" | grep -q 'BRIC_RESTORE_REQUIRE_DEST_VERIFY'
if printf '%s\n' "$export_arg" | grep -q 'STRAY_SECRET'; then echo 'FAIL: unrelated variable exported by restore' >&2; exit 1; fi
if grep '^ARGS=' "$BRIC_TEST_CAPTURE" | grep -Fq "$restore_file"; then echo 'FAIL: restore file serialized in argv' >&2; exit 1; fi
if grep '^ARGS=' "$BRIC_TEST_CAPTURE" | grep -Fq "$restore_dest"; then echo 'FAIL: restore destination serialized in argv' >&2; exit 1; fi

# The downstream orchestrator must keep the same hygiene for array/finalize submissions.
if grep -q 'EXPORTS="ALL"' "$ROOT/cluster/scripts/bric-orchestrate.sh" || grep -Eq '^[[:space:]]*[^#].*--export=ALL' "$ROOT/cluster/scripts/bric-orchestrate.sh"; then echo 'FAIL: orchestrator uses blanket ALL export' >&2; exit 1; fi
grep -Fq 'AID="$(env "${SBATCH_ENV[@]}" sbatch' "$ROOT/cluster/scripts/bric-orchestrate.sh"
grep -Fq 'FID="$(env "${SBATCH_ENV[@]}" sbatch' "$ROOT/cluster/scripts/bric-orchestrate.sh"
if grep -q -- '--export="$EXPORTS,BRIC_RUN_ID=' "$ROOT/cluster/scripts/bric-orchestrate.sh"; then echo 'FAIL: orchestrator serializes BRIC_RUN_ID in export grammar' >&2; exit 1; fi

echo 'PASS: Slurm backup/restore/orchestrator use allow-listed name exports; comma roots rejected; --wait uses requested_at'
