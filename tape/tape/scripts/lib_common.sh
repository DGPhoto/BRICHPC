#!/bin/bash
# Shared helpers for the TAPE SERVER side. Same marker semantics as the cluster. No keys, ever.

tsql()  { sqlite3 -batch -cmd '.timeout 60000' "$BRIC_TAPE_DB" "$1"; }
tsqlc() { sqlite3 -batch -separator '|' -cmd '.timeout 60000' "$BRIC_TAPE_DB" "$1"; }
sql_quote() { printf "%s" "$1" | sed "s/'/''/g"; }
tcfg() { tsql "SELECT value FROM config WHERE key='$(sql_quote "$1")';"; }
# -------------------------------------------------------------------------------------------------
# Durable operational logging (Review-30).
#
# Primary destination:  $BRIC_LOG_DIR (default /var/log/bric)
# NFS fallback:         $BRIC_LOG_FALLBACK_DIR
#
# Per-process *.events.v1.log files are pipe-delimited and have a stable schema for the future reader:
# BRICLOGv1|time|host|role|user|component|pid|ppid|level|event|run|project|chunk|copy|drive|vt|
# attempt|rc|duration_ms|bytes|slurm_job|slurm_task|message
#
# Raw stdout/stderr are copied to one file per process. They are never merged, so commands whose
# stdout is an API (notably `bric backup`, which echoes a run id) remain byte-for-byte compatible.
# No shell tracing is used: `set -x` would expose passphrases and key material.
# -------------------------------------------------------------------------------------------------
_bric_log_host() { hostname -s 2>/dev/null || hostname 2>/dev/null || printf unknown; }
_bric_log_clean() {
    local s="${1-}" max="${BRIC_LOG_MAX_MESSAGE:-4000}"
    s="$(printf '%s' "$s" | tr '\r\n\t|' '    ')"
    printf '%s' "$s" | head -c "$max"
}
_bric_log_safe_component() {
    local s="${1:-$(basename "$0")}"; s="$(printf '%s' "$s" | tr -c 'A-Za-z0-9._-' '_')"
    printf '%s' "${s:-unknown}"
}
_bric_log_default_fallback() {
    local host; host="$(_bric_log_host)"
    case "${BRIC_ROLE:-slurm}" in
        slurm) printf '%s/log/fallback/%s' "${BRIC_HOME:-/projects/bricsoftware/apps/bric2/cluster}" "$host";;
        tape)  printf '%s/.system/log/%s' "${BRIC_QNAP:-/mnt/data/bric}" "$host";;
        *)     printf '%s/bric-log/%s' "${TMPDIR:-/tmp}" "$host";;
    esac
}
_bric_log_prepare_root() {
    local root="$1" probe mnt fs
    [ -n "$root" ] || return 1
    # If a logging destination lives under the shared bus, never create it on the local root
    # filesystem after an NFS mount loss. This matters on the tape host, whose fallback is normally
    # $BRIC_QNAP/.system/log/<host>.
    if [ "${BRIC_REQUIRE_NFS_BUS:-0}" = 1 ] && [ -n "${BRIC_QNAP:-}" ]; then
        case "$root/" in
            "$BRIC_QNAP"/*)
                mnt="${BRIC_QNAP_MNT:-$(dirname "$BRIC_QNAP")}"; fs=""
                command -v mountpoint >/dev/null 2>&1 && mountpoint -q "$mnt" 2>/dev/null || return 1
                if command -v findmnt >/dev/null 2>&1; then
                    fs="$(findmnt -n -T "$mnt" -o FSTYPE 2>/dev/null | head -1 || true)"
                fi
                [ -n "$fs" ] || fs="$(stat -f -c %T "$mnt" 2>/dev/null || true)"
                case "$fs" in nfs|nfs4|nfs*) :;; *) return 1;; esac
                ;;
        esac
    fi
    mkdir -p "$root" 2>/dev/null || return 1
    probe="$root/.bric-write-test.$$"
    ( umask 0002; : > "$probe" ) 2>/dev/null || return 1
    rm -f "$probe" 2>/dev/null || true
    return 0
}
bric_log_init() {
    [ -n "${_BRIC_LOG_INITIALIZED:-}" ] && return 0
    _BRIC_LOG_INITIALIZED=1
    _BRIC_LOG_PRIMARY_ROOT="${BRIC_LOG_DIR:-/var/log/bric}"
    _BRIC_LOG_FALLBACK_ROOT="${BRIC_LOG_FALLBACK_DIR:-$(_bric_log_default_fallback)}"
    if _bric_log_prepare_root "$_BRIC_LOG_PRIMARY_ROOT"; then
        _BRIC_LOG_CURRENT_ROOT="$_BRIC_LOG_PRIMARY_ROOT"
        _BRIC_LOG_LOCATION=primary
    elif _bric_log_prepare_root "$_BRIC_LOG_FALLBACK_ROOT"; then
        _BRIC_LOG_CURRENT_ROOT="$_BRIC_LOG_FALLBACK_ROOT"
        _BRIC_LOG_LOCATION=fallback
        printf '[%s] WARN: BRIC structured log failover primary=%s fallback=%s trigger=initialization\n' \
            "$(date +'%Y-%m-%d %H:%M:%S')" "$_BRIC_LOG_PRIMARY_ROOT" "$_BRIC_LOG_FALLBACK_ROOT" >&2
    else
        _BRIC_LOG_CURRENT_ROOT=""
        _BRIC_LOG_LOCATION=unavailable
        printf '[%s] ERROR: neither BRIC log destination is writable (primary=%s fallback=%s)\n' \
            "$(date +'%Y-%m-%d %H:%M:%S')" "$_BRIC_LOG_PRIMARY_ROOT" "$_BRIC_LOG_FALLBACK_ROOT" >&2
    fi
    export _BRIC_LOG_PRIMARY_ROOT _BRIC_LOG_FALLBACK_ROOT _BRIC_LOG_CURRENT_ROOT _BRIC_LOG_LOCATION
    # Review 31E6: an initialization-time failover must be durable in the structured log too,
    # not only visible on stderr. bric_event() re-enters bric_log_init(), which is safe because
    # _BRIC_LOG_INITIALIZED is already set before destination selection.
    if [ "${_BRIC_LOG_LOCATION:-}" = fallback ] && [ "${_BRIC_LOG_INIT_FAILOVER_RECORDED:-0}" != 1 ]; then
        _BRIC_LOG_INIT_FAILOVER_RECORDED=1; export _BRIC_LOG_INIT_FAILOVER_RECORDED
        BRIC_LOG_RC=1 bric_event WARN LOG_FAILOVER \
            "primary=${_BRIC_LOG_PRIMARY_ROOT:-unset} fallback=${_BRIC_LOG_FALLBACK_ROOT:-unset} trigger=initialization" || true
    fi
}
_bric_log_day() { date -u +%Y-%m-%d; }
_bric_log_event_rel() {
    # Keep one process-unique event-log stem, but resolve the YYYY-MM-DD directory on EVERY event.
    # A long-running daemon must not file September 7 events under its September 5 start directory.
    local day host comp stamp
    if [ -z "${_BRIC_LOG_EVENT_STEM:-}" ]; then
        comp="$(_bric_log_safe_component "${BRIC_LOG_COMPONENT:-$(basename "$0")}")"
        stamp="$(date -u +%Y%m%dT%H%M%SZ).${SLURM_JOB_ID:-nojob}.$$.${RANDOM:-0}"
        _BRIC_LOG_EVENT_STEM="${comp}.${stamp}.events.v1.log"
        export _BRIC_LOG_EVENT_STEM
    fi
    day="$(_bric_log_day)"; host="$(_bric_log_host)"
    _BRIC_LOG_EVENT_REL="events/$day/$host/$_BRIC_LOG_EVENT_STEM"
    export _BRIC_LOG_EVENT_REL
    return 0
}
_bric_log_prepare_leaf_dir() {
    local dir="$1" group="${BRIC_LOG_GROUP:-bric}" current_group=""
    mkdir -p "$dir" 2>/dev/null || return 1
    current_group="$(stat -c %G "$dir" 2>/dev/null || true)"
    # Preferred production layout: setgid BRIC group, so 0640 files created by different real users
    # remain readable by the operator/parser service even across root-squashed NFS. If the group is
    # unavailable or the caller cannot use it, fall back to sticky write/execute-only shared dirs.
    if [ "$current_group" = "$group" ] || chgrp "$group" "$dir" 2>/dev/null; then
        chmod 2770 "$dir" 2>/dev/null || true
    else
        chmod 1733 "$dir" 2>/dev/null || true
    fi
    return 0
}
_bric_log_append_at_root() { # root line
    local root="$1" line="$2" path dir
    [ -n "$root" ] || return 1
    _bric_log_prepare_root "$root" || return 1
    _bric_log_event_rel
    path="$root/$_BRIC_LOG_EVENT_REL"; dir="$(dirname "$path")"
    _bric_log_prepare_leaf_dir "$root/events" || return 1
    _bric_log_prepare_leaf_dir "$root/events/$(_bric_log_day)" || return 1
    _bric_log_prepare_leaf_dir "$dir" || return 1
    ( umask 0027; printf '%s\n' "$line" >>"$path"; chmod 0640 "$path" 2>/dev/null || true ) 2>/dev/null
}
_bric_log_append() { # line; primary first, then persistent fallback
    local line="$1" root
    bric_log_init
    for root in "${_BRIC_LOG_CURRENT_ROOT:-}" "${_BRIC_LOG_FALLBACK_ROOT:-}"; do
        [ -n "$root" ] || continue
        if _bric_log_append_at_root "$root" "$line"; then
            if [ "$root" != "${_BRIC_LOG_CURRENT_ROOT:-}" ]; then
                local failed_primary="${_BRIC_LOG_CURRENT_ROOT:-unset}"
                _BRIC_LOG_CURRENT_ROOT="$root"; _BRIC_LOG_LOCATION=fallback
                export _BRIC_LOG_CURRENT_ROOT _BRIC_LOG_LOCATION
                # The triggering event is already durable on fallback. Emit an explicit structured
                # breadcrumb there too; direct _append_at_root avoids recursive failover handling.
                if [ "${_BRIC_LOG_FAILOVER_EMITTING:-0}" != 1 ]; then
                    _BRIC_LOG_FAILOVER_EMITTING=1; export _BRIC_LOG_FAILOVER_EMITTING
                    local fts fhost frole fuser fcomp fline
                    fts="$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"
                    fhost="$(_bric_log_host)"; frole="${BRIC_ROLE:-unknown}"; fuser="${BRIC_USER:-${USER:-unknown}}"; fcomp="${BRIC_LOG_COMPONENT:-$(basename "$0")}"
                    fline="BRICLOGv1|$(_bric_log_clean "$fts")|$(_bric_log_clean "$fhost")|$(_bric_log_clean "$frole")|$(_bric_log_clean "$fuser")|$(_bric_log_clean "$fcomp")|${BASHPID:-$$}|$PPID|WARN|LOG_FAILOVER|$(_bric_log_clean "${BRIC_LOG_RUN_ID:-${BRIC_RUN_ID:-}}")|$(_bric_log_clean "${BRIC_LOG_PROJECT:-${BRIC_PROJECT:-}}")|$(_bric_log_clean "${BRIC_LOG_CHUNK:-}")|$(_bric_log_clean "${BRIC_LOG_COPY_ROLE:-}")|$(_bric_log_clean "${BRIC_LOG_DRIVE:-}")|$(_bric_log_clean "${BRIC_LOG_VOLUMETAG:-}")||1|||||primary=$(_bric_log_clean "$failed_primary") fallback=$(_bric_log_clean "$root") trigger=structured-write-failure"
                    _bric_log_append_at_root "$root" "$fline" || true
                    printf '[%s] WARN: BRIC structured log failover primary=%s fallback=%s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$failed_primary" "$root" >&2 || true
                    _BRIC_LOG_FAILOVER_EMITTING=0; export _BRIC_LOG_FAILOVER_EMITTING
                fi
            fi
            return 0
        fi
    done
    return 1
}
bric_event() { # LEVEL EVENT MESSAGE -- context comes from BRIC_LOG_* variables
    local level="${1:-INFO}" event="${2:-MESSAGE}" message="${3:-}" ts host role user component
    local run project chunk copy drive vt attempt rc duration bytes sjob stask line
    bric_log_init
    ts="$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"
    host="$(_bric_log_host)"; role="${BRIC_ROLE:-unknown}"; user="${BRIC_USER:-${USER:-$(id -un 2>/dev/null || echo unknown)}}"
    component="${BRIC_LOG_COMPONENT:-$(basename "$0")}"; run="${BRIC_LOG_RUN_ID:-${BRIC_RUN_ID:-}}"
    project="${BRIC_LOG_PROJECT:-${BRIC_PROJECT:-}}"; chunk="${BRIC_LOG_CHUNK:-}"
    copy="${BRIC_LOG_COPY_ROLE:-}"; drive="${BRIC_LOG_DRIVE:-}"; vt="${BRIC_LOG_VOLUMETAG:-}"
    attempt="${BRIC_LOG_ATTEMPT:-}"; rc="${BRIC_LOG_RC:-}"; duration="${BRIC_LOG_DURATION_MS:-}"
    bytes="${BRIC_LOG_BYTES:-}"; sjob="${SLURM_JOB_ID:-}"; stask="${SLURM_ARRAY_TASK_ID:-}"
    line="BRICLOGv1|$(_bric_log_clean "$ts")|$(_bric_log_clean "$host")|$(_bric_log_clean "$role")|$(_bric_log_clean "$user")|$(_bric_log_clean "$component")|${BASHPID:-$$}|$PPID|$(_bric_log_clean "$level")|$(_bric_log_clean "$event")|$(_bric_log_clean "$run")|$(_bric_log_clean "$project")|$(_bric_log_clean "$chunk")|$(_bric_log_clean "$copy")|$(_bric_log_clean "$drive")|$(_bric_log_clean "$vt")|$(_bric_log_clean "$attempt")|$(_bric_log_clean "$rc")|$(_bric_log_clean "$duration")|$(_bric_log_clean "$bytes")|$(_bric_log_clean "$sjob")|$(_bric_log_clean "$stask")|$(_bric_log_clean "$message")"
    if ! _bric_log_append "$line"; then
        printf '[%s] ERROR: BRIC structured log unavailable (primary=%s fallback=%s event=%s)\n' \
            "$(date +'%Y-%m-%d %H:%M:%S')" "${_BRIC_LOG_PRIMARY_ROOT:-unset}" \
            "${_BRIC_LOG_FALLBACK_ROOT:-unset}" "$event" >&2
        [ "${BRIC_REQUIRE_LOGGING:-1}" = 1 ] && return 70
    fi
    return 0
}
_bric_log_prepare_process_dir() { # root relative-process-prefix
    local root="$1" rel="$2" day host dir
    [ -n "$root" ] || return 1
    _bric_log_prepare_root "$root" || return 1
    day="$(printf '%s' "$rel" | cut -d/ -f2)"; host="$(printf '%s' "$rel" | cut -d/ -f3)"
    _bric_log_prepare_leaf_dir "$root/processes" || return 1
    _bric_log_prepare_leaf_dir "$root/processes/$day" || return 1
    dir="$root/processes/$day/$host"
    _bric_log_prepare_leaf_dir "$dir" || return 1
}
_bric_raw_append() { # path line
    local path="$1" line="$2"
    [ -d "$(dirname "$path")" ] || return 1
    ( umask 0027; printf '%s\n' "$line" >>"$path"; chmod 0640 "$path" 2>/dev/null || true ) 2>/dev/null
}
_bric_stdio_sink() { # stdout|stderr primary_path fallback_path
    local stream="$1" current="$2" fallback="$3" line failed_over=0
    while IFS= read -r line || [ -n "$line" ]; do
        if ! _bric_raw_append "$current" "$line"; then
            current="$fallback"
            if [ "$failed_over" -eq 0 ]; then
                failed_over=1
                _bric_raw_append "$current" "BRIC LOG FAILOVER: primary raw log became unavailable; stream=$stream" || true
                BRIC_LOG_RC=1 bric_event WARN LOG_FAILOVER "stream=$stream fallback=$fallback" || true
            fi
            _bric_raw_append "$current" "$line" || true
        fi
        if [ "$stream" = stdout ]; then printf '%s\n' "$line"; else printf '%s\n' "$line" >&2; fi
    done
}
bric_log_attach_stdio() {
    [ "${BRIC_LOG_CAPTURE_STDIO:-1}" = 1 ] || return 0
    [ -n "${_BRIC_STDIO_ATTACHED:-}" ] && return 0
    bric_log_init
    [ -n "${_BRIC_LOG_CURRENT_ROOT:-}" ] || return 0
    local day host comp stamp rel pbase fbase
    day="$(date -u +%Y-%m-%d)"; host="$(_bric_log_host)"; comp="$(_bric_log_safe_component "${BRIC_LOG_COMPONENT:-$(basename "$0")}")"
    stamp="$(date -u +%Y%m%dT%H%M%SZ).${SLURM_JOB_ID:-nojob}.$$.${RANDOM:-0}"
    rel="processes/$day/$host/${comp}.${stamp}"
    pbase="${_BRIC_LOG_CURRENT_ROOT}/$rel"; fbase="${_BRIC_LOG_FALLBACK_ROOT}/$rel"
    _bric_log_prepare_process_dir "${_BRIC_LOG_CURRENT_ROOT}" "$rel" || true
    _bric_log_prepare_process_dir "${_BRIC_LOG_FALLBACK_ROOT}" "$rel" || true
    _BRIC_STDIO_ATTACHED=1; export _BRIC_STDIO_ATTACHED
    exec 1> >(_bric_stdio_sink stdout "${pbase}.stdout.log" "${fbase}.stdout.log")
    exec 2> >(_bric_stdio_sink stderr "${pbase}.stderr.log" "${fbase}.stderr.log" >&2)
}
bric_log_process_start() { # component argv...
    local component="${1:-$(basename "$0")}"; shift || true
    BRIC_LOG_COMPONENT="$(_bric_log_safe_component "$component")"; export BRIC_LOG_COMPONENT
    bric_log_init
    if [ -z "${_BRIC_LOG_CURRENT_ROOT:-}" ] && [ "${BRIC_REQUIRE_LOGGING:-1}" = 1 ]; then
        printf '[%s] ERROR: refusing to start unlogged component %s; primary and NFS fallback are unavailable\n' \
            "$(date +'%Y-%m-%d %H:%M:%S')" "$BRIC_LOG_COMPONENT" >&2
        exit 70
    fi
    _bric_log_event_rel; bric_log_attach_stdio
    local process_extra="${BRIC_LOG_PROCESS_EXTRA:-}"
    BRIC_LOG_RC=0 bric_event INFO PROCESS_START "cwd=$(pwd) argv=$* log=${_BRIC_LOG_LOCATION:-unknown}:${_BRIC_LOG_CURRENT_ROOT:-none}${process_extra:+ $process_extra}"
    if [ "${_BRIC_LOG_LOCATION:-}" = fallback ]; then
        bric_event WARN LOG_FALLBACK_ACTIVE "primary=${_BRIC_LOG_PRIMARY_ROOT:-unset} fallback=${_BRIC_LOG_FALLBACK_ROOT:-unset}"
    fi
    _BRIC_PROCESS_END_LOGGED=0; export _BRIC_PROCESS_END_LOGGED
    trap 'bric_log_process_end "$?"' EXIT
}
bric_log_process_end() { # rc
    local rc="${1:-0}" level=INFO
    [ "${_BRIC_PROCESS_END_LOGGED:-0}" = 1 ] && return 0
    _BRIC_PROCESS_END_LOGGED=1; export _BRIC_PROCESS_END_LOGGED
    [ "$rc" -eq 0 ] 2>/dev/null || level=ERROR
    BRIC_LOG_RC="$rc" bric_event "$level" PROCESS_END "process exited rc=$rc" || true
    return 0
}
_bric_human_log() { printf '[%s] %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$*" >&2; }
log()  { bric_event INFO MESSAGE "$*"; _bric_human_log "$*"; }
warn_log() { bric_event WARN WARNING "$*"; _bric_human_log "WARN: $*"; }
die()  {
    local msg="$*"
    BRIC_LOG_RC=1 bric_event ERROR FATAL "$msg" ||         _bric_human_log "ERROR: FATAL event could not be persisted"
    _bric_human_log "ERROR: $msg"
    exit 1
}

audit() {
    local action="$1" object="${2:-}" result="${3:-}" detail="${4:-}" err rc=0
    err="$(mktemp)"
    if tsql "INSERT INTO audit_log (actor,action,object,result,detail) VALUES ('tape-daemon','$(sql_quote "$action")','$(sql_quote "$object")','$(sql_quote "$result")','$(sql_quote "$detail")');" 2>"$err"; then
        bric_event INFO AUDIT "action=$action object=$object result=$result detail=$detail"
    else
        rc=$?; BRIC_LOG_RC="$rc" bric_event ERROR AUDIT_DB_WRITE_FAILED "action=$action object=$object result=$result sqlite=$(tr '\n|' '  ' <"$err" | head -c 1000)"
    fi
    rm -f "$err"; return 0
}

# ---------------------------------------------------------------------------------------------
# Central config file loader. LOCKSTEP COPY: an identical function lives in tape/scripts/
# lib_common.sh (the two hosts do not share files at runtime) — modify BOTH together, like the
# DR escrow-unwrap precedent.
# Search order: $BRIC_CONFIG (explicit path; the literal value "none" disables loading entirely,
# used by the test suite for hermeticity), else /etc/bric/bric.conf.
# Precedence: THE ENVIRONMENT WINS. The file only fills in variables not already set, so explicit
# exports, systemd Environment= lines and test harnesses always override it.
# The file is PARSED, never sourced: only lines matching BRIC_<NAME>=<value> are honored, so a
# writable config can never inject code. BRIC_FAULT_* keys are refused: fault injection must never
# be persistable in a config file.
# ---------------------------------------------------------------------------------------------
bric_load_config() {
    local cfg="${BRIC_CONFIG:-/etc/bric/bric.conf}" line key val
    [ "$cfg" = none ] && return 0
    [ -f "$cfg" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%%#*}"                          # strip comments
        line="${line#"${line%%[![:space:]]*}"}"     # ltrim
        [ -n "$line" ] || continue
        key="${line%%=*}"; val="${line#*=}"
        case "$key" in
            BRIC_FAULT_*) continue;;                # never persistable
            BRIC_[A-Z0-9_]*) ;;
            *) continue;;                           # not a BRIC_ assignment: ignore silently
        esac
        case "$key" in *[!A-Z0-9_]*) continue;; esac
        # strip one layer of surrounding quotes, trim trailing space
        val="${val%"${val##*[![:space:]]}"}"
        case "$val" in \"*\") val="${val#\"}"; val="${val%\"}";; \'*\') val="${val#\'}"; val="${val%\'}";; esac
        # THE ENVIRONMENT WINS: only fill the gap
        if [ -z "$(eval "printf %s \"\${$key+x}\"")" ]; then
            eval "export $key=\"\$val\""
        fi
    done < "$cfg"
    return 0
}
bric_load_config

# ---- site defaults (AFTER the config file: env > file > these) ----
: "${BRIC_ROLE:=tape}"
: "${BRIC_TAPE_HOME:=/opt/bric2/tape}"
: "${BRIC_TAPE_DB:=$BRIC_TAPE_HOME/db/tape_catalog.db}"
: "${BRIC_QNAP:=/mnt/data/bric}"
: "${BRIC_QNAP_MNT:=$(dirname "$BRIC_QNAP")}" # exact shared-bus mount point
: "${BRIC_REQUIRE_NFS_BUS:=0}"              # production configs set 1; tests/local sandboxes leave 0
: "${BRIC_TAPE_SQL_INIT:=$BRIC_TAPE_HOME/sql/tape_init.sql}"
if [ "${BRIC_CONFIG:-}" = none ]; then
    : "${BRIC_LOG_DIR:=${TMPDIR:-/tmp}/bric-test-log/${UID:-0}/primary}"
    : "${BRIC_LOG_FALLBACK_DIR:=${TMPDIR:-/tmp}/bric-test-log/${UID:-0}/fallback}"
else
    : "${BRIC_LOG_DIR:=/var/log/bric}"
    : "${BRIC_LOG_FALLBACK_DIR:=$BRIC_QNAP/.system/log/$(_bric_log_host)}"
fi
: "${BRIC_LOG_CAPTURE_STDIO:=1}"
: "${BRIC_LOG_GROUP:=bric}"
: "${BRIC_LOG_MAX_MESSAGE:=4000}"
: "${BRIC_REQUIRE_LOGGING:=1}"

# Review 31C: one canonical, configuration-authoritative singleton/work-fence namespace.
# The daemon also holds known historical namespaces during migration, but these are the defaults
# for new installations and explicit config files.
: "${BRIC_TAPE_LOCK:=/var/lock/bric_tape.lock}"
: "${BRIC_TAPE_WORK_LOCK:=${BRIC_TAPE_LOCK}.work}"

# Open a lock file without truncating it and verify that the pathname still resolves to the inode
# we opened. This is important for legacy names under /tmp: reject symlinks and files owned by a
# different uid instead of following/truncating an attacker-controlled path.
bric_tape_open_lock_fd() { # OUTVAR PATH
    local outvar="$1" path="$2" dir owner fd_owner path_id fd_id newfd created=0
    case "$path" in /*) ;; *) die "tape lock path must be absolute: $path";; esac
    [ ! -L "$path" ] || die "refusing symlink tape lock path: $path"
    dir="$(dirname "$path")"
    if [ ! -d "$dir" ]; then
        mkdir -p "$dir" || die "cannot create tape lock directory: $dir"
        chmod 0755 "$dir" 2>/dev/null || true
    fi
    if [ -e "$path" ]; then
        [ -f "$path" ] || die "tape lock path is not a regular file: $path"
        owner="$(stat -Lc %u -- "$path" 2>/dev/null || true)"
        [ "$owner" = "${EUID:-$(id -u)}" ] || die "refusing tape lock with unexpected owner uid=${owner:-unknown}: $path"
    else
        created=1
    fi
    unset newfd
    exec {newfd}>>"$path" || die "cannot open tape lock without truncation: $path"
    [ ! -L "$path" ] || { eval "exec ${newfd}>&-"; die "tape lock became a symlink while opening: $path"; }
    local proc_pid="${BASHPID:-$$}"
    path_id="$(stat -Lc '%d:%i' -- "$path" 2>/dev/null || true)"
    fd_id="$(stat -Lc '%d:%i' -- "/proc/$proc_pid/fd/$newfd" 2>/dev/null || true)"
    fd_owner="$(stat -Lc %u -- "/proc/$proc_pid/fd/$newfd" 2>/dev/null || true)"
    if [ -z "$path_id" ] || [ "$path_id" != "$fd_id" ] || [ "$fd_owner" != "${EUID:-$(id -u)}" ]; then
        eval "exec ${newfd}>&-" 2>/dev/null || true
        die "tape lock pathname/inode ownership changed while opening: $path"
    fi
    [ "$created" -eq 0 ] || chmod 0640 "$path" 2>/dev/null || true
    printf -v "$outvar" '%s' "$newfd"
}

bric_tape_close_fd_csv() { # comma-separated fd list
    local list="${1:-}" fd IFS=,
    [ -n "$list" ] || return 0
    for fd in $list; do
        case "$fd" in ''|*[!0-9]*) continue;; esac
        eval "exec ${fd}>&-" 2>/dev/null || true
    done
}
bric_close_daemon_singleton_fds() {
    # Empty means "already closed in this process/subshell".  Do not use `:-9` here: after a child
    # drops the inherited singleton descriptors Bash may reuse the same fd number for a later
    # redirection.  Re-closing a stale numeric list would then close Bash's new internal fd.
    local list="${BRIC_TAPE_SINGLETON_FDS-9}"
    bric_tape_close_fd_csv "$list"
    BRIC_TAPE_SINGLETON_FDS=""
    export BRIC_TAPE_SINGLETON_FDS
}
bric_close_daemon_work_fds() {
    local list="${BRIC_TAPE_WORK_FDS-7}"
    bric_tape_close_fd_csv "$list"
    BRIC_TAPE_WORK_FDS=""
    export BRIC_TAPE_WORK_FDS
}

# Known namespaces used by deployed pre-31C generations. Custom test/site lock paths do not
# automatically opt into these system paths; the production namespaces below do. Tests can set
# _BRIC_TEST_LEGACY_LOCK_DIR to exercise the migration barrier without touching /run or /tmp.
bric_tape_legacy_singleton_paths() { # selected canonical path
    local selected="$1" base="${_BRIC_TEST_LEGACY_LOCK_DIR:-}"
    if [ -n "$base" ]; then
        printf '%s\n' \
            "$base/var/lock/bric_tape.lock" \
            "$base/tmp/bric_tape.lock" \
            "$base/run/bric/bric-tape-daemon.lock" \
            "$base/run/bric/tape.lock"
        return 0
    fi
    case "$selected" in
        /var/lock/bric_tape.lock|/tmp/bric_tape.lock|/run/bric/bric-tape-daemon.lock|/run/bric/tape.lock)
            # Include the 31C canonical name as well as every historical deployed name. This matters
            # during in-place upgrades because /etc/bric/bric.conf is intentionally not rewritten:
            # a host may still select a historical /run path, yet it must contend with a fresh 31C
            # tree using the new /var/lock default.
            printf '%s\n' /var/lock/bric_tape.lock /tmp/bric_tape.lock /run/bric/bric-tape-daemon.lock /run/bric/tape.lock ;;
    esac
}
bric_tape_legacy_work_paths() { # selected singleton path; emit the generation work-fence set
    local selected="$1" base="${_BRIC_TEST_LEGACY_LOCK_DIR:-}"
    if [ -n "$base" ]; then
        printf '%s\n' \
            "$base/var/lock/bric_tape.lock.work" \
            "$base/tmp/bric_tape.lock.work" \
            "$base/run/bric/bric-tape-daemon.lock.work" \
            "$base/run/bric/tape.lock.work"
        return 0
    fi
    case "$selected" in
        /var/lock/bric_tape.lock|/tmp/bric_tape.lock|/run/bric/bric-tape-daemon.lock|/run/bric/tape.lock)
            printf '%s\n' /var/lock/bric_tape.lock.work /tmp/bric_tape.lock.work /run/bric/bric-tape-daemon.lock.work /run/bric/tape.lock.work ;;
    esac
}

require_cmds() { local c; for c in "$@"; do command -v "$c" >/dev/null 2>&1 || die "required command not found: $c"; done; }
require_role() {
    local want="$1"
    [ "${BRIC_ROLE:-}" = "$want" ] || die "host role mismatch: this command requires BRIC_ROLE=$want, got '${BRIC_ROLE:-unset}'"
}

# Validate the shared QNAP bus as NFS when the site configuration requires it.  Tests and
# deliberately local sandboxes leave BRIC_REQUIRE_NFS_BUS=0; production role configs set it to 1.
# The check is fail-closed because silently writing to a local directory after an NFS mount loss
# would split the bus between hosts and break marker/catalog consistency.
bric_bus_fstype() {
    local target="${1:-${BRIC_QNAP_MNT:-$(dirname "$BRIC_QNAP")}}" fs=""
    if command -v findmnt >/dev/null 2>&1; then
        fs="$(findmnt -n -T "$target" -o FSTYPE 2>/dev/null | head -1 || true)"
    fi
    [ -n "$fs" ] || fs="$(stat -f -c %T "$target" 2>/dev/null || true)"
    printf '%s' "$fs"
}
bric_require_nfs_bus() {
    [ "${BRIC_REQUIRE_NFS_BUS:-0}" = 1 ] || return 0
    local mnt="${BRIC_QNAP_MNT:-$(dirname "$BRIC_QNAP")}" fs
    require_cmds mountpoint stat
    mountpoint -q "$mnt" 2>/dev/null || die "shared bus mount $mnt is not mounted; refusing to use a local fallback directory"
    fs="$(bric_bus_fstype "$mnt")"
    case "$fs" in nfs|nfs4|nfs*) :;; *) die "shared bus mount $mnt has filesystem type '${fs:-unknown}', expected NFS";; esac
    [ -d "$BRIC_QNAP" ] || die "shared bus root $BRIC_QNAP does not exist under $mnt"
    [ -w "$BRIC_QNAP" ] || die "shared bus root $BRIC_QNAP is not writable by $(id -un 2>/dev/null || echo unknown)"
    bric_event INFO NFS_BUS_READY "mount=$mnt root=$BRIC_QNAP fstype=$fs"
}
# Strict charset for project/run_id parsed from QNAP directory names (anti path-injection on the bus).
valid_name() {
    local n="${1-}"
    [ "${#n}" -ge 1 ] && [ "${#n}" -le 160 ] || return 1
    case "$n" in [A-Za-z0-9]*) ;; *) return 1;; esac
    case "$n" in *[!A-Za-z0-9._-]*) return 1;; esac
    return 0
}

qnap_run_dir() { printf '%s/archive/%s/%s' "$BRIC_QNAP" "$1" "$2"; }

_bric_marker_event() { # dir name content
    local dir="$1" name="$2" content="${3:-}" level=INFO run project
    run="$(basename "$dir")"; project="$(basename "$(dirname "$dir")")"
    case "$name" in *.ERROR|run.DENIED|run.ABORTED) level=ERROR;; esac
    case "$content" in refused:*|*failed*|*FAIL*) level=ERROR;; esac
    BRIC_LOG_RUN_ID="$run" BRIC_LOG_PROJECT="$project" bric_event "$level" MARKER_PUBLISHED         "marker=$name body=$(printf '%s' "$content" | head -c 1000)"
}

marker_set() {
    local dir="$1" name="$2" content="${3:-}"
    mkdir -p "$dir"; printf '%s' "$content" > "$dir/.$name.tmp.$$"; mv -f "$dir/.$name.tmp.$$" "$dir/$name"
    _bric_marker_event "$dir" "$name" "$content"
}
marker_exists() { [ -e "$1/$2" ]; }
marker_read()   { cat "$1/$2" 2>/dev/null; }
# Atomic claim: win the race iff the rename succeeds (source vanishes for everyone else).
marker_claim()  {
    local dir="$1" src="$2" dst="$3"
    if mv "$dir/$src" "$dir/$dst" 2>/dev/null; then
        BRIC_LOG_RUN_ID="$(basename "$dir")" BRIC_LOG_PROJECT="$(basename "$(dirname "$dir")")"             bric_event INFO MARKER_CLAIMED "source=$src destination=$dst"
        return 0
    fi
    return 1
}

# ---- bus authentication (ECDSA P-256 over SHA-256), symmetric. Each side signs the markers it PUBLISHES with its own
# private key (BRIC_BUS_SIGN_KEY) and verifies the markers it CONSUMES with the peer's public key
# (BRIC_BUS_VERIFY_KEY). Tape: sign=tape-priv, verify=cluster-pub. The tape server's signing key is
# NOT a data secret (it cannot decrypt anything), so signing receipts keeps it keyless for data.
: "${BRIC_BUS_SIGN_KEY:=}"
: "${BRIC_BUS_VERIFY_KEY:=}"
bus_sign_enabled()   { [ -n "$BRIC_BUS_SIGN_KEY" ]   && [ -f "$BRIC_BUS_SIGN_KEY" ]; }
bus_verify_enabled() { [ -n "$BRIC_BUS_VERIFY_KEY" ] && [ -f "$BRIC_BUS_VERIFY_KEY" ]; }
marker_field() { awk -v k="$1" 'index($0,k"=")==1{print substr($0,length(k)+2); exit}' "$2" 2>/dev/null; }   # exact literal key match (robust vs metachars), first value only
# Domain separation (see cluster lib_common for the rationale): sign a canonical envelope binding a
# fixed domain tag + project/run location + marker name, so a .sig is non-transferable across markers.
_bus_sig_input() {   # dir name bodyfile -> writes the canonical to-sign bytes to stdout
    local dir="$1" name="$2" bodyfile="$3" run proj
    run="$(basename "$dir")"; proj="$(basename "$(dirname "$dir")")"
    printf 'BRIC-MARKER-V1\n%s/%s/%s\n' "$proj" "$run" "$name"
    cat "$bodyfile"
}
marker_set_signed() {   # dir name content -> publish <name>.sig (detached) THEN <name>
    local dir="$1" name="$2" content="${3:-}"
    mkdir -p "$dir"
    if bus_sign_enabled; then
        printf '%s' "$content" > "$dir/.$name.body.$$"
        _bus_sig_input "$dir" "$name" "$dir/.$name.body.$$" > "$dir/.$name.signin.$$"
        local sig err
        err="$dir/.$name.err.$$"
        # ECDSA P-256 over SHA-256 via `dgst` — LOCKSTEP with cluster/scripts/lib_common.sh.
        # Ed25519 has no command-line signing path on OpenSSL 1.1.1 (RHEL 8); `dgst -sha256`
        # behaves identically on 1.1.1 and 3.x. The signed input is unchanged.
        sig="$(openssl dgst -sha256 -sign "$BRIC_BUS_SIGN_KEY" "$dir/.$name.signin.$$" 2>"$err" | openssl base64 -A)" || sig=""
        rm -f "$dir/.$name.body.$$" "$dir/.$name.signin.$$"
        if [ -z "$sig" ]; then
            # Keep in LOCKSTEP with cluster/scripts/lib_common.sh: never swallow OpenSSL's reason.
            local why; why="$(tr '\n' ' ' < "$err" 2>/dev/null)"; rm -f "$err"
            die "bus signing failed for marker $name (BRIC_BUS_SIGN_KEY=$BRIC_BUS_SIGN_KEY, $(openssl version 2>/dev/null), key $(wc -c <"$BRIC_BUS_SIGN_KEY" 2>/dev/null || echo '?') bytes): ${why:-openssl produced no error text}"
        fi
        rm -f "$err"
        printf '%s' "$sig" > "$dir/.$name.sig.tmp.$$"; mv -f "$dir/.$name.sig.tmp.$$" "$dir/$name.sig"
    fi
    printf '%s' "$content" > "$dir/.$name.tmp.$$"; mv -f "$dir/.$name.tmp.$$" "$dir/$name"
    _bric_marker_event "$dir" "$name" "$content"
}
marker_verify() {   # dir name -> rc 0 ok (or disabled); rc 1 missing/bad signature
    bus_verify_enabled || return 0
    local dir="$1" name="$2" tmpsig signin
    [ -f "$dir/$name.sig" ] || { log "bus: REFUSED $name in $(basename "$dir") — no signature"; return 1; }
    tmpsig="$(mktemp)"
    openssl base64 -d -A -in "$dir/$name.sig" -out "$tmpsig" 2>/dev/null || { rm -f "$tmpsig"; log "bus: REFUSED $name — unreadable signature"; return 1; }
    signin="$(mktemp)"; _bus_sig_input "$dir" "$name" "$dir/$name" > "$signin"
    if openssl dgst -sha256 -verify "$BRIC_BUS_VERIFY_KEY" -signature "$tmpsig" "$signin" >/dev/null 2>&1; then
        rm -f "$tmpsig" "$signin"; return 0
    fi
    rm -f "$tmpsig" "$signin"; log "bus: REFUSED $name in $(basename "$dir") — BAD signature (forged or tampered)"; return 1
}
