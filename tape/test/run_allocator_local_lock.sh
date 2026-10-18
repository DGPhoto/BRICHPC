#!/bin/bash
# Review 32B3: parallel chunk allocation must never place its correctness flock in BRIC_RUNSTATE,
# because user runstate can live on NFSv3. Member lists may remain shared; the allocator mutex is local.
set -euo pipefail
export BRIC_CONFIG=none
REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
ROOT="$(mktemp -d)"
trap 'rm -rf "$ROOT"' EXIT
fail(){ echo "FAIL: $*" >&2; exit 1; }

export BRIC_HOME="$REPO/cluster"
export BRIC_DB="$ROOT/cluster.db"
export BRIC_SQL_INIT="$REPO/cluster/sql/cluster_init.sql"
export BRIC_RUNSTATE="$ROOT/shared-runstate"
export BRIC_LOCAL_LOCK_DIR="$ROOT/local-locks"
export BRIC_REQUIRE_LOGGING=0
export BRIC_LOG_CAPTURE_STDIO=0
mkdir -p "$BRIC_RUNSTATE" "$BRIC_LOCAL_LOCK_DIR"
chmod 700 "$BRIC_RUNSTATE" "$BRIC_LOCAL_LOCK_DIR"
sqlite3 "$BRIC_DB" < "$BRIC_SQL_INIT" >/dev/null

RUN=locktest__20260914T000000Z__0001
sqlite3 "$BRIC_DB" <<SQL
INSERT INTO projects(project_name,owner) VALUES('locktest','tester');
INSERT INTO runs(run_id,project_name,submitted_by,owner,status)
VALUES('$RUN','locktest','tester','tester','PRODUCING');
SQL

GATE="$ROOT/gate.sh"
cat > "$GATE" <<'GATE'
#!/bin/bash
exit 0
GATE
chmod +x "$GATE"

ALLOC="$REPO/cluster/scripts/bric-stream-allocate.sh"
pids=()
for i in 1 2 3 4; do
    "$ALLOC" --run "$RUN" --type TAR_PART --gate "$GATE" --target 4194304 >"$ROOT/out.$i" 2>"$ROOT/err.$i" &
    pids+=("$!")
done
rc=0
for p in "${pids[@]}"; do wait "$p" || rc=1; done
[ "$rc" -eq 0 ] || { cat "$ROOT"/err.* >&2; fail "concurrent allocator failed"; }

nums="$(cat "$ROOT"/out.* | sort -n | tr '\n' ' ' | sed 's/ $//')"
[ "$nums" = "1 2 3 4" ] || fail "allocator did not serialize unique chunk numbers: $nums"
[ "$(sqlite3 "$BRIC_DB" "SELECT COUNT(*) FROM chunks WHERE run_id='$RUN' AND state='ALLOCATED';")" = 4 ] \
    || fail "allocator catalog does not contain four allocations"
[ ! -e "$BRIC_RUNSTATE/$RUN/chunk-allocate.lock" ] || fail "allocator lock regressed into shared BRIC_RUNSTATE"
[ -f "$BRIC_LOCAL_LOCK_DIR/chunk-allocate.$RUN.lock" ] || fail "local allocator lock was not created"

grep -h "lock=$BRIC_LOCAL_LOCK_DIR/chunk-allocate.$RUN.lock" "$ROOT"/err.* >/dev/null \
    || fail "allocator did not report the local lock path"

echo "PASS run_allocator_local_lock"
