#!/bin/bash
# Regression coverage for producer flow-control races with the tape daemon.
# The tape side legitimately removes chunk_*.enc while producers count staged bytes/files.
set -euo pipefail
REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/q/archive/p/r" "$T/state/r" "$T/fakebin"
printf 1024 > "$T/state/r/reserved_capacity"
sqlite3 "$T/catalog.db" <<'SQL'
CREATE TABLE config(key TEXT PRIMARY KEY,value TEXT);
CREATE TABLE runs(run_id TEXT PRIMARY KEY,project_name TEXT);
INSERT INTO config VALUES('max_inflight_chunks','1');
INSERT INTO config VALUES('qnap_budget_bytes','0');
INSERT INTO runs VALUES('r','p');
SQL

# 1) Per-run staged-file counting must not use find(1).  Make any find invocation fatal and let the
# daemon-equivalent remover free the single window slot while the gate is waiting.
printf x > "$T/q/archive/p/r/chunk_0001.enc"
cat > "$T/fakebin/find" <<'EOF_FIND_LOCAL'
#!/bin/sh
exit 71
EOF_FIND_LOCAL
chmod +x "$T/fakebin/find"
( sleep 2; rm -f "$T/q/archive/p/r/chunk_0001.enc" ) &
env PATH="$T/fakebin:$PATH" BRIC_DB="$T/catalog.db" BRIC_QNAP="$T/q" BRIC_RUNSTATE="$T/state" BRIC_POLL=1 \
  timeout 10 "$REPO/cluster/scripts/bric-stream-gate.sh" --run r --required-total 1 >/dev/null
printf '✓ per-run stream window tolerates concurrent chunk deletion without find/pipefail abort\n'

# 2) The global QNAP byte budget still needs recursive find, but GNU find must be told that entries
# disappearing between readdir/stat are an expected race.  This fake find refuses to succeed unless
# -ignore_readdir_race is present, then returns one staged byte.
sqlite3 "$T/catalog.db" "UPDATE config SET value='8' WHERE key='max_inflight_chunks'; UPDATE config SET value='1024' WHERE key='qnap_budget_bytes';"
cat > "$T/fakebin/find" <<'EOF_FIND_RACE'
#!/bin/sh
seen=0
for arg in "$@"; do
    [ "$arg" = "-ignore_readdir_race" ] && seen=1
done
[ "$seen" -eq 1 ] || exit 72
printf '1\n'
exit 0
EOF_FIND_RACE
chmod +x "$T/fakebin/find"
env PATH="$T/fakebin:$PATH" BRIC_DB="$T/catalog.db" BRIC_QNAP="$T/q" BRIC_RUNSTATE="$T/state" BRIC_POLL=1 \
  timeout 10 "$REPO/cluster/scripts/bric-stream-gate.sh" --run r --required-total 1 >/dev/null
printf '✓ global QNAP budget scan uses find -ignore_readdir_race\n'

# 3) A transient genuine find/NFS failure is UNKNOWN budget, not an immediate producer abort.
# The gate must stay fail-closed (no new staging), log the real find stderr, retry, and recover when
# the probe succeeds.  This fake find fails twice with an ESTALE-like diagnostic, then succeeds.
cat > "$T/fakebin/find" <<'EOF_FIND_TRANSIENT'
#!/bin/sh
state="${FAKE_FIND_STATE:?}"
n=0; [ ! -f "$state" ] || n="$(cat "$state")"
n=$((n+1)); printf '%s\n' "$n" > "$state"
if [ "$n" -lt 3 ]; then
    echo 'find: simulated NFS stale file handle' >&2
    exit 73
fi
printf '1\n'
exit 0
EOF_FIND_TRANSIENT
chmod +x "$T/fakebin/find"
rm -f "$T/find.state" "$T/transient.log"
env PATH="$T/fakebin:$PATH" FAKE_FIND_STATE="$T/find.state" \
  BRIC_DB="$T/catalog.db" BRIC_QNAP="$T/q" BRIC_RUNSTATE="$T/state" BRIC_POLL=1 \
  BRIC_QNAP_PROBE_MAX_FAILURES=4 \
  timeout 10 "$REPO/cluster/scripts/bric-stream-gate.sh" --run r --required-total 1 \
  >"$T/transient.log" 2>&1
grep -q 'simulated NFS stale file handle' "$T/transient.log"
grep -q 'QNAP budget probe failed (1/4 consecutive' "$T/transient.log"
grep -q 'QNAP budget probe unavailable (2/4 failures)' "$T/transient.log"
[ "$(cat "$T/find.state")" -eq 3 ]
printf '✓ transient global-budget probe failures pause and retry with stderr preserved\n'

# 4) Persistent genuine failures still abort after the configured consecutive-failure threshold.
# This preserves fail-closed safety without turning one NFS hiccup into an append-only tape abort.
cat > "$T/fakebin/find" <<'EOF_FIND_PERSISTENT'
#!/bin/sh
echo 'find: simulated persistent NFS I/O error' >&2
exit 74
EOF_FIND_PERSISTENT
chmod +x "$T/fakebin/find"
rm -f "$T/persistent.log"
if env PATH="$T/fakebin:$PATH" BRIC_DB="$T/catalog.db" BRIC_QNAP="$T/q" BRIC_RUNSTATE="$T/state" \
     BRIC_POLL=1 BRIC_QNAP_PROBE_MAX_FAILURES=3 \
     timeout 10 "$REPO/cluster/scripts/bric-stream-gate.sh" --run r --required-total 1 \
     >"$T/persistent.log" 2>&1; then
    echo 'FAIL: persistent global QNAP budget probe failure did not abort' >&2
    exit 1
fi
grep -q 'simulated persistent NFS I/O error' "$T/persistent.log"
grep -q 'QNAP budget probe failed 3 consecutive times' "$T/persistent.log"
printf '✓ persistent global-budget probe failure aborts only after configured threshold\n'

# 5) The legacy SLURM chunk producer has an independent sliding-window implementation.  Keep it on
# the same race-safe Bash-glob policy; do not reintroduce find|wc under pipefail there.
if grep -Eq 'staged=.*find .*chunk_.*\\.enc' "$REPO/cluster/scripts/bric-chunk.sh"; then
    echo 'FAIL: bric-chunk still counts staged blobs with find(1)' >&2
    exit 1
fi
grep -q '_staged_files=("$RUN_DIR"/chunk_\*.enc)' "$REPO/cluster/scripts/bric-chunk.sh"
grep -q 'if inflight="$(qnap_inflight_bytes)"; then' "$REPO/cluster/scripts/bric-chunk.sh"
grep -q 'QNAP budget probe failed' "$REPO/cluster/scripts/bric-chunk.sh"
printf '✓ legacy bric-chunk uses the same race-safe, bounded-retry budget policy\n' 
