#!/bin/bash
. "$(cd "$(dirname "$(readlink -f "$0")")" && pwd)/lib_test_daemon.sh"
# Notifications: every user-visible lifecycle event must (1) append a structured line to the
# root-readable event log and (2) best-effort email <owner>@ku.dk — and a BROKEN mailer must never
# affect the operation itself.
#   A) backup e2e            -> BACKUP_START + BACKUP_DONE, both logged and both mailed to owner@ku.dk
#   B) reservation denied    -> BACKUP_DENIED with the daemon's reason
#   C) quiescence failure    -> CHUNK_ERROR + BACKUP_FAILED
#   D) restore e2e           -> RESTORE_START + RESTORE_DONE
#   E) restore that dies     -> RESTORE_FAILED (via the EXIT trap)
#   F) mailer exits 1        -> operation still succeeds; log line says mail=failed
#   G) no mailer in PATH     -> operation still succeeds; log line says mail=skipped
set -uo pipefail
export BRIC_CONFIG=none   # hermetic: never read /etc/bric/bric.conf inside tests
REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
ROOT="$(mktemp -d)"
echo "workroot=$ROOT"
fail=0; ok() { echo "  ok: $*"; }; bad() { echo "  FAIL: $*"; fail=1; }

export BRIC_HOME="$REPO/cluster" BRIC_DB="$ROOT/c.db" BRIC_QNAP="$ROOT/qnap/bric"
export BRIC_KEYS="$ROOT/keys" BRIC_SQL_INIT="$REPO/cluster/sql/cluster_init.sql"
export BRIC_USER="vsz652" BRIC_RUN_MODE="local"
export BRIC_RESERVE_TIMEOUT=40 BRIC_DRAIN_TIMEOUT=60 BRIC_CLOSE_TIMEOUT=60 BRIC_POLL=1 BRIC_RESTORE_TIMEOUT=40
export BRIC_TAPE_HOME="$REPO/tape" BRIC_TAPE_DB="$ROOT/t.db" BRIC_TAPE_SQL_INIT="$REPO/tape/sql/tape_init.sql"
export BRIC_TAPE_BACKEND="sim" BRIC_TAPELIB="$ROOT/tapelib" BRIC_TAPE_LOCK="$ROOT/tape.lock"
export BRIC_NOTIFY_LOG="$ROOT/events.log" BRIC_MAIL_DOMAIN="ku.dk" BRIC_NOTIFY_MAIL=auto

# mock mailer: records To/Subject into a mailbox file
MOCK="$ROOT/mockbin"; mkdir -p "$MOCK"; export PATH="$MOCK:$PATH"
MAILBOX="$ROOT/mailbox"; : > "$MAILBOX"; export MAILBOX
cat > "$MOCK/mail" <<'M'
#!/bin/bash
# mail -s SUBJECT TO   (body on stdin)
[ -f "$MAILBOX.broken" ] && exit 1
subj=""; to=""
while [ $# -gt 0 ]; do case "$1" in -s) subj="$2"; shift 2;; *) to="$1"; shift;; esac; done
printf 'TO=%s SUBJ=%s\n' "$to" "$subj" >> "$MAILBOX"
cat >/dev/null
M
chmod +x "$MOCK/mail" 2>/dev/null || true

mkdir -p "$BRIC_QNAP" "$BRIC_KEYS" "$BRIC_TAPELIB"
chmod +x "$REPO"/cluster/scripts/*.sh "$REPO"/cluster/bin/bric "$REPO"/tape/bin/bric-tape-daemon 2>/dev/null || true
sqlite3 "$BRIC_DB" < "$BRIC_SQL_INIT" >/dev/null
sqlite3 "$BRIC_TAPE_DB" < "$BRIC_TAPE_SQL_INIT" >/dev/null
sqlite3 "$BRIC_DB" "UPDATE config SET value='4194304' WHERE key='segment_target_bytes';"
sqlite3 "$BRIC_TAPE_DB" "UPDATE config SET value='1' WHERE key='poll_seconds';"
head -c 32 /dev/urandom | base64 > "$BRIC_KEYS/${BRIC_USER}_user_key.txt"
head -c 32 /dev/urandom | base64 > "$BRIC_KEYS/master.key"
sqlite3 "$BRIC_TAPE_DB" "INSERT INTO tapes(volumetag,slot,role,pair_number,paired_volumetag,capacity_tb,used_tb,status)
  VALUES('000000L9',1,'PRIMARY',1,'000001L9',18,0,'EMPTY'),('000001L9',2,'BACKUP',1,'000000L9',18,0,'EMPTY'),
        ('000002L9',3,'PRIMARY',2,'000003L9',18,0,'EMPTY'),('000003L9',4,'BACKUP',2,'000002L9',18,0,'EMPTY');"

setsid "$REPO/tape/bin/bric-tape-daemon" --loop >"$ROOT/daemon.log" 2>&1 & DAEMON=$!
trap 'bric_test_stop_group "$DAEMON"; [ -n "${KEEP:-}" ] || { rm -rf "$ROOT" 2>/dev/null || { sleep 1; rm -rf "$ROOT"; }; }' EXIT
sleep 1

evt() { grep -c "|$1|" "$BRIC_NOTIFY_LOG" 2>/dev/null || true; }

echo "=== A) backup e2e: START + DONE, logged and mailed ==="
SRC="$ROOT/data/np"; mkdir -p "$SRC"; dd if=/dev/urandom of="$SRC/a.dat" bs=1M count=2 status=none
RUN="$("$REPO/cluster/bin/bric" backup --project np --source "$SRC")" || bad "backup failed"
[ "$(evt BACKUP_START)" = 1 ] && ok "BACKUP_START logged once" || bad "BACKUP_START count=$(evt BACKUP_START)"
[ "$(evt BACKUP_DONE)"  = 1 ] && ok "BACKUP_DONE logged once"  || bad "BACKUP_DONE count=$(evt BACKUP_DONE)"
grep -q "TO=vsz652@ku.dk SUBJ=\[BRIC Archive\] BACKUP_START $RUN" "$MAILBOX" && ok "START mail to vsz652@ku.dk" || bad "START mail missing"
grep -q "TO=vsz652@ku.dk SUBJ=\[BRIC Archive\] BACKUP_DONE $RUN"  "$MAILBOX" && ok "DONE mail to vsz652@ku.dk"  || bad "DONE mail missing"
grep "|BACKUP_START|" "$BRIC_NOTIFY_LOG" | grep -q "mail=sent" && ok "log line records mail=sent" || bad "mail outcome not in log line"

echo "=== B) reservation denied -> BACKUP_DENIED ==="
sqlite3 "$BRIC_TAPE_DB" "UPDATE tapes SET status='RETIRED' WHERE status='EMPTY';"   # nothing reservable for a NEW project
"$REPO/cluster/bin/bric" backup --project np2 --source "$SRC" >/dev/null 2>&1 && bad "backup np2 should have been denied"
[ "$(evt BACKUP_DENIED)" = 1 ] && ok "BACKUP_DENIED logged" || bad "BACKUP_DENIED count=$(evt BACKUP_DENIED)"
grep "|BACKUP_DENIED|" "$BRIC_NOTIFY_LOG" | grep -q "pair" && ok "denial reason (capacity) carried in the event" || bad "denial reason missing"
grep -q "SUBJ=\[BRIC Archive\] BACKUP_DENIED" "$MAILBOX" && ok "DENIED mail sent" || bad "DENIED mail missing"
sqlite3 "$BRIC_TAPE_DB" "UPDATE tapes SET status='EMPTY' WHERE status='RETIRED';"

echo "=== C) quiescence failure -> CHUNK_ERROR + BACKUP_FAILED ==="
SRCQ="$ROOT/data/npq"; mkdir -p "$SRCQ"; dd if=/dev/urandom of="$SRCQ/m.dat" bs=1M count=1 status=none
RUNQ="$("$REPO/cluster/scripts/bric-plan.sh" --project npq --source "$SRCQ" 2>/dev/null)" || bad "plan npq failed"
sleep 1.1; echo drift >> "$SRCQ/m.dat"
for c in $(seq 1 "$(sqlite3 "$BRIC_DB" "SELECT n_chunks FROM runs WHERE run_id='$RUNQ';")"); do
    "$REPO/cluster/scripts/bric-chunk.sh" --run "$RUNQ" --chunk "$c" >/dev/null 2>&1 || true
done
"$REPO/cluster/scripts/bric-finalize.sh" --run "$RUNQ" >/dev/null 2>&1 || true
[ "$(evt CHUNK_ERROR)" -ge 1 ] && ok "CHUNK_ERROR logged (quiescence violation)" || bad "CHUNK_ERROR missing"
[ "$(evt BACKUP_FAILED)" -ge 1 ] && ok "BACKUP_FAILED logged" || bad "BACKUP_FAILED missing"
grep -q "SUBJ=\[BRIC Archive\] BACKUP_FAILED $RUNQ" "$MAILBOX" && ok "FAILED mail sent" || bad "FAILED mail missing"

echo "=== D) restore e2e -> RESTORE_START + RESTORE_DONE ==="
"$REPO/cluster/scripts/bric-restore.sh" --project np --dest "$ROOT/rest" >/dev/null 2>&1 || bad "restore failed"
[ "$(evt RESTORE_START)" = 1 ] && ok "RESTORE_START logged" || bad "RESTORE_START count=$(evt RESTORE_START)"
[ "$(evt RESTORE_DONE)"  = 1 ] && ok "RESTORE_DONE logged"  || bad "RESTORE_DONE count=$(evt RESTORE_DONE)"
grep -q "SUBJ=\[BRIC Archive\] RESTORE_DONE $RUN" "$MAILBOX" && ok "RESTORE_DONE mail sent" || bad "RESTORE_DONE mail missing"

echo "=== E) restore that dies -> RESTORE_FAILED via trap ==="
bric_test_stop_group "$DAEMON"   # no daemon: staging will time out
BRIC_RESTORE_TIMEOUT=3 "$REPO/cluster/scripts/bric-restore.sh" --project np --dest "$ROOT/rest2" >/dev/null 2>&1 && bad "restore should have failed"
[ "$(evt RESTORE_FAILED)" -ge 1 ] && ok "RESTORE_FAILED logged (EXIT trap fired on die)" || bad "RESTORE_FAILED missing"
grep -q "SUBJ=\[BRIC Archive\] RESTORE_FAILED" "$MAILBOX" && ok "RESTORE_FAILED mail sent" || bad "RESTORE_FAILED mail missing"
setsid "$REPO/tape/bin/bric-tape-daemon" --loop >>"$ROOT/daemon.log" 2>&1 & DAEMON=$!
sleep 1

echo "=== F) broken mailer must not break the operation ==="
touch "$MAILBOX.broken"
"$REPO/cluster/scripts/bric-restore.sh" --project np --dest "$ROOT/rest3" >/dev/null 2>&1 && ok "restore succeeded with a failing mailer" || bad "operation broken by the mailer"
grep "|RESTORE_DONE|" "$BRIC_NOTIFY_LOG" | tail -1 | grep -q "mail=failed" && ok "log line records mail=failed" || bad "mail=failed not recorded"
rm -f "$MAILBOX.broken"

echo "=== G) no mailer available: mail=skipped, notify still logs (hermetic unit test) ==="
# Removing the mock would expose a REAL mailer on production-like hosts (mailx/sendmail on
# brictape) — both failing the assertion and risking real deliveries. Instead: call bric_notify
# directly under a MINIMAL PATH containing only what the function itself needs, so no mailer of
# any kind is findable, on any machine.
MINP="$ROOT/minpath"; mkdir -p "$MINP"
for b in bash tr head date hostname mkdir dirname; do ln -sf "$(command -v $b)" "$MINP/$b" 2>/dev/null; done
G_LOG="$ROOT/g_events.log"
( PATH="$MINP" BRIC_CONFIG=none BRIC_NOTIFY_MAIL=auto BRIC_NOTIFY_LOG="$G_LOG" \
  bash -c ". '$REPO/cluster/scripts/lib_common.sh' 2>/dev/null; bric_notify G_TEST vsz652 g_run 'no mailer reachable'" ) 2>/dev/null
grep -q "|G_TEST|.*|mail=skipped" "$G_LOG" 2>/dev/null \
    && ok "no mailer in PATH -> event logged with mail=skipped, no failure" \
    || bad "skipped-outcome not recorded: $(tail -1 "$G_LOG" 2>/dev/null)"
"$REPO/cluster/scripts/bric-restore.sh" --project np --dest "$ROOT/rest4" >/dev/null 2>&1 && ok "pipeline unaffected (restore still succeeds)" || bad "operation broken"
echo "=== H) UNWRITABLE notify-log path must never break an operation (production bug regression) ==="
# Root-agnostic repro of the brictape incident: as a non-root user, mkdir -p /var/log/bric fails
# and an unarmored line inside bric_notify killed every `set -e` caller right after
# "reservation GRANTED". /proc is unwritable even for root, so this reproduces for everyone.
# The daemon restarted after test E is already running. Reuse it here; starting a second loop against
# the same catalog would make teardown ambiguous and can leave an orphan process after the test.
SRCH="$ROOT/data/nph"; mkdir -p "$SRCH"; dd if=/dev/urandom of="$SRCH/h.dat" bs=1M count=1 status=none
if RUNH="$(BRIC_NOTIFY_LOG=/proc/nonexistent/events.log BRIC_HOME=/proc/nx2 \
        "$REPO/cluster/bin/bric" backup --project np --source "$SRCH" 2>>"$ROOT/h.log")"; then
    [ "$(sqlite3 "$BRIC_DB" "SELECT status FROM runs WHERE run_id='$RUNH';")" = CLOSED ] \
        && ok "backup reached CLOSED with every preferred log path unwritable (fell back to /tmp)" \
        || bad "backup survived but did not close"
else
    bad "backup DIED with unwritable notify-log path (the production bug is back): $(tail -1 "$ROOT/h.log")"
fi
echo "=== log format sanity (for the root cron digest) ==="
awk -F'|' 'NF!=7 {bad=1} END {exit bad}' "$BRIC_NOTIFY_LOG" && ok "every event line has exactly 7 pipe-separated fields" || bad "malformed event line(s): $(awk -F'|' 'NF!=7' "$BRIC_NOTIFY_LOG" | head -2)"

echo
[ "$fail" -eq 0 ] && echo "✓ NOTIFICATION CHECKS PASSED" || { echo "✗ NOTIFICATION FAILURES"; exit 1; }
