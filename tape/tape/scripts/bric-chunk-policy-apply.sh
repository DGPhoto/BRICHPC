#!/bin/bash
# Apply Review 32B1 chunk-size policy to an EXISTING tape catalog.
# Static code updates never mutate catalogs; run explicitly while no archive/restore is active.
set -euo pipefail
IFS=$'\n\t'
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
. "$HERE/lib_common.sh"
require_role tape
require_cmds sqlite3 find
TARGET=128000000000
SHOW=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --chunk-target-bytes) TARGET="${2:-}"; shift 2;;
        --show) SHOW=1; shift;;
        -h|--help)
            cat <<'USAGE'
Usage: bric-chunk-policy-apply.sh [--chunk-target-bytes BYTES] [--show]

Updates only tape.config.chunk_target_bytes in an existing tape catalog.
Default: 128000000000 (128 GB decimal).
Refuses to change policy while an active reservation or restore request exists.
USAGE
            exit 0;;
        *) die "unknown option: $1";;
    esac
done
case "$TARGET" in ''|*[!0-9]*|0) die "--chunk-target-bytes must be a positive integer";; esac
show_values() { sqlite3 -header -column "$BRIC_TAPE_DB" "SELECT key,value FROM config WHERE key='chunk_target_bytes';"; }
[ "$SHOW" -eq 0 ] || { show_values; exit 0; }
[ "${EUID:-$(id -u)}" -eq 0 ] || die "chunk policy changes must be applied as root"
active="$(sqlite3 -batch -cmd '.timeout 60000' "$BRIC_TAPE_DB" "SELECT COUNT(*) FROM reservation WHERE state='GRANTED';")"
[ "$active" = 0 ] || die "$active active reservation(s) found; wait until archive work is terminal"
# A restore can exist only on the shared bus; refuse if a request is present without a terminal STAGED receipt.
if [ -d "$BRIC_QNAP/restore" ] && find "$BRIC_QNAP/restore" -mindepth 3 -maxdepth 3 -type f -name request -print -quit 2>/dev/null | grep -q .; then
    pending=0
    while IFS= read -r req; do
        d="$(dirname "$req")"
        [ -e "$d/request.STAGED" ] || pending=$((pending+1))
    done < <(find "$BRIC_QNAP/restore" -mindepth 3 -maxdepth 3 -type f -name request 2>/dev/null)
    [ "$pending" -eq 0 ] || die "$pending active restore request(s) found; wait/cancel before changing chunk policy"
fi
printf 'Before:\n'; show_values
sqlite3 -batch -cmd '.timeout 60000' "$BRIC_TAPE_DB" "INSERT INTO config(key,value) VALUES('chunk_target_bytes','$TARGET') ON CONFLICT(key) DO UPDATE SET value=excluded.value;"
printf '\nAfter:\n'; show_values
printf '\nReview 32B1 tape chunk policy applied. chunk_target_bytes=%s bytes.\n' "$TARGET"
