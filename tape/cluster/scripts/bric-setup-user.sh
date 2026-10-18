#!/bin/bash
# Root-only, idempotent onboarding of one real OS/AD archive user.
#
# It keeps the institution master key administrative, creates or recovers exactly one personal
# 32-byte user key, stores only its authenticated master-wrapped escrow in the cluster catalog, and
# installs the plaintext personal key in the user's own ~/.bric with user ownership and mode 0600.
# Home operations are deliberately executed AS THE USER, so root-squashed/AD-backed filesystems can
# work when UID-based access is available. The script refuses mismatches instead of rotating keys.
set -euo pipefail
IFS=$'\n\t'
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
. "$HERE/lib_common.sh"
[ "${EUID:-$(id -u)}" -eq 0 ] || die "bric-setup-user must be run as root"
bric_log_process_start "bric-setup-user" "$@"
require_cmds getent id sqlite3 openssl sha256sum base64 awk sed mktemp flock setfacl cmp install stat

USERNAME=""; HOME_OVERRIDE=""; HANDOUT_DIR="none"; STRICT_RUNTIME=0
while [ "$#" -gt 0 ]; do case "$1" in
    --user)       USERNAME="${2:-}"; shift 2;;
    --home)       HOME_OVERRIDE="${2:-}"; shift 2;;
    --handout)    HANDOUT_DIR="${2:-}"; shift 2;;
    --no-handout) HANDOUT_DIR="none"; shift;;
    --strict-runtime-checks) STRICT_RUNTIME=1; shift;;
    -h|--help)
        cat <<'USAGE'
usage: bric-setup-user --user OS_OR_AD_USER [--home ABSOLUTE_HOME] [--handout DIR]
                       [--strict-runtime-checks]

Run as root on the Slurm/cluster host. The command is idempotent:
  * existing escrow + missing home key -> restores the same key into the home;
  * existing home key + missing escrow -> escrows that same key;
  * both present and equal             -> verifies and leaves them unchanged;
  * both present but different         -> FAILS CLOSED (no silent key rotation).

By default no second plaintext handout is left in the administrator key directory. Use
--handout DIR only when a paper/password-manager delivery sheet is explicitly required.
Runtime access problems are warnings unless --strict-runtime-checks is requested.
USAGE
        exit 0;;
    *) die "unknown option: $1";;
esac; done

[ -n "$USERNAME" ] || die "usage: bric-setup-user --user NAME"
valid_name "$USERNAME" || die "invalid user name '$USERNAME'"

PW="$(getent passwd "$USERNAME" || true)"
[ -n "$PW" ] || die "user '$USERNAME' is not resolvable by getent passwd (AD/SSSD/NSS)"
IFS=: read -r _pw_name _pw_x USER_UID USER_GID _pw_gecos USER_HOME USER_SHELL <<EOF_PW
$PW
EOF_PW
[ "$USER_UID" -ne 0 ] 2>/dev/null || die "refusing to provision uid 0"
[ -n "$HOME_OVERRIDE" ] && USER_HOME="$HOME_OVERRIDE"
case "$USER_HOME" in /*) ;; *) die "user home must be an absolute path (got '$USER_HOME')";; esac
[ "$USER_HOME" != / ] || die "refusing to use / as user home"

if command -v runuser >/dev/null 2>&1; then
    RUN_AS=(runuser -u "$USERNAME" --)
elif command -v su >/dev/null 2>&1; then
    # Fallback is intentionally limited to simple shell commands below.
    RUN_AS=(su -s /bin/bash "$USERNAME" -c)
else
    die "need runuser or su to perform root-squash-safe home operations as $USERNAME"
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/bric-user-setup.XXXXXX")"
chmod 700 "$TMP"
_cleanup(){ local rc=$?; trap - EXIT; rm -rf "$TMP"; bric_log_process_end "$rc"; exit "$rc"; }
trap _cleanup EXIT

MK="$(master_key_file)"
[ -s "$MK" ] || die "institution master key not found/empty: $MK"
[ -s "$BRIC_DB" ] || die "cluster catalog not found/empty: $BRIC_DB"

# Serialize all onboarding operations against the same cluster catalog. Without this lock, two root
# invocations for the same user could both observe "no escrow", generate different keys and race the
# final home/catalog writes. A single catalog-scoped lock is cheap and also protects batch automation.
SETUP_LOCK="${BRIC_USER_SETUP_LOCK:-$(dirname "$BRIC_DB")/.bric-user-setup.lock}"
mkdir -p "$(dirname "$SETUP_LOCK")"
exec 9>"$SETUP_LOCK"
flock -x 9 || die "cannot acquire user-onboarding lock: $SETUP_LOCK"

USER_DIR="$USER_HOME/.bric"
USER_KEY="$USER_DIR/${USERNAME}_user_key.txt"
USER_ENV="$USER_DIR/env.sh"
USER_FALLBACK_LOG_DIR="$USER_DIR/log"
LOG_ADMIN_GROUP="${BRIC_LOG_ADMIN_GROUP:-bric}"
USER_CENTRAL_LOG_ROOT="${BRIC_USER_LOG_ROOT:-${BRIC_LOG_DIR:-/var/log/bric}/users}"
USER_LOG_DIR="$USER_CENTRAL_LOG_ROOT/$USERNAME"
USER_BG_LOG_DIR="$USER_LOG_DIR/jobs"
USER_LOCAL_LOCK_ROOT="${BRIC_LOCAL_LOCK_ROOT:-/var/lib/bric/locks/users}"
USER_LOCAL_LOCK_DIR="$USER_LOCAL_LOCK_ROOT/$USERNAME"
USER_RUNSTATE="$USER_DIR/runstate"
USER_PID_DIR="$USER_DIR/pids"
TMP_KEY="$TMP/user.key"
TMP_HOME_KEY="$TMP/home.key"

run_as_user_shell() {
    local script="$1"; shift
    if [ "${RUN_AS[0]}" = runuser ]; then
        "${RUN_AS[@]}" env "$@" bash -c "$script"
    else
        # shell-quote env assignments for the su fallback
        local cmd="" kv
        for kv in "$@"; do printf -v cmd '%s %q' "$cmd" "$kv"; done
        "${RUN_AS[@]}" "env$cmd bash -c $(printf %q "$script")"
    fi
}

assert_user_env_safe() {
    if ! run_as_user_shell '
        [ ! -e "$BRIC_UENV" ] && exit 0
        [ ! -L "$BRIC_UENV" ] && [ -f "$BRIC_UENV" ] && [ -r "$BRIC_UENV" ] || exit 1
        first=$(sed -n "1p" "$BRIC_UENV" 2>/dev/null || true)
        case "$first" in
            "# BRIC-MANAGED-FILE "*|"# Generated by BRIC root onboarding."*) exit 0;;
            *) exit 1;;
        esac
    ' "BRIC_UENV=$USER_ENV"; then
        die "refusing to overwrite unmanaged user file: $USER_ENV — move it aside or let BRIC IT inspect it"
    fi
}

home_key_exists() {
    run_as_user_shell '[ -s "$BRIC_UKEY" ]' "BRIC_UKEY=$USER_KEY" >/dev/null 2>&1
}
read_home_key() {
    umask 077
    run_as_user_shell 'cat "$BRIC_UKEY"' "BRIC_UKEY=$USER_KEY" > "$TMP_HOME_KEY"
}
validate_key_file() {
    local f="$1" dec="$TMP/decoded.$$"
    [ -s "$f" ] || die "empty user key: $f"
    [ "$(wc -l < "$f" | tr -d ' ')" -le 1 ] || die "user key must be exactly one Base64 line"
    if ! openssl base64 -d -A -in "$f" -out "$dec" 2>/dev/null || [ "$(wc -c < "$dec" | tr -d ' ')" != 32 ]; then
        rm -f "$dec"; die "user key does not decode to exactly 32 bytes"
    fi
    rm -f "$dec"
}
install_home_key() {
    run_as_user_shell '
        set -eu
        umask 077
        mkdir -p "$BRIC_UDIR"
        chmod 700 "$BRIC_UDIR"
        tmp="$BRIC_UKEY.tmp.$$"
        cat > "$tmp"
        chmod 600 "$tmp"
        mv -f "$tmp" "$BRIC_UKEY"
    ' "BRIC_UDIR=$USER_DIR" "BRIC_UKEY=$USER_KEY" < "$TMP_KEY"
}

provision_central_user_log() {
    getent group "$LOG_ADMIN_GROUP" >/dev/null 2>&1 \
        || die "central log admin group does not exist: $LOG_ADMIN_GROUP"
    case "$USER_CENTRAL_LOG_ROOT" in /*) ;; *) die "BRIC_USER_LOG_ROOT must be absolute: $USER_CENTRAL_LOG_ROOT";; esac
    # The collection root is listable by the BRIC admin group but only traversable by ordinary users.
    install -d -m 0751 -o root -g "$LOG_ADMIN_GROUP" "$USER_CENTRAL_LOG_ROOT"
    # Per-user directories remain owned by the user. Their ordinary owning-group entry is deliberately
    # empty (important when the NSS primary group is a broad group such as 'users'); a named ACL grants
    # the dedicated admin group read/traverse access and is inherited by every future day/host leaf.
    install -d -m 0700 -o "$USER_UID" -g "$USER_GID" "$USER_LOG_DIR" "$USER_BG_LOG_DIR"
    setfacl -m "u::rwx,g::---,g:${LOG_ADMIN_GROUP}:r-x,m::r-x,o::---" "$USER_LOG_DIR" "$USER_BG_LOG_DIR"
    setfacl -d -m "u::rwx,g::---,g:${LOG_ADMIN_GROUP}:r-x,m::r-x,o::---" "$USER_LOG_DIR" "$USER_BG_LOG_DIR"

    # Repair previously created central-log directories and ordinary single-link log files.  Never
    # follow symlinks and never rewrite multiply-linked files: a user-controlled hardlink must not
    # let privileged onboarding grant the admin group access to an inode outside the log tree.
    find -P "$USER_LOG_DIR" -xdev -type d -exec \
        setfacl -m "u::rwx,g::---,g:${LOG_ADMIN_GROUP}:r-x,m::r-x,o::---" {} +
    find -P "$USER_LOG_DIR" -xdev -type d -exec \
        setfacl -d -m "u::rwx,g::---,g:${LOG_ADMIN_GROUP}:r-x,m::r-x,o::---" {} +
    find -P "$USER_LOG_DIR" -xdev -type f -uid "$USER_UID" -links 1 -exec \
        setfacl -m "u::rw-,g::---,g:${LOG_ADMIN_GROUP}:r--,m::r--,o::---" {} +
}


provision_local_lock_dir() {
    case "$USER_LOCAL_LOCK_ROOT" in /*) ;; *) die "BRIC_LOCAL_LOCK_ROOT must be absolute: $USER_LOCAL_LOCK_ROOT";; esac
    # Correctness locks must not inherit logging/storage placement.  Provision a dedicated local tree
    # and fail during onboarding if the administrator points it at a known network filesystem.
    install -d -m 0755 -o root -g root "$(dirname "$USER_LOCAL_LOCK_ROOT")"
    install -d -m 0711 -o root -g root "$USER_LOCAL_LOCK_ROOT"
    local lockfs
    lockfs="$(stat -f -c %T "$USER_LOCAL_LOCK_ROOT" 2>/dev/null || printf unknown)"
    case "$lockfs" in
        nfs|nfs4|cifs|smb2|9p|fuse.sshfs)
            die "BRIC_LOCAL_LOCK_ROOT must be host-local, not $lockfs: $USER_LOCAL_LOCK_ROOT";;
        unknown)
            die "cannot determine filesystem type for BRIC_LOCAL_LOCK_ROOT: $USER_LOCAL_LOCK_ROOT";;
    esac
    install -d -m 0700 -o "$USER_UID" -g "$USER_GID" "$USER_LOCAL_LOCK_DIR"
}

install_user_env() {
    local stamp
    stamp="$(date -u +%Y%m%dT%H%M%SZ)"
    cat > "$TMP/env.sh" <<EOF_ENV
# BRIC-MANAGED-FILE v1 — generated by bric-setup-user; do not edit
# Loaded only inside the BRIC command process. No shell profile is modified.
export BRIC_CONFIG=$(printf '%q' "${BRIC_CONFIG:-/etc/bric/bric.conf}")
export BRIC_USER=$(printf '%q' "$USERNAME")
export BRIC_USER_KEY_FILE=$(printf '%q' "$USER_KEY")
# Normal users log to a root-provisioned central per-user tree.  The private home tree is retained
# only as an emergency fallback if the local central filesystem becomes unavailable.
export BRIC_USER_LOG_ROOT=$(printf '%q' "$USER_CENTRAL_LOG_ROOT")
export BRIC_LOG_DIR=$(printf '%q' "$USER_LOG_DIR")
export BRIC_LOG_FALLBACK_DIR=$(printf '%q' "$USER_FALLBACK_LOG_DIR")
# Correctness-critical flock mutexes must stay on the host-local filesystem, never on shared NFS.
export BRIC_LOCAL_LOCK_DIR=$(printf '%q' "$USER_LOCAL_LOCK_DIR")
# Per-run plaintext member lists stay private in the user home. This works both in local mode
# and later on Slurm because the home is shared across the archive nodes.
export BRIC_RUNSTATE=$(printf '%q' "$USER_RUNSTATE")
# Local backup/restore jobs detach by default. PID metadata and stdout/stderr stay private here.
export BRIC_PID_DIR=$(printf '%q' "$USER_PID_DIR")
export BRIC_BACKGROUND_LOGDIR=$(printf '%q' "$USER_BG_LOG_DIR")
export BRIC_LOG_GROUP=$(printf '%q' "$LOG_ADMIN_GROUP")
EOF_ENV
    run_as_user_shell '
        set -eu
        umask 077
        mkdir -p "$BRIC_UDIR" "$BRIC_UFALLBACK" "$BRIC_URUNSTATE" "$BRIC_UPIDS"
        chmod 700 "$BRIC_UDIR" "$BRIC_UFALLBACK" "$BRIC_URUNSTATE" "$BRIC_UPIDS"
        incoming="$BRIC_UENV.new.$$"
        trap '\''rm -f "$incoming"'\'' EXIT HUP INT TERM
        cat > "$incoming"
        chmod 600 "$incoming"
        if [ -e "$BRIC_UENV" ] || [ -L "$BRIC_UENV" ]; then
            [ ! -L "$BRIC_UENV" ] || { echo "refusing symlink user environment: $BRIC_UENV" >&2; exit 73; }
            first=$(sed -n "1p" "$BRIC_UENV" 2>/dev/null || true)
            case "$first" in
                "# BRIC-MANAGED-FILE "*|"# Generated by BRIC root onboarding."*) :;;
                *) echo "refusing to overwrite unmanaged user file: $BRIC_UENV" >&2; exit 73;;
            esac
            if cmp -s "$incoming" "$BRIC_UENV"; then
                rm -f "$incoming"
                trap - EXIT HUP INT TERM
                exit 0
            fi
            backup="$BRIC_UENV.bak.$BRIC_STAMP"
            n=0
            while [ -e "$backup" ]; do n=$((n+1)); backup="$BRIC_UENV.bak.$BRIC_STAMP.$n"; done
            cp -p -- "$BRIC_UENV" "$backup"
            chmod 600 "$backup"
        fi
        mv -f "$incoming" "$BRIC_UENV"
        chmod 600 "$BRIC_UENV"
        trap - EXIT HUP INT TERM
    ' "BRIC_UDIR=$USER_DIR" "BRIC_UFALLBACK=$USER_FALLBACK_LOG_DIR" "BRIC_URUNSTATE=$USER_RUNSTATE" "BRIC_UPIDS=$USER_PID_DIR" "BRIC_UENV=$USER_ENV" "BRIC_STAMP=$stamp" < "$TMP/env.sh"
}

assert_user_env_safe
provision_central_user_log
provision_local_lock_dir

ESCROW="$(sql "SELECT key_escrow FROM users WHERE username='$(sql_quote "$USERNAME")';")"
HAVE_ESCROW=0; [ -n "$ESCROW" ] && HAVE_ESCROW=1
HAVE_HOME=0; home_key_exists && HAVE_HOME=1

if [ "$HAVE_ESCROW" = 1 ]; then
    printf '%s' "$ESCROW" | master_unwrap "$MK" > "$TMP_KEY" \
        || die "cannot unwrap existing escrow for '$USERNAME' (wrong master or corrupt escrow)"
    validate_key_file "$TMP_KEY"
    if [ "$HAVE_HOME" = 1 ]; then
        read_home_key
        validate_key_file "$TMP_HOME_KEY"
        [ "$(sha256sum "$TMP_HOME_KEY" | awk '{print $1}')" = "$(sha256sum "$TMP_KEY" | awk '{print $1}')" ] \
            || die "HOME KEY / ESCROW MISMATCH for '$USERNAME' — refusing silent rotation; investigate before proceeding"
        log "existing home key matches authenticated escrow for $USERNAME"
    else
        install_home_key
        log "restored the existing escrowed key into $USER_KEY"
    fi
else
    if [ "$HAVE_HOME" = 1 ]; then
        read_home_key
        validate_key_file "$TMP_HOME_KEY"
        cp "$TMP_HOME_KEY" "$TMP_KEY"
        chmod 600 "$TMP_KEY"
        log "importing the existing personal key from $USER_KEY into institutional escrow"
    else
        umask 077
        head -c 32 /dev/urandom | base64 > "$TMP_KEY"
        validate_key_file "$TMP_KEY"
        log "generated a new personal archive key for $USERNAME"
    fi

    reg_args=(--user "$USERNAME" --key-file "$TMP_KEY" --escrow-only)
    if [ "$HANDOUT_DIR" = none ]; then reg_args+=(--no-handout)
    else
        [ -n "$HANDOUT_DIR" ] || die "--handout requires a directory"
        case "$HANDOUT_DIR" in /*) ;; *) die "--handout directory must be absolute";; esac
        reg_args+=(--handout "$HANDOUT_DIR")
    fi
    BRIC_DB="$BRIC_DB" BRIC_CONFIG="${BRIC_CONFIG:-/etc/bric/bric.conf}" \
    BRIC_MASTER_KEY_FILE="$MK" BRIC_ADMIN_KEYS="${BRIC_ADMIN_KEYS:-$(dirname "$MK")}" \
    BRIC_KEYS="${BRIC_ADMIN_KEYS:-$(dirname "$MK")}" \
        "$HERE/bric-register-user.sh" "${reg_args[@]}"

    if [ "$HAVE_HOME" = 0 ]; then
        install_home_key
        log "installed personal key in $USER_KEY"
    fi
fi

# Exact post-install verification performed with the user's own identity, which also proves the home
# is traversable on root-squashed/AD-backed storage in the context that Slurm jobs will use.
read_home_key
validate_key_file "$TMP_HOME_KEY"
[ "$(sha256sum "$TMP_HOME_KEY" | awk '{print $1}')" = "$(sha256sum "$TMP_KEY" | awk '{print $1}')" ] \
    || die "post-install verification failed: home key differs from escrowed key"
install_user_env

# Local mode updates the single cluster catalog directly. Grant only this onboarded identity access
# to the catalog directory/file, including SQLite WAL/SHM creation. No local Unix group is required.
DB_DIR="$(dirname "$BRIC_DB")"
setfacl -m "u:${USERNAME}:rwx" "$DB_DIR"
setfacl -d -m "u:${USERNAME}:rwx" "$DB_DIR"
setfacl -m "u:${USERNAME}:rw-" "$BRIC_DB"
for db_sidecar in "$BRIC_DB-wal" "$BRIC_DB-shm"; do
    [ ! -e "$db_sidecar" ] || setfacl -m "u:${USERNAME}:rw-" "$db_sidecar"
done

# Normal production runs must never proceed without an institutional recovery escrow.
sql "INSERT INTO config(key,value) VALUES('require_user_escrow','1')
     ON CONFLICT(key) DO UPDATE SET value='1';"

# Verify non-secret runtime prerequisites with the target identity. These checks never copy the
# cluster signing private key. They are warnings by default because a QNAP/module/share outage can be
# transient; --strict-runtime-checks turns them into an onboarding gate.
runtime_issue() {
    if [ "$STRICT_RUNTIME" = 1 ]; then die "$*"; else warn_log "$*"; fi
}
if [ "$(cfg require_bus_signing 2>/dev/null || printf 0)" = 1 ]; then
    if [ -z "${BRIC_BUS_SIGN_KEY:-}" ]; then runtime_issue "require_bus_signing=1 but BRIC_BUS_SIGN_KEY is unset"
    elif ! run_as_user_shell '[ -r "$BRIC_SIGN" ]' "BRIC_SIGN=$BRIC_BUS_SIGN_KEY"; then
        runtime_issue "$USERNAME cannot read the configured cluster bus signing key: $BRIC_BUS_SIGN_KEY"
    fi
    if [ -z "${BRIC_BUS_VERIFY_KEY:-}" ]; then runtime_issue "require_bus_signing=1 but BRIC_BUS_VERIFY_KEY is unset"
    elif ! run_as_user_shell '[ -r "$BRIC_VERIFY" ]' "BRIC_VERIFY=$BRIC_BUS_VERIFY_KEY"; then
        runtime_issue "$USERNAME cannot read the configured tape verification key: $BRIC_BUS_VERIFY_KEY"
    fi
fi
run_as_user_shell '[ -d "$BRIC_BUS" ] && [ -w "$BRIC_BUS" ]' "BRIC_BUS=$BRIC_QNAP"     || runtime_issue "$USERNAME cannot currently write the configured QNAP bus root: $BRIC_QNAP"

audit USER_HOME_PROVISIONED "$USERNAME" OK "home=$USER_HOME key=$USER_KEY uid=$USER_UID gid=$USER_GID"

cat <<EOF_DONE

BRIC user onboarding complete
  user:          $USERNAME (uid=$USER_UID gid=$USER_GID)
  home:          $USER_HOME
  personal key:  $USER_KEY  (owned/readable by $USERNAME only)
  environment:   $USER_ENV
  log primary:   $USER_LOG_DIR  (private, automatic)
  run scratch:   $USER_RUNSTATE  (private, automatic)
  local locks:   $USER_LOCAL_LOCK_DIR  (host-local correctness mutexes)
  background:    $USER_PID_DIR  (PID metadata) / $USER_BG_LOG_DIR  (logs)
  master key:    $MK  (NOT copied to the user)
  escrow:        authenticated v2 row in $BRIC_DB

User commands (no shell initialization required):
  bric backup  NAME PATH
  bric restore NAME DESTINATION
  bric status
  bric jobs
  bric log JOB_ID
EOF_DONE
