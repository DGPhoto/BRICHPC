#!/bin/bash
# bric-register-user: register a designated archive user and escrow their key with the institution
# master key. This is an ADMIN action: normal users never receive or read the master key.
#
# Default mode preserves the historical admin key directory behaviour (generate/install
# $BRIC_USER_KEYS_DIR/<user>_user_key.txt, then escrow it).  --escrow-only is the production-safe
# mode used by bric-setup-user.sh: it wraps a supplied key without leaving a second plaintext copy in
# the administrator key directory.
set -euo pipefail
IFS=$'\n\t'
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
. "$HERE/lib_common.sh"
bric_log_process_start "bric-register-user" "$@"
require_cmds sqlite3 openssl sha256sum awk base64

USERNAME=""; KEY_FILE=""; USERS_FILE=""; HANDOUT_DIR="${BRIC_HANDOUTS:-}"; ESCROW_ONLY=0
while [ "$#" -gt 0 ]; do case "$1" in
    --user)         USERNAME="${2:-}"; shift 2;;
    --key-file)     KEY_FILE="${2:-}"; shift 2;;
    --users-file)   USERS_FILE="${2:-}"; shift 2;;
    --handout)      HANDOUT_DIR="${2:-}"; shift 2;;
    --no-handout)   HANDOUT_DIR="none"; shift;;
    --escrow-only)  ESCROW_ONLY=1; shift;;
    --generate)     shift;; # compatibility: generation is already the default when no key exists
    -h|--help)
        cat <<'USAGE'
usage: bric-register-user --user NAME [--key-file FILE] [--handout DIR|--no-handout]
       bric-register-user --user NAME --key-file FILE --escrow-only [--handout DIR|--no-handout]
       bric-register-user --users-file FILE [--handout DIR|--no-handout]

--escrow-only wraps the supplied key but does not copy it into the administrator key directory.
Use cluster/scripts/bric-setup-user.sh for normal production onboarding.
USAGE
        exit 0;;
    *) die "unknown option: $1";;
esac; done

# Batch mode is retained for staging/logical users. Production OS/AD users should be provisioned by
# bric-setup-user.sh so ownership, home permissions and escrow consistency are verified together.
if [ -n "$USERS_FILE" ]; then
    [ "$ESCROW_ONLY" = 0 ] || die "--escrow-only is not supported with --users-file"
    [ -f "$USERS_FILE" ] || die "users file not found: $USERS_FILE"
    rc=0
    while IFS= read -r u || [ -n "$u" ]; do
        u="${u%%#*}"; u="$(printf '%s' "$u" | tr -d '[:space:]')"
        [ -n "$u" ] || continue
        args=(--user "$u")
        [ -z "${HANDOUT_DIR:-}" ] || { [ "$HANDOUT_DIR" = none ] && args+=(--no-handout) || args+=(--handout "$HANDOUT_DIR"); }
        "$0" "${args[@]}" || { log "FAILED registering $u"; rc=1; }
    done < "$USERS_FILE"
    exit "$rc"
fi

[ -n "$USERNAME" ] || die "usage: bric-register-user --user NAME [--key-file FILE]"
valid_name "$USERNAME" || die "invalid user name '$USERNAME'"

MK="$(master_key_file)"
[ -s "$MK" ] || die "master key not found/empty: $MK (administrator action)"

KEY_SOURCE=""
if [ "$ESCROW_ONLY" = 1 ]; then
    [ -n "$KEY_FILE" ] || die "--escrow-only requires --key-file FILE"
    [ -s "$KEY_FILE" ] || die "key file not found/empty: $KEY_FILE"
    KEY_SOURCE="$KEY_FILE"
else
    UKF="$(user_key_file "$USERNAME")"
    mkdir -p "$(dirname "$UKF")"
    if [ -n "$KEY_FILE" ]; then
        [ -s "$KEY_FILE" ] || die "key file not found/empty: $KEY_FILE"
        install -m 600 "$KEY_FILE" "$UKF"
        log "installed user key for $USERNAME from $KEY_FILE"
    elif [ -s "$UKF" ]; then
        log "using existing user key for $USERNAME ($UKF)"
    else
        umask 077
        head -c 32 /dev/urandom | base64 > "$UKF.tmp.$$"
        mv -f "$UKF.tmp.$$" "$UKF"
        chmod 600 "$UKF"
        log "generated new user key for $USERNAME ($UKF)"
    fi
    KEY_SOURCE="$UKF"
fi

# Validate the persistent key format without printing it: exactly one non-empty Base64 line which
# decodes to 32 bytes. This catches truncated hand-copies before any archive is created.
[ "$(wc -l < "$KEY_SOURCE" | tr -d ' ')" -le 1 ] || die "user key must contain one Base64 line: $KEY_SOURCE"
_dec="$(mktemp)"
if ! openssl base64 -d -A -in "$KEY_SOURCE" -out "$_dec" 2>/dev/null || [ "$(wc -c < "$_dec" | tr -d ' ')" != 32 ]; then
    rm -f "$_dec"; die "user key is not Base64 encoding of exactly 32 random bytes: $KEY_SOURCE"
fi
rm -f "$_dec"

ESCROW="$(master_wrap "$MK" < "$KEY_SOURCE")" || die "failed to wrap user key with master key"
[ -n "$ESCROW" ] || die "empty escrow produced"
QESC="$(sql_quote "$ESCROW")"
sql "INSERT INTO users (username,key_escrow,created_at,updated_at)
     VALUES ('$(sql_quote "$USERNAME")','$QESC',datetime('now'),datetime('now'))
     ON CONFLICT(username) DO UPDATE SET key_escrow='$QESC', updated_at=datetime('now');"

GOT="$(printf '%s' "$ESCROW" | master_unwrap "$MK")" || die "escrow self-check: unwrap failed"
[ "$GOT" = "$(cat "$KEY_SOURCE")" ] || die "escrow self-check: unwrapped key does not match"
audit USER_REGISTERED "$USERNAME" OK "authenticated escrow; plaintext_admin_copy=$([ "$ESCROW_ONLY" = 1 ] && echo no || echo yes)"

if [ "${HANDOUT_DIR:-}" != "none" ]; then
    HD="${HANDOUT_DIR:-${BRIC_ADMIN_KEYS:-$BRIC_KEYS}/handouts}"
    ( umask 077; mkdir -p "$HD" )
    HOF="$HD/${USERNAME}_key_handout.txt"
    ( umask 077; {
        echo "=============================================================================="
        echo " BRIC ARCHIVE 2.0 — PERSONAL RECOVERY KEY                    $(date -u +%Y-%m-%d)"
        echo " User: $USERNAME"
        echo "=============================================================================="
        echo
        echo " YOUR KEY (one line, exactly as printed):"
        echo
        echo "   $(cat "$KEY_SOURCE")"
        echo
        echo " WHAT IT IS"
        echo "   This key encrypts every archive you make. With it — and the tapes — your"
        echo "   data is recoverable in 10-15 years even if no BRIC system still exists."
        echo
        echo " KEEP IT LIKE THIS"
        echo "   1. PRINT this sheet and store it somewhere safe OUTSIDE the university"
        echo "      (at home, in a safe). Paper survives everything digital."
        echo "   2. Optionally also store the key line in a password manager."
        echo "   3. NEVER send it by email or chat. Never store it next to the tapes."
        echo
        echo " IF YOU LOSE IT"
        echo "   BRIC IT can recover your data with the institution master key (break-glass,"
        echo "   audited). If BOTH your key and the master key are lost, the data is"
        echo "   mathematically unrecoverable. That is the design, not a bug."
        echo
        echo " EMERGENCY RECOVERY (any Linux machine, the tapes, this key — nothing else):"
        echo "   bric-dr-from-tapes.sh --project <YOUR_PROJECT> \\"
        echo "       --user-key-file <file containing the key line above> --dest <output dir>"
        echo "   Full instructions travel ON every tape (README_RECOVERY.txt) and in the"
        echo "   Recovery Handbook (docs/RECOVERY_HANDBOOK.html)."
        echo "=============================================================================="
    } > "$HOF" )
    chmod 600 "$HOF"
    log "key handout sheet written: $HOF (print/deliver securely, then delete the plaintext sheet)"
fi

log "user '$USERNAME' registered and key escrowed (master-recoverable)"
