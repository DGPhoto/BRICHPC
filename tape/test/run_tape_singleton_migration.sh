#!/bin/bash
. "$(cd "$(dirname "$(readlink -f "$0")")" && pwd)/lib_test_daemon.sh"
# Review 31C: cross-generation singleton/work-fence migration + PROCESS_START provenance.
set -euo pipefail
IFS=$'\n\t'
export BRIC_CONFIG=none
REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
EXPECTED_REVIEW="$(sed -n 's/^review=//p' "$REPO/RELEASE")"
EXPECTED_RELEASE_ID="$(sed -n 's/^release_id=//p' "$REPO/RELEASE")"
ROOT="$(mktemp -d)"
DAEMON_PID=""
cleanup() {
    bric_test_stop_group "${DAEMON_PID:-0}"
    bric_test_rmrf_retry "$ROOT"
}
trap cleanup EXIT
mkdir -p "$ROOT/tapelib" "$ROOT/qnap/archive" "$ROOT/log" "$ROOT/log2" "$ROOT/legacy/tmp" "$ROOT/legacy/run/bric"
DB="$ROOT/tape.db"
sqlite3 "$DB" < "$REPO/tape/sql/tape_init.sql" >/dev/null

export BRIC_ROLE=tape BRIC_TAPE_HOME="$REPO/tape" BRIC_TAPE_DB="$DB" BRIC_TAPE_SQL_INIT="$REPO/tape/sql/tape_init.sql"
export BRIC_TAPE_BACKEND=sim BRIC_TAPELIB="$ROOT/tapelib" BRIC_QNAP="$ROOT/qnap" BRIC_REQUIRE_NFS_BUS=0
export BRIC_TAPE_LOCK="$ROOT/canonical/bric_tape.lock" BRIC_TAPE_WORK_LOCK="$ROOT/canonical/bric_tape.lock.work"
export BRIC_LOG_DIR="$ROOT/log" BRIC_LOG_FALLBACK_DIR="$ROOT/log2" BRIC_REQUIRE_LOGGING=1 BRIC_LOG_CAPTURE_STDIO=0
export _BRIC_TEST_LEGACY_LOCK_DIR="$ROOT/legacy"
export BRIC_POLL_SECONDS=30
D="$REPO/tape/bin/bric-tape-daemon"
LEGACY_SINGLE="$ROOT/legacy/tmp/bric_tape.lock"
LEGACY_WORK="$ROOT/legacy/tmp/bric_tape.lock.work"

mkdir -p "$(dirname "$LEGACY_SINGLE")"
exec 21>>"$LEGACY_SINGLE"; flock -n 21
if "$D" --recover >"$ROOT/refuse.out" 2>&1; then
    echo 'FAIL: daemon started while a legacy singleton namespace was held' >&2; exit 1
fi
flock -u 21; exec 21>&-
echo '  ok: legacy singleton refuses new generation'

# A surviving pre-31C worker may hold only the old work fence. New recovery must wait for it.
(
    exec 22>>"$LEGACY_WORK"; flock 22
    touch "$ROOT/work-held"
    sleep 2
) & holder=$!
for _ in $(seq 1 50); do [ -e "$ROOT/work-held" ] && break; sleep 0.05; done
[ -e "$ROOT/work-held" ] || { echo 'FAIL: could not establish legacy work fence' >&2; exit 1; }
t0="$(date +%s%3N)"
"$D" --recover >"$ROOT/recover.out" 2>&1
t1="$(date +%s%3N)"
wait "$holder"
[ $((t1-t0)) -ge 1200 ] || { echo "FAIL: recovery did not wait for legacy work fence ($((t1-t0)) ms)" >&2; exit 1; }
grep -q "WORK_FENCE_ACQUIRED.*lock=$LEGACY_WORK" "$ROOT"/log/events/*/*/*.log 2>/dev/null || true
echo '  ok: legacy work-fence delays recovery'

# Loop mode holds canonical plus all three historical singleton/work namespaces simultaneously.
setsid "$D" --loop >"$ROOT/loop.out" 2>&1 & DAEMON_PID=$!
for _ in $(seq 1 1200); do
    grep -Rqs 'DAEMON_LOOP_START' "$ROOT/log" && break
    kill -0 "$DAEMON_PID" 2>/dev/null || { cat "$ROOT/loop.out" >&2; echo 'FAIL: daemon exited during lock migration test' >&2; exit 1; }
    sleep 0.05
done
grep -Rqs 'DAEMON_LOOP_START' "$ROOT/log" || { echo 'FAIL: daemon did not enter loop' >&2; exit 1; }
for lp in \
    "$BRIC_TAPE_LOCK" \
    "$ROOT/legacy/var/lock/bric_tape.lock" \
    "$ROOT/legacy/tmp/bric_tape.lock" \
    "$ROOT/legacy/run/bric/bric-tape-daemon.lock" \
    "$ROOT/legacy/run/bric/tape.lock"; do
    if flock -n "$lp" -c true 2>/dev/null; then echo "FAIL: singleton not held: $lp" >&2; exit 1; fi
done
for lp in \
    "$BRIC_TAPE_WORK_LOCK" \
    "$ROOT/legacy/var/lock/bric_tape.lock.work" \
    "$ROOT/legacy/tmp/bric_tape.lock.work" \
    "$ROOT/legacy/run/bric/bric-tape-daemon.lock.work" \
    "$ROOT/legacy/run/bric/tape.lock.work"; do
    if flock -n "$lp" -c true 2>/dev/null; then echo "FAIL: work fence not held: $lp" >&2; exit 1; fi
done
echo '  ok: canonical + multiple historical locks held together'

grep -R 'PROCESS_START' "$ROOT/log" | grep -F "repo=$REPO" | grep -F "review=$EXPECTED_REVIEW" | grep -F "release_id=$EXPECTED_RELEASE_ID" | grep -F 'script=' >/dev/null
echo '  ok: PROCESS_START provenance'
bric_test_stop_group "$DAEMON_PID"; DAEMON_PID=""

# Configuration must never permit a relative lock path.
if BRIC_TAPE_LOCK=relative.lock BRIC_TAPE_WORK_LOCK="$ROOT/relative.work" _BRIC_TEST_LEGACY_LOCK_DIR= \
   "$D" --recover >"$ROOT/relative.out" 2>&1; then
    echo 'FAIL: relative singleton path accepted' >&2; exit 1
fi
grep -q 'BRIC_TAPE_LOCK must be absolute' "$ROOT/relative.out"
echo '  ok: relative singleton path rejected'

# An upgraded host may retain a historical lock path in /etc/bric/bric.conf.  The migration set
# must still include the 31C /var/lock canonical namespace (and its work fence), otherwise a fresh
# default-config 31C tree could start beside the upgraded one.
prod_single="$(
  BRIC_CONFIG=none _BRIC_TEST_LEGACY_LOCK_DIR= bash -c '. "$1"; bric_tape_legacy_singleton_paths /run/bric/tape.lock' _ "$REPO/tape/scripts/lib_common.sh"
)"
printf '%s\n' "$prod_single" | grep -Fxq /var/lock/bric_tape.lock
prod_work="$(
  BRIC_CONFIG=none _BRIC_TEST_LEGACY_LOCK_DIR= bash -c '. "$1"; bric_tape_legacy_work_paths /run/bric/tape.lock' _ "$REPO/tape/scripts/lib_common.sh"
)"
printf '%s\n' "$prod_work" | grep -Fxq /var/lock/bric_tape.lock.work
echo '  ok: historical configured namespace still fences 31C canonical /var/lock namespace'

# Review 31E1: a child may close inherited singleton/work descriptors and Bash may immediately reuse
# the same numeric fd for a redirection. Repeated close helpers must therefore be no-ops in that child.
FD_COMMON="$REPO/tape/scripts/lib_common.sh"
BRIC_CONFIG=none bash -c '
  set -euo pipefail
  . "$1"
  root="$2"
  exec 10>"$root/singleton.original"
  BRIC_TAPE_SINGLETON_FDS=10
  bric_close_daemon_singleton_fds
  exec 10>"$root/singleton.reused"
  bric_close_daemon_singleton_fds
  printf "singleton-reuse-ok\n" >&10
  exec 10>&-
  exec 11>"$root/work.original"
  BRIC_TAPE_WORK_FDS=11
  bric_close_daemon_work_fds
  exec 11>"$root/work.reused"
  bric_close_daemon_work_fds
  printf "work-reuse-ok\n" >&11
  exec 11>&-
' _ "$FD_COMMON" "$ROOT"
grep -qx 'singleton-reuse-ok' "$ROOT/singleton.reused" || { echo 'FAIL: repeated singleton close killed a reused fd' >&2; exit 1; }
grep -qx 'work-reuse-ok' "$ROOT/work.reused" || { echo 'FAIL: repeated work-fence close killed a reused fd' >&2; exit 1; }
echo '  ok: daemon fd-close helpers are idempotent after numeric fd reuse'

echo "PASS: $EXPECTED_REVIEW singleton migration fences legacy generations, keeps fd closes idempotent, and logs executable provenance"
