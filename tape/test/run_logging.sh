#!/bin/bash
# Durable logging acceptance: primary/fallback selection, stdout API preservation, stderr capture,
# runtime failover and stable BRICLOGv1 schema. No sqlite or tape hardware required.
set -euo pipefail
export BRIC_CONFIG=none
REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
ROOT="$(mktemp -d)"
trap '[ -n "${KEEP:-}" ] && echo KEPT_ROOT=$ROOT || rm -rf "$ROOT"' EXIT
fail(){ echo "FAIL: $*" >&2; exit 1; }

cat >"$ROOT/fallback_child.sh" <<'CHILD'
#!/bin/bash
set -euo pipefail
. "$BRIC_LIB"
bric_log_process_start logging-fallback api-test
printf 'RUN-API-123\n'
printf 'hardware diagnostic sentinel\n' >&2
BRIC_LOG_RUN_ID=run-log-1 BRIC_LOG_PROJECT=project-log BRIC_LOG_CHUNK=7 \
  BRIC_LOG_COPY_ROLE=BACKUP BRIC_LOG_DRIVE=1 BRIC_LOG_VOLUMETAG=LOG002L9 \
  BRIC_LOG_ATTEMPT=2 BRIC_LOG_RC=5 BRIC_LOG_DURATION_MS=1234 BRIC_LOG_BYTES=4096 \
  bric_event ERROR DRIVE_TEST_FAILURE $'first line|second line'
exit 7
CHILD
chmod +x "$ROOT/fallback_child.sh"

# Primary cannot exist under /proc, so the process must use the configured NFS-style fallback.
set +e
OUT="$(BRIC_LIB="$REPO/cluster/scripts/lib_common.sh" \
  BRIC_ROLE=slurm BRIC_HOME="$ROOT/home" BRIC_LOG_DIR=/proc/bric-denied \
  BRIC_LOG_FALLBACK_DIR="$ROOT/nfs-fallback" BRIC_LOG_CAPTURE_STDIO=1 \
  "$ROOT/fallback_child.sh" 2>"$ROOT/caller.err")"
RC=$?
set -e
[ "$RC" -eq 7 ] || fail "child rc changed by logger: expected 7 got $RC"
[ "$OUT" = RUN-API-123 ] || fail "stdout API changed/contaminated: '$OUT'"
grep -q 'hardware diagnostic sentinel' "$ROOT/caller.err" || fail "stderr was not preserved to caller"
sleep 0.2
EV="$(find "$ROOT/nfs-fallback/events" -type f -name '*.events.v1.log' | head -1)"
[ -n "$EV" ] || fail "no structured fallback event log"
grep -q '|PROCESS_START|' "$EV" || fail "PROCESS_START missing"
grep -q '|DRIVE_TEST_FAILURE|' "$EV" || fail "hardware failure event missing"
grep -q '|PROCESS_END|' "$EV" || fail "PROCESS_END missing"
grep -q '|run-log-1|project-log|7|BACKUP|1|LOG002L9|2|5|1234|4096|' "$EV" || fail "structured context fields missing"
grep -q 'first line second line' "$EV" || fail "message was not newline/pipe sanitized"
awk -F'|' 'NF != 23 { bad=1 } END { exit bad }' "$EV" || fail "BRICLOGv1 record does not have 23 fields"
RAWOUT="$(find "$ROOT/nfs-fallback/processes" -type f -name '*.stdout.log' | head -1)"
RAWERR="$(find "$ROOT/nfs-fallback/processes" -type f -name '*.stderr.log' | head -1)"
grep -qx 'RUN-API-123' "$RAWOUT" || fail "raw stdout copy missing"
grep -q 'hardware diagnostic sentinel' "$RAWERR" || fail "raw stderr copy missing"
[ "$(stat -c %a "$EV")" = 640 ] || fail "event log permissions are not 0640"
[ "$(stat -c %a "$RAWOUT")" = 640 ] || fail "raw stdout permissions are not 0640"

# Exhaustive mode is fail-closed: no archive process may start when neither destination is writable.
set +e
BRIC_LIB="$REPO/cluster/scripts/lib_common.sh" BRIC_ROLE=slurm BRIC_HOME="$ROOT/home"   BRIC_LOG_DIR=/proc/bric-primary-denied BRIC_LOG_FALLBACK_DIR=/proc/bric-fallback-denied   BRIC_REQUIRE_LOGGING=1 BRIC_LOG_CAPTURE_STDIO=1 "$ROOT/fallback_child.sh"   >"$ROOT/unlogged.out" 2>"$ROOT/unlogged.err"
UNLOGGED_RC=$?
set -e
[ "$UNLOGGED_RC" -eq 70 ] || fail "unlogged process was not refused with rc=70 (got $UNLOGGED_RC)"
[ ! -s "$ROOT/unlogged.out" ] || fail "unlogged child executed its payload"
grep -q 'refusing to start unlogged component' "$ROOT/unlogged.err" || fail "missing fail-closed diagnostic"

# Prove live failover: primary works at startup, then becomes a plain file while the process runs.
cat >"$ROOT/runtime_child.sh" <<'CHILD'
#!/bin/bash
set -euo pipefail
. "$BRIC_LIB"
bric_log_process_start logging-runtime-failover
printf 'before-failover\n'
bric_event INFO RUNTIME_BEFORE 'primary still writable'
touch "$SYNC/ready"
while [ ! -e "$SYNC/continue" ]; do sleep 0.05; done
printf 'after-failover\n'
printf 'stderr-after-failover\n' >&2
bric_event WARN RUNTIME_AFTER 'primary disappeared; event must be on NFS fallback'
CHILD
chmod +x "$ROOT/runtime_child.sh"
mkdir -p "$ROOT/primary" "$ROOT/runtime-fallback" "$ROOT/sync"
BRIC_LIB="$REPO/cluster/scripts/lib_common.sh" BRIC_ROLE=slurm BRIC_HOME="$ROOT/home" \
  BRIC_LOG_DIR="$ROOT/primary" BRIC_LOG_FALLBACK_DIR="$ROOT/runtime-fallback" \
  BRIC_LOG_CAPTURE_STDIO=1 SYNC="$ROOT/sync" "$ROOT/runtime_child.sh" \
  >"$ROOT/runtime.out" 2>"$ROOT/runtime.err" & PID=$!
for _ in $(seq 1 100); do [ -e "$ROOT/sync/ready" ] && break; sleep 0.05; done
[ -e "$ROOT/sync/ready" ] || fail "runtime child did not start"
rm -rf "$ROOT/primary"; : >"$ROOT/primary"
touch "$ROOT/sync/continue"
wait "$PID" || fail "runtime failover changed process result"
sleep 0.2
grep -q '^before-failover$' "$ROOT/runtime.out" || fail "pre-failover stdout missing"
grep -q '^after-failover$' "$ROOT/runtime.out" || fail "post-failover stdout missing"
grep -q 'stderr-after-failover' "$ROOT/runtime.err" || fail "post-failover stderr missing"
REV="$(find "$ROOT/runtime-fallback/events" -type f -name '*.events.v1.log' | head -1)"
[ -n "$REV" ] || fail "runtime fallback structured log missing"
grep -Rqs '|RUNTIME_AFTER|' "$ROOT/runtime-fallback/events" || fail "post-failover event not written to fallback"
grep -Rqs '|PROCESS_END|' "$ROOT/runtime-fallback/events" || fail "process end missing after runtime failover"
grep -Rqs '|LOG_FAILOVER|' "$ROOT/runtime-fallback/events" || fail "runtime failover event missing"

# Hardware command diagnostics: preserve the original stderr, rc and duration in BRICLOGv1.
mkdir -p "$ROOT/fakebin" "$ROOT/hw-primary" "$ROOT/hw-fallback"
cat >"$ROOT/fakebin/mtx" <<'MTX'
#!/bin/bash
echo 'SCSI sense: hardware error ASC=44h' >&2
exit 17
MTX
chmod +x "$ROOT/fakebin/mtx"
cat >"$ROOT/hw_child.sh" <<'CHILD'
#!/bin/bash
set -euo pipefail
. "$TAPE_COMMON"
. "$TAPE_IO"
bric_log_process_start logging-hardware-status
_status
CHILD
chmod +x "$ROOT/hw_child.sh"
set +e
PATH="$ROOT/fakebin:$PATH" TAPE_COMMON="$REPO/tape/scripts/lib_common.sh"   TAPE_IO="$REPO/tape/scripts/lib_tape_io.sh" BRIC_ROLE=tape BRIC_TAPE_HOME="$ROOT/tape"   BRIC_QNAP="$ROOT/qnap" BRIC_LOG_DIR="$ROOT/hw-primary"   BRIC_LOG_FALLBACK_DIR="$ROOT/hw-fallback" BRIC_DRIVE_STATUS_TIMEOUT=2   BRIC_CHANGER="$ROOT/fake-changer" "$ROOT/hw_child.sh"   >"$ROOT/hw.out" 2>"$ROOT/hw.err"
HWRC=$?
set -e
[ "$HWRC" -ne 0 ] || fail "failing changer status unexpectedly succeeded"
grep -q 'SCSI sense: hardware error ASC=44h' "$ROOT/hw.err" || fail "original changer stderr not re-emitted"
HEV="$(find "$ROOT/hw-primary/events" -type f -name '*.events.v1.log' | head -1)"
grep -q '|CHANGER_STATUS_FAILED|' "$HEV" || fail "changer status failure event missing"
grep -q '|17|' "$HEV" || fail "actual mtx rc=17 was not preserved"
grep -q 'SCSI sense: hardware error ASC=44h' "$HEV" || fail "original changer diagnostic missing from structured log"

find "$ROOT/runtime-fallback/processes" -type f -name '*.stdout.log' -exec grep -q 'after-failover' {} \; \
  || fail "post-failover raw stdout missing from fallback"
find "$ROOT/runtime-fallback/processes" -type f -name '*.stderr.log' -exec grep -q 'stderr-after-failover' {} \; \
  || fail "post-failover raw stderr missing from fallback"

echo "  ok: stdout/stderr preserved; hardware rc/stderr captured; primary->NFS failover durable"
echo "PASS run_logging"
