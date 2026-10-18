#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
TMP="$(mktemp -d /tmp/bric-help-man.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/home/.bric" "$TMP/log/primary" "$TMP/log/fallback"

run_help() {
    BRIC_CONFIG=none BRIC_ROLE=slurm HOME="$TMP/home" \
    BRIC_LOG_DIR="$TMP/log/primary" BRIC_LOG_FALLBACK_DIR="$TMP/log/fallback" \
    BRIC_REQUIRE_LOGGING=1 "$ROOT/cluster/bin/bric-run" "$@"
}

run_help --help > "$TMP/general"
grep -q '^  bric jobs$' "$TMP/general"
grep -q '^  bric log' "$TMP/general"
grep -q '^  bric cancel' "$TMP/general"
grep -q '^  bric help' "$TMP/general"
grep -q 'man bric' "$TMP/general"
grep -q 'list     \[--long\] \[--all\]' "$TMP/general"
grep -q '^  bric contents PROJECT' "$TMP/general"
grep -q '^  bric find     PROJECT QUERY' "$TMP/general"
grep -q '^  bric exclusions PROJECT' "$TMP/general"
grep -q '^  bric source-changes PROJECT' "$TMP/general"

run_help help backup > "$TMP/backup"
grep -q '^Usage: bric backup PROJECT SOURCE \[--as LOGICAL_ROOT\] \[--exclude RELPATH \.\.\.\] \[--source-change-policy strict|record\] \[--force\] \[--wait\]' "$TMP/backup"
run_help backup --help > "$TMP/backup2"
cmp "$TMP/backup" "$TMP/backup2"
run_help backup help > "$TMP/backup3"
cmp "$TMP/backup" "$TMP/backup3"

run_help help restore > "$TMP/restore"
run_help restore --help > "$TMP/restore2"
run_help restore help > "$TMP/restore3"
cmp "$TMP/restore" "$TMP/restore2"
cmp "$TMP/restore" "$TMP/restore3"
grep -q -- '--require-destination-verify' "$TMP/restore3"
! grep -q 'preflight' "$TMP/restore3"
[ ! -d "$TMP/home/.bric/pids" ] || ! find "$TMP/home/.bric/pids" -name 'restore.*.meta' -print -quit | grep -q .

# Malformed operational commands must fail synchronously, before preflight and
# before the background supervisor creates a restore.unknown/backup.unknown job.
if run_help restore project-only >"$TMP/badrestore.out" 2>"$TMP/badrestore.err"; then
    echo 'FAIL: incomplete restore command accepted' >&2; exit 1
fi
grep -q 'usage: bric restore PROJECT DEST' "$TMP/badrestore.err"
! grep -q 'bric-run preflight' "$TMP/badrestore.out"
[ ! -d "$TMP/home/.bric/pids" ] || ! find "$TMP/home/.bric/pids" -name 'restore.*.meta' -print -quit | grep -q .

if run_help backup project-only >"$TMP/badbackup.out" 2>"$TMP/badbackup.err"; then
    echo 'FAIL: incomplete backup command accepted' >&2; exit 1
fi
grep -q 'usage: bric backup PROJECT SOURCE' "$TMP/badbackup.err"
! grep -q 'bric-run preflight' "$TMP/badbackup.out"

run_help --help log > "$TMP/loghelp"
grep -q 'Press Ctrl-C' "$TMP/loghelp"
run_help list --help > "$TMP/listhelp"
grep -q -- '--all' "$TMP/listhelp"
run_help contents --help > "$TMP/contentshelp"
grep -q -- '--limit 0' "$TMP/contentshelp"
run_help find --help > "$TMP/findhelp"
grep -q 'case-insensitively' "$TMP/findhelp"
run_help source-changes --help > "$TMP/sourcechangeshelp"
grep -q 'FILE_CHANGED_DURING_READ' "$TMP/sourcechangeshelp"
grep -q -- '--force' "$TMP/backup"

MAN="$ROOT/docs/man/bric.1"
[ -s "$MAN" ]
grep -q '^\.TH BRIC 1 ' "$MAN"
for section in NAME SYNOPSIS DESCRIPTION COMMANDS OPTIONS 'RUN STATES' FILES ENVIRONMENT 'EXIT STATUS' EXAMPLES 'SEE ALSO'; do
    grep -q "^\\.SH $section$" "$MAN"
done
for command in backup restore status list contents find exclusions source-changes jobs log cancel help; do
    grep -q "$command" "$MAN"
done
grep -q 'BRIC_MAN_DIR:=/usr/local/share/man/man1' "$ROOT/bric-setup.sh"
grep -q 'install_man_page' "$ROOT/bric-setup.sh"
grep -q 'docs/man/bric.1' "$ROOT/bric-setup.sh"
grep -q -- '--require-destination-verify' "$MAN"

bash -n "$ROOT/cluster/bin/bric" "$ROOT/cluster/bin/bric-run" "$ROOT/bric-setup.sh"
echo 'PASS: complete CLI help, command help and standard bric(1) manual installation'
