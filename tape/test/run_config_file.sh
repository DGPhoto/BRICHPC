#!/bin/bash
. "$(cd "$(dirname "$(readlink -f "$0")")" && pwd)/lib_test_daemon.sh"
# Central config file (bric.conf):
#   A) values from the file apply when the environment does not set them (both cluster AND tape lib)
#   B) THE ENVIRONMENT WINS over the file
#   C) parser safety: non-BRIC keys, malformed keys, code-injection attempts and BRIC_FAULT_* lines
#      are all ignored — the file can never execute code or persist fault injection
#   D) BRIC_CONFIG=none disables loading entirely (suite hermeticity)
#   E) an end-to-end backup driven purely by file-provided notification settings produces the
#      expected event log at the file-configured path
set -uo pipefail
export BRIC_CONFIG=none   # hermetic: never read /etc/bric/bric.conf inside tests
REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
ROOT="$(mktemp -d)"
CONFIG_JOURNAL_BASE="${BRIC_RESTORE_JOURNAL_ROOT:-$ROOT/journal-base}"; mkdir -p "$CONFIG_JOURNAL_BASE"; chmod 1777 "$CONFIG_JOURNAL_BASE"; export BRIC_RESTORE_JOURNAL_ROOT="$CONFIG_JOURNAL_BASE"
echo "workroot=$ROOT"
fail=0; ok() { echo "  ok: $*"; }; bad() { echo "  FAIL: $*"; fail=1; }
trap '[ -n "${KEEP:-}" ] || { rm -rf "$ROOT" 2>/dev/null || { sleep 1; rm -rf "$ROOT"; }; }' EXIT

CFG="$ROOT/bric.conf"
cat > "$CFG" <<EOF
# test config
BRIC_MAIL_DOMAIN=example.org
BRIC_QNAP=/tmp/qnap_from_file
BRIC_POLL="9"
BRIC_TAPE_BLOCK='131072'
BRIC_NOTIFY_LOG=$ROOT/from_file_events.log
BRIC_FAULT_DIE_BETWEEN_COPIES=1
BRIC_FAULT_CLOSE_AFTER=1
PATH=/evil
LD_PRELOAD=/evil.so
BRIC_BAD KEY=x
BRIC_lower=x
BRIC_INJECT=\$(touch $ROOT/pwned)
EOF

echo "=== A) file applies where env is silent — cluster lib ==="
out="$(env -i BRIC_RESTORE_JOURNAL_ROOT="$BRIC_RESTORE_JOURNAL_ROOT" HOME="$HOME" PATH="$PATH" BRIC_CONFIG="$CFG" bash -c '
  . '"$REPO"'/cluster/scripts/lib_common.sh 2>/dev/null
  printf "%s|%s|%s|%s\n" "$BRIC_MAIL_DOMAIN" "$BRIC_POLL" "$BRIC_TAPE_BLOCK" "$BRIC_QNAP"')"
[ "$out" = "example.org|9|131072|/tmp/qnap_from_file" ] && ok "cluster lib loaded file values, INCLUDING a site-defaulted variable (env > file > defaults)" || bad "cluster lib got: $out"

echo "=== A2) same file, tape lib ==="
out="$(env -i BRIC_RESTORE_JOURNAL_ROOT="$BRIC_RESTORE_JOURNAL_ROOT" HOME="$HOME" PATH="$PATH" BRIC_CONFIG="$CFG" bash -c '
  . '"$REPO"'/tape/scripts/lib_common.sh 2>/dev/null
  printf "%s|%s\n" "$BRIC_MAIL_DOMAIN" "$BRIC_TAPE_BLOCK"')"
[ "$out" = "example.org|131072" ] && ok "tape lib loaded the same file (lockstep loader works)" || bad "tape lib got: $out"

echo "=== B) the environment wins ==="
out="$(env -i BRIC_RESTORE_JOURNAL_ROOT="$BRIC_RESTORE_JOURNAL_ROOT" HOME="$HOME" PATH="$PATH" BRIC_CONFIG="$CFG" BRIC_MAIL_DOMAIN=ku.dk BRIC_POLL=1 bash -c '
  . '"$REPO"'/cluster/scripts/lib_common.sh 2>/dev/null
  printf "%s|%s\n" "$BRIC_MAIL_DOMAIN" "$BRIC_POLL"')"
[ "$out" = "ku.dk|1" ] && ok "explicit env overrode the file ($out)" || bad "precedence broken: $out"

echo "=== C) parser safety ==="
out="$(env -i BRIC_RESTORE_JOURNAL_ROOT="$BRIC_RESTORE_JOURNAL_ROOT" HOME="$HOME" PATH="$PATH" BRIC_CONFIG="$CFG" bash -c '
  . '"$REPO"'/cluster/scripts/lib_common.sh 2>/dev/null
  printf "%s|%s|%s|%s\n" "${BRIC_FAULT_DIE_BETWEEN_COPIES:-UNSET}" "${BRIC_FAULT_CLOSE_AFTER:-UNSET}" "${BRIC_INJECT:-SET_BUT_INERT}" "${LD_PRELOAD:-UNSET}"')"
case "$out" in
  UNSET\|UNSET\|*\|UNSET) ok "BRIC_FAULT_* refused; LD_PRELOAD/PATH ignored" ;;
  *) bad "parser let something through: $out" ;;
esac
[ ! -e "$ROOT/pwned" ] && ok "command substitution in a value did NOT execute (parsed, not sourced)" || bad "CODE EXECUTION from config value!"

echo "=== D) BRIC_CONFIG=none disables loading ==="
out="$(env -i BRIC_RESTORE_JOURNAL_ROOT="$BRIC_RESTORE_JOURNAL_ROOT" HOME="$HOME" PATH="$PATH" BRIC_CONFIG=none bash -c '
  . '"$REPO"'/cluster/scripts/lib_common.sh 2>/dev/null
  printf "%s\n" "${BRIC_MAIL_DOMAIN:-UNSET}"')"
[ "$out" = "UNSET" ] && ok "none-mode: nothing loaded" || bad "none-mode leaked: $out"

echo "=== E) e2e: notification log path taken from the FILE ==="
export BRIC_HOME="$REPO/cluster" BRIC_DB="$ROOT/c.db" BRIC_QNAP="$ROOT/qnap/bric"
export BRIC_KEYS="$ROOT/keys" BRIC_SQL_INIT="$REPO/cluster/sql/cluster_init.sql"
export BRIC_USER="vsz652" BRIC_RUN_MODE="local"
export BRIC_RESERVE_TIMEOUT=40 BRIC_DRAIN_TIMEOUT=60 BRIC_CLOSE_TIMEOUT=60 BRIC_POLL=1
export BRIC_TAPE_HOME="$REPO/tape" BRIC_TAPE_DB="$ROOT/t.db" BRIC_TAPE_SQL_INIT="$REPO/tape/sql/tape_init.sql"
export BRIC_TAPE_BACKEND="sim" BRIC_TAPELIB="$ROOT/tapelib" BRIC_TAPE_LOCK="$ROOT/tape.lock"
export BRIC_CONFIG="$ROOT/e2e.conf"
cat > "$BRIC_CONFIG" <<EOF
BRIC_NOTIFY_LOG=$ROOT/e2e_events.log
BRIC_NOTIFY_MAIL=off
EOF
mkdir -p "$BRIC_QNAP" "$BRIC_KEYS" "$BRIC_TAPELIB"
chmod +x "$REPO"/cluster/scripts/*.sh "$REPO"/cluster/bin/bric "$REPO"/tape/bin/bric-tape-daemon 2>/dev/null || true
sqlite3 "$BRIC_DB" < "$BRIC_SQL_INIT" >/dev/null
sqlite3 "$BRIC_TAPE_DB" < "$BRIC_TAPE_SQL_INIT" >/dev/null
sqlite3 "$BRIC_DB" "UPDATE config SET value='4194304' WHERE key='segment_target_bytes';"
sqlite3 "$BRIC_TAPE_DB" "UPDATE config SET value='1' WHERE key='poll_seconds';"
head -c 32 /dev/urandom | base64 > "$BRIC_KEYS/${BRIC_USER}_user_key.txt"
head -c 32 /dev/urandom | base64 > "$BRIC_KEYS/master.key"
sqlite3 "$BRIC_TAPE_DB" "INSERT INTO tapes(volumetag,slot,role,pair_number,paired_volumetag,capacity_tb,used_tb,status)
  VALUES('000000L9',1,'PRIMARY',1,'000001L9',18,0,'EMPTY'),('000001L9',2,'BACKUP',1,'000000L9',18,0,'EMPTY');"
setsid "$REPO/tape/bin/bric-tape-daemon" --loop >"$ROOT/daemon.log" 2>&1 & DAEMON=$!
trap 'bric_test_stop_group "$DAEMON"; [ -n "${KEEP:-}" ] || { rm -rf "$ROOT" 2>/dev/null || { sleep 1; rm -rf "$ROOT"; }; }' EXIT
sleep 1
SRC="$ROOT/data/cfg"; mkdir -p "$SRC"; dd if=/dev/urandom of="$SRC/a.dat" bs=1M count=2 status=none
"$REPO/cluster/bin/bric" backup --project cfg --source "$SRC" >/dev/null || bad "backup failed"
grep -q "|BACKUP_DONE|" "$ROOT/e2e_events.log" 2>/dev/null \
    && ok "event log written at the FILE-configured path ($ROOT/e2e_events.log)" \
    || bad "event log not at file-configured path"

echo "=== F) bric-setup reads the config file too (setup/runtime coherence) ==="
CFG2="$ROOT/setup.conf"
printf 'BRIC_QNAP=/tmp/distinctive_qnap_from_file\n' > "$CFG2"
out="$(env -i BRIC_RESTORE_JOURNAL_ROOT="$BRIC_RESTORE_JOURNAL_ROOT" HOME="$HOME" PATH="$PATH" BRIC_CONFIG="$CFG2" bash "$REPO/bric-setup.sh" --role cluster --dry-run 2>&1 || true)"
echo "$out" | grep -q "distinctive_qnap_from_file" \
    && ok "setup --dry-run reflects the config-file value (BRIC_QNAP)" \
    || bad "setup ignored the config file"
out="$(env -i BRIC_RESTORE_JOURNAL_ROOT="$BRIC_RESTORE_JOURNAL_ROOT" HOME="$HOME" PATH="$PATH" BRIC_CONFIG="$CFG2" BRIC_QNAP=/tmp/env_wins_here bash "$REPO/bric-setup.sh" --role cluster --dry-run 2>&1 || true)"
echo "$out" | grep -q "env_wins_here" && ! echo "$out" | grep -q "distinctive_qnap_from_file" \
    && ok "environment still overrides the file in setup" \
    || bad "setup precedence broken"

echo "=== G) duplicated defaults must never DIVERGE (lint) ==="
# bric-setup.sh declares a last-resort default layer for some paths that lib_common also defaults.
# Whichever runs first wins, so a divergence is SILENT: one of the two copies becomes unreachable
# and the operator edits a line that does nothing. Values may be duplicated (documented), but they
# must be IDENTICAL. This lint is the guard.
dump_defaults() {  # file -> "VAR<TAB>default"
    grep -oE '^: "\$\{BRIC_[A-Z0-9_]+:=[^}]*\}' "$1" 2>/dev/null \
      | sed -E 's/^: "\$\{([A-Z0-9_]+):=(.*)\}$/\1\t\2/'
}
dump_defaults "$REPO/cluster/scripts/lib_common.sh"  > "$ROOT/lint_lib.txt"
dump_defaults "$REPO/tape/scripts/lib_common.sh"    >> "$ROOT/lint_lib.txt"
dump_defaults "$REPO/bric-setup.sh"                  > "$ROOT/lint_setup.txt"
divergent=""; shared=0
while IFS="$(printf '\t')" read -r var def; do
    [ -n "$var" ] || continue
    libdef="$(awk -F'\t' -v v="$var" '$1==v {print $2; exit}' "$ROOT/lint_lib.txt")"
    [ -n "$libdef" ] || continue
    shared=$((shared+1))
    [ "$libdef" = "$def" ] || divergent="$divergent $var(lib='$libdef' setup='$def')"
done < "$ROOT/lint_setup.txt"
[ "$shared" -gt 0 ] && ok "lint ran over $shared duplicated default(s)" || bad "lint found nothing to compare — parser broken?"
[ -z "$divergent" ] && ok "no divergence between bric-setup and lib_common defaults" \
    || bad "DIVERGENT defaults (one copy is unreachable):$divergent"

echo
[ "$fail" -eq 0 ] && echo "✓ CONFIG FILE CHECKS PASSED" || { echo "✗ CONFIG FILE FAILURES"; exit 1; }
