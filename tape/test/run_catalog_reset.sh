#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
S="$ROOT/cluster/scripts/bric-reset-catalog.sh"
bash -n "$S"
grep -q 'DELETE FROM runs;' "$S"
grep -q 'DELETE FROM projects;' "$S"
grep -q "UPDATE config SET value='0' WHERE key='run_counter'" "$S"
! grep -q 'DELETE FROM users;' "$S"
grep -q '\.backup' "$S"
grep -q 'refusing destructive reset without --yes' "$S"
grep -q 'libexec/bric-tar-stream' "$S"
grep -q 'stream-backup' "$S"
echo 'PASS: reset script backs up and clears operational state while preserving users/config'
