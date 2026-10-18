#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
P="$ROOT/cluster/scripts/bric-plan.sh"
grep -Fq "find . -type f -printf '%P\\0%s\\0%T@\\0'" "$P"
grep -Fq 'sqlite3 -batch -cmd' "$P"
grep -Fq '< "$PLAN_SQL"' "$P"
grep -Fq "'BEGIN IMMEDIATE;'" "$P"
grep -Fq "sql_emit 'COMMIT;'" "$P"
grep -Fq 'planning progress:' "$P"
! grep -q "stat -c'%s|%Y'" "$P"
! grep -q 'sort -z' "$P"
# The hot regular-file loop must not invoke the sql() helper per file.
LOOP="$(sed -n '/while IFS= read -r -d.*rel/,/done < <(cd.*find .*type f/p' "$P")"
! printf '%s\n' "$LOOP" | grep -Eq '^[[:space:]]*sql "'
echo 'PASS: planner uses find metadata and one batched SQLite transaction'
