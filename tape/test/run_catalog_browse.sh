#!/bin/bash
# Review 32B5: catalog-only logical namespace, multi-run latest-wins/history, filtering and pagination.
set -euo pipefail
IFS=$'\n\t'
ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
TMP="$(mktemp -d /tmp/bric-catalog-browse.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
DB="$TMP/cluster.db"
HOME_DIR="$TMP/home"
mkdir -p "$HOME_DIR/.bric" "$TMP/log/primary" "$TMP/log/fallback"
sqlite3 "$DB" < "$ROOT/cluster/sql/cluster_init.sql" >/dev/null
sqlite3 "$DB" <<'SQL'
INSERT INTO projects(project_name,owner,status) VALUES
 ('project_a','vsz652','ACTIVE'),
 ('project_b','otheruser','ACTIVE');
INSERT INTO runs(run_id,project_name,kind,source_path,submitted_by,owner,status,requested_at,closed_at,source_canonical_path,logical_root) VALUES
 ('project_a__20260701T000000Z__0001','project_a','ARCHIVE','/src/alpha','vsz652','vsz652','CLOSED','2026-07-01 00:00:00','2026-07-01 00:10:00','/src/alpha','alpha'),
 ('project_a__20260702T000000Z__0002','project_a','APPEND','/src/alpha','vsz652','vsz652','CLOSED','2026-07-02 00:00:00','2026-07-02 00:10:00','/src/alpha','alpha'),
 ('project_a__20260702T120000Z__0003','project_a','APPEND','/src/beta','vsz652','vsz652','CLOSED','2026-07-02 12:00:00','2026-07-02 12:10:00','/src/beta','beta'),
 ('project_a__20260703T000000Z__0004','project_a','APPEND','/src/alpha','vsz652','vsz652','FAILED','2026-07-03 00:00:00',NULL,'/src/alpha','alpha'),
 ('project_b__20260702T000000Z__0001','project_b','ARCHIVE','/src/secret','otheruser','otheruser','CLOSED','2026-07-02 00:00:00','2026-07-02 00:10:00','/src/secret','secret');
INSERT INTO files(run_id,rel_path,size_bytes,mtime,sha256_plain,chunk_no,member_index,entry_type) VALUES
 ('project_a__20260701T000000Z__0001','old/file.txt',11,1700000000,'a',1,0,'F'),
 ('project_a__20260701T000000Z__0001','shared.txt',10,1700000001,'old',1,1,'F'),
 ('project_a__20260702T000000Z__0002','docs',0,1700000100,'',1,0,'D'),
 ('project_a__20260702T000000Z__0002','docs/read me.txt',12,1700000200,'b',1,1,'F'),
 ('project_a__20260702T000000Z__0002','raw/Sample01.BAM',4096,1700000300,'c',2,0,'F'),
 ('project_a__20260702T000000Z__0002','shared.txt',20,1700000400,'new',2,1,'F'),
 ('project_a__20260702T000000Z__0002','weird
name.txt',7,1700000500,'d',3,0,'F'),
 ('project_a__20260702T120000Z__0003','shared.txt',30,1700000550,'beta',1,0,'F'),
 ('project_a__20260702T120000Z__0003','other only.txt',31,1700000560,'beta2',1,1,'F'),
 ('project_a__20260703T000000Z__0004','partial/not-valid.txt',3,1700000600,'e',1,0,'F'),
 ('project_b__20260702T000000Z__0001','secret.txt',9,1700000700,'f',1,0,'F');
SQL

run_bric() {
  BRIC_CONFIG=none BRIC_ROLE=slurm BRIC_DB="$DB" BRIC_USER=vsz652 \
  BRIC_ALLOW_USER_OVERRIDE=1 HOME="$HOME_DIR" \
  BRIC_LOG_DIR="$TMP/log/primary" BRIC_LOG_FALLBACK_DIR="$TMP/log/fallback" \
  BRIC_REQUIRE_LOGGING=1 "$ROOT/cluster/bin/bric-run" "$@"
}

# Help is available without runtime preflight or job creation.
run_bric contents --help > "$TMP/contents.help"
run_bric find help > "$TMP/find.help"
grep -q '^Usage: bric contents PROJECT' "$TMP/contents.help"
grep -q '^Usage: bric find PROJECT QUERY' "$TMP/find.help"
grep -q -- '--history' "$TMP/contents.help"
! grep -q preflight "$TMP/contents.help"
[ ! -d "$HOME_DIR/.bric/pids" ] || ! find "$HOME_DIR/.bric/pids" -name '*.meta' -print -quit | grep -q .

# Default project view is the union of CLOSED runs, deduplicated per logical root/path.
run_bric contents project_a --limit 0 > "$TMP/contents.out" 2> "$TMP/contents.err"
grep -q '^alpha/old/file.txt$' "$TMP/contents.out"                 # old-only file remains visible
grep -q '^alpha/shared.txt$' "$TMP/contents.out"                   # alpha latest version
grep -q '^beta/shared.txt$' "$TMP/contents.out"                    # same rel path in distinct root remains separate
grep -q '^beta/other only.txt$' "$TMP/contents.out"
! grep -q 'partial/not-valid' "$TMP/contents.out"                   # FAILED ignored
[ "$(grep -c '^alpha/shared.txt$' "$TMP/contents.out")" -eq 1 ]
grep -q 'view=project history=no total=8 shown=8 offset=0' "$TMP/contents.err"

# Explicit --run is exact/immutable; 32B5 consistently displays the logical prefix in browse output.
run_bric contents project_a --run project_a__20260701T000000Z__0001 --limit 0 > "$TMP/old.out" 2> "$TMP/old.err"
grep -q '^alpha/old/file.txt$' "$TMP/old.out"
grep -q '^alpha/shared.txt$' "$TMP/old.out"
! grep -q '^alpha/docs' "$TMP/old.out"
grep -q 'run=project_a__20260701T000000Z__0001 history=no total=2 shown=2 offset=0' "$TMP/old.err"

# --history exposes every version with an unambiguous run id.
run_bric contents project_a --history --limit 0 > "$TMP/history.out" 2> "$TMP/history.err"
grep -Fq $'project_a__20260701T000000Z__0001\talpha/shared.txt' "$TMP/history.out"
grep -Fq $'project_a__20260702T000000Z__0002\talpha/shared.txt' "$TMP/history.out"
grep -Fq $'project_a__20260702T120000Z__0003\tbeta/shared.txt' "$TMP/history.out"
[ "$(grep -c $'\talpha/shared.txt$' "$TMP/history.out")" -eq 2 ]
if run_bric contents project_a --history --run project_a__20260701T000000Z__0001 >"$TMP/mix.out" 2>"$TMP/mix.err"; then
  echo 'FAIL: --history combined with --run was accepted' >&2; exit 1
fi
grep -q -- '--history cannot be combined with --run' "$TMP/mix.err"

# Type filtering and long output are applied after the logical view is built.
run_bric contents project_a --type file --long --limit 0 > "$TMP/long.out" 2> "$TMP/long.err"
grep -q 'TYPE' "$TMP/long.out"
grep -q 'alpha/raw/Sample01.BAM' "$TMP/long.out"
! grep -Eq '(^|[[:space:]])DIR([[:space:]]|$)' "$TMP/long.out"
run_bric contents project_a --history --long --limit 0 > "$TMP/history-long.out" 2>/dev/null
grep -q 'RUN_ID' "$TMP/history-long.out"

# Search is case-insensitive over the complete logical path and escapes embedded newlines.
run_bric find project_a sample01 > "$TMP/find.out" 2> "$TMP/find.err"
grep -q '^alpha/raw/Sample01.BAM$' "$TMP/find.out"
run_bric find project_a beta/shared > "$TMP/find-root.out" 2>/dev/null
grep -q '^beta/shared.txt$' "$TMP/find-root.out"
run_bric find project_a name.txt --limit 0 > "$TMP/weird.out" 2> "$TMP/weird.err"
grep -Fq 'alpha/weird\nname.txt' "$TMP/weird.out"

# Pagination is global across roots, not per run/root.
run_bric contents project_a --limit 3 --offset 2 > "$TMP/page.out" 2> "$TMP/page.err"
[ "$(wc -l < "$TMP/page.out")" -eq 3 ]
grep -q 'view=project history=no total=8 shown=3 offset=2' "$TMP/page.err"
grep -q 'use --offset 5' "$TMP/page.err"

# Failed runs are not valid exact views.
if run_bric contents project_a --run project_a__20260703T000000Z__0004 >"$TMP/bad.out" 2>"$TMP/bad.err"; then
  echo 'FAIL: FAILED run accepted for contents' >&2; exit 1
fi
grep -q 'is FAILED' "$TMP/bad.err"

# Argument/type validation remains synchronous and catalog-only.
if run_bric find project_a >"$TMP/missing.out" 2>"$TMP/missing.err"; then
  echo 'FAIL: find without query accepted' >&2; exit 1
fi
grep -q 'usage: bric find PROJECT QUERY' "$TMP/missing.err"
if run_bric contents project_a --type device >"$TMP/type.out" 2>"$TMP/type.err"; then
  echo 'FAIL: invalid type accepted' >&2; exit 1
fi
grep -q 'expected all|file|dir|link' "$TMP/type.err"

echo 'PASS: 32B5 catalog logical namespace, multi-run latest-wins/history and global filtering/pagination'
