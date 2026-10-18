#!/bin/bash
# Shared helpers for the CLUSTER side of BRIC Archive 2.0.
# Markers on the QNAP are written to *.tmp and atomically rename()d into place.


sql()  { sqlite3 -batch -cmd '.timeout 60000' "$BRIC_DB" "$1"; }
sqlc() { sqlite3 -batch -separator '|' -cmd '.timeout 60000' "$BRIC_DB" "$1"; }
# NUL/newline-safe rows: fields 0x1f, records 0x1e (read with: IFS=$'\x1f' read -r -d $'\x1e').
sqla() { sqlite3 -batch -cmd '.timeout 60000' "$BRIC_DB" ".mode ascii" "$1"; }
sql_quote() { printf "%s" "$1" | sed "s/'/''/g"; }
cfg()  { sql "SELECT value FROM config WHERE key='$(sql_quote "$1")';"; }
# Resolve the per-worker stream chunk target. `segment_target_bytes` remains a hard upper bound for
# compatibility with existing deployments/tests. Review 32B1 defaults both the segment hard cap and
# explicit worker target to 128 GB; 0/auto still derives aggregate_target/workers.
stream_worker_chunk_target() {  # aggregate_target workers configured_worker_target
    local target="$1" workers="$2" configured="${3:-}" out
    case "$target" in ''|*[!0-9]*|0) return 2;; esac
    case "$workers" in ''|*[!0-9]*|0) return 2;; esac
    case "$configured" in
        ''|auto|AUTO|0) out=$(( target / workers ));;
        *[!0-9]*) return 2;;
        *) out="$configured";;
    esac
    [ "$out" -gt 0 ] || out="$target"
    # Never let the new parallel-specific setting defeat the long-standing segment target. This is
    # what keeps reduced-target safety/e2e tests and explicit site tuning meaningful.
    [ "$out" -le "$target" ] || out="$target"
    printf '%s\n' "$out"
}
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
_bric_log_is_central_user_path() {
    local path="$1" os_user central_root
    [ "${EUID:-$(id -u)}" -ne 0 ] || return 1
    os_user="$(id -un 2>/dev/null || printf unknown)"
    central_root="${BRIC_USER_LOG_ROOT:-/var/log/bric/users}/$os_user"
    case "$path/" in
        "${central_root%/}/"*) return 0;;
        *) return 1;;
    esac
}
_bric_log_enforce_user_dir_acl() {
    local dir="$1" group="${BRIC_LOG_GROUP:-bric}"
    command -v setfacl >/dev/null 2>&1 || return 1
    setfacl -m "u::rwx,g::---,g:${group}:r-x,m::r-x,o::---" "$dir" >/dev/null 2>&1 || return 1
    setfacl -d -m "u::rwx,g::---,g:${group}:r-x,m::r-x,o::---" "$dir" >/dev/null 2>&1 || return 1
}
_bric_log_enforce_user_file_acl() {
    local path="$1" group="${BRIC_LOG_GROUP:-bric}"
    command -v setfacl >/dev/null 2>&1 || return 1
    setfacl -m "u::rw-,g::---,g:${group}:r--,m::r--,o::---" "$path" >/dev/null 2>&1 || return 1
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
    if _bric_log_is_central_user_path "$root"; then
        _bric_log_enforce_user_dir_acl "$root" || return 1
    fi
    probe="$root/.bric-write-test.$$"
    ( umask 0002; : > "$probe" ) 2>/dev/null || return 1
    rm -f "$probe" 2>/dev/null || true
    return 0
}
bric_log_init() {
    [ -n "${_BRIC_LOG_INITIALIZED:-}" ] && return 0
    _BRIC_LOG_INITIALIZED=1
    # Review 31E4: root/system components keep the system root. Normal users use a root-provisioned
    # central per-user tree and retain ~/.bric/log only as an emergency fallback.
    if [ -n "${BRIC_LOG_DIR:-}" ]; then
        _BRIC_LOG_PRIMARY_ROOT="$BRIC_LOG_DIR"
        _BRIC_LOG_FALLBACK_ROOT="${BRIC_LOG_FALLBACK_DIR:-$(_bric_log_default_fallback)}"
    elif [ "${EUID:-$(id -u)}" -ne 0 ]; then
        local os_user
        os_user="$(id -un 2>/dev/null || printf unknown)"
        _BRIC_LOG_PRIMARY_ROOT="${BRIC_USER_LOG_ROOT:-/var/log/bric/users}/$os_user"
        _BRIC_LOG_FALLBACK_ROOT="${BRIC_LOG_FALLBACK_DIR:-${HOME:-/tmp}/.bric/log}"
    else
        _BRIC_LOG_PRIMARY_ROOT=/var/log/bric
        _BRIC_LOG_FALLBACK_ROOT="${BRIC_LOG_FALLBACK_DIR:-$(_bric_log_default_fallback)}"
    fi
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
    case "$dir/" in
        "${HOME:-/nonexistent}/.bric/log/"*) chmod 0700 "$dir" 2>/dev/null || true; return 0;;
    esac
    if _bric_log_is_central_user_path "$dir"; then
        _bric_log_enforce_user_dir_acl "$dir" || return 1
        return 0
    fi
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
    ( umask 0077; printf '%s\n' "$line" >>"$path" ) 2>/dev/null || return 1
    if _bric_log_is_central_user_path "$path"; then
        _bric_log_enforce_user_file_acl "$path" || return 1
    else
        chmod 0640 "$path" 2>/dev/null || true
    fi
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
    ( umask 0077; printf '%s\n' "$line" >>"$path" ) 2>/dev/null || return 1
    if _bric_log_is_central_user_path "$path"; then
        _bric_log_enforce_user_file_acl "$path" || return 1
    else
        chmod 0640 "$path" 2>/dev/null || true
    fi
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
    if sql "INSERT INTO audit_log (actor,action,object,result,detail) VALUES ('$(sql_quote "$(bric_whoami)")','$(sql_quote "$action")','$(sql_quote "$object")','$(sql_quote "$result")','$(sql_quote "$detail")');" 2>"$err"; then
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
# Review 31E1 compatibility: user processes log centrally under a root-provisioned per-user tree.
# New onboarding exports BRIC_LOG_DIR explicitly.  Pre-31E1 users may still export only the private
# home fallback; derive the central primary from the effective OS identity BEFORE config loading so
# a system-wide BRIC_LOG_DIR=/var/log/bric cannot send an unprivileged user into root-only leaves.
if [ "${EUID:-$(id -u)}" -ne 0 ] && [ -z "${BRIC_LOG_DIR+x}" ]; then
    _bric_os_user="$(id -un 2>/dev/null || printf unknown)"
    export BRIC_LOG_DIR="${BRIC_USER_LOG_ROOT:-/var/log/bric/users}/$_bric_os_user"
    if [ -z "${BRIC_LOG_FALLBACK_DIR+x}" ] && [ -n "${HOME:-}" ]; then
        export BRIC_LOG_FALLBACK_DIR="$HOME/.bric/log"
    fi
    unset _bric_os_user
fi
bric_load_config

# ---- site defaults (AFTER the config file: env > file > these) ----
: "${BRIC_ROLE:=slurm}"
: "${BRIC_HOME:=/projects/bricsoftware/apps/bric2/cluster}"
: "${BRIC_DB:=$BRIC_HOME/db/cluster_catalog.db}"
: "${BRIC_QNAP:=/mnt/data/bric}"            # NFS-mounted QNAP staging bus
: "${BRIC_QNAP_MNT:=$(dirname "$BRIC_QNAP")}" # exact shared-bus mount point
: "${BRIC_REQUIRE_NFS_BUS:=0}"              # production configs set 1; tests/local sandboxes leave 0
# Key locations are deliberately separated:
#   - normal jobs use only the owner key in $HOME/.bric (or BRIC_USER_KEY_FILE);
#   - administrative escrow operations use BRIC_MASTER_KEY_FILE / BRIC_ADMIN_KEYS.
# BRIC_KEYS remains a compatibility alias for older tests/configurations, but production should not
# point it at a root-only directory in the system-wide config.
: "${BRIC_KEYS:=$HOME/.bric}"
: "${BRIC_USER_KEYS_DIR:=$BRIC_KEYS}"
: "${BRIC_USER_KEY_FILE:=}"
: "${BRIC_ADMIN_KEYS:=$BRIC_KEYS}"
: "${BRIC_MASTER_KEY_FILE:=}"
: "${BRIC_SQL_INIT:=$BRIC_HOME/sql/cluster_init.sql}"
# Cluster-private per-run scratch (NUL-safe member lists, etc.). MUST stay off the world-readable
# QNAP: it holds plaintext file names. Defaults next to the catalog DB, which is always writable.
: "${BRIC_RUNSTATE:=$(dirname "$BRIC_DB")/runstate}"
: "${BRIC_MODULE_INIT:=/etc/profile.d/modules.sh}"
: "${BRIC_SLURM_OPENSSL_MODULE:=openssl/3.5.7}"  # preferred module; runtime falls back dynamically
: "${BRIC_OPENSSL_MIN_MAJOR:=3}"

# Resolve the operational OpenSSL runtime without assuming that one module is usable by every UID.
# Policy:
#   1. Keep the current openssl when its major version is already >= BRIC_OPENSSL_MIN_MAJOR.
#   2. Otherwise initialize Environment Modules, purge only inside this BRIC process/job, inspect
#      `module avail`, and try compatible OpenSSL modules from newest to oldest.
#   3. BRIC_SLURM_OPENSSL_MODULE is merely the preferred first candidate. A site ACL may expose a
#      module in `module avail` but deny it to root; in that case the resolver continues with the
#      next compatible module instead of failing on the pinned name.
bric_openssl_version() {
    openssl version 2>/dev/null | awk 'NR==1 { print $2; exit }'
}

bric_openssl_version_ok() {
    local version major min_major="${BRIC_OPENSSL_MIN_MAJOR:-3}"
    version="$(bric_openssl_version 2>/dev/null || true)"
    major="${version%%.*}"
    case "$major" in ''|*[!0-9]*) return 1;; esac
    [ "$major" -ge "$min_major" ] 2>/dev/null
}

bric_init_modules() {
    type module >/dev/null 2>&1 && return 0
    [ -r "${BRIC_MODULE_INIT:-/etc/profile.d/modules.sh}" ] || return 1
    # shellcheck disable=SC1090
    . "${BRIC_MODULE_INIT:-/etc/profile.d/modules.sh}"
    type module >/dev/null 2>&1
}

bric_available_openssl_modules() {
    local listing min_major="${BRIC_OPENSSL_MIN_MAJOR:-3}"
    listing="$({ module -t avail openssl 2>&1 || module avail openssl 2>&1 || true; } \
        | sed -E $'s/\x1B\[[0-9;]*[[:alpha:]]//g')"
    printf '%s\n' "$listing" \
        | grep -Eio 'openssl/[0-9]+([.][0-9]+){0,3}([[:alnum:]_.+-]*)?' \
        | awk -F/ -v min="$min_major" '
            {
                v=$2; split(v,a,".");
                if ((a[1]+0) >= min && !seen[tolower($0)]++) print $0
            }' \
        | awk -F/ '{ version=$2; print version "\t" $0 }' \
        | sort -t $'\t' -k1,1Vr \
        | cut -f2-
}

bric_ensure_openssl3() { # optional argument: purge
    local mode="${1:-}" preferred="${BRIC_SLURM_OPENSSL_MODULE:-}" candidate version
    local -a candidates=()
    local -A seen=()

    BRIC_OPENSSL_MODULE_LOADED=0
    BRIC_OPENSSL_MODULE_SELECTED=""
    BRIC_OPENSSL_ERROR=""

    if bric_openssl_version_ok; then
        BRIC_OPENSSL_VERSION="$(bric_openssl_version)"
        BRIC_OPENSSL_MODULE_SELECTED="current"
        export BRIC_OPENSSL_VERSION BRIC_OPENSSL_MODULE_SELECTED BRIC_OPENSSL_MODULE_LOADED
        return 0
    fi

    if ! bric_init_modules; then
        BRIC_OPENSSL_ERROR="OpenSSL >=${BRIC_OPENSSL_MIN_MAJOR:-3} unavailable and Environment Modules init not found/readable: ${BRIC_MODULE_INIT:-/etc/profile.d/modules.sh}"
        export BRIC_OPENSSL_ERROR
        return 1
    fi

    # The wrapper/job is a child process, so purging here cannot alter the caller's login shell.
    if [ "$mode" = purge ]; then
        module purge >/dev/null 2>&1 || {
            BRIC_OPENSSL_ERROR="initial module purge failed while resolving OpenSSL"
            export BRIC_OPENSSL_ERROR
            return 1
        }
        # A purge can expose a sufficiently new system OpenSSL; avoid loading any module in that case.
        if bric_openssl_version_ok; then
            BRIC_OPENSSL_VERSION="$(bric_openssl_version)"
            BRIC_OPENSSL_MODULE_SELECTED="system-after-purge"
            export BRIC_OPENSSL_VERSION BRIC_OPENSSL_MODULE_SELECTED BRIC_OPENSSL_MODULE_LOADED
            return 0
        fi
    fi

    [ -z "$preferred" ] || candidates+=("$preferred")
    while IFS= read -r candidate; do
        [ -z "$candidate" ] || candidates+=("$candidate")
    done < <(bric_available_openssl_modules)

    for candidate in "${candidates[@]}"; do
        [ -n "$candidate" ] || continue
        case "${seen[$candidate]+x}" in x) continue;; esac
        seen[$candidate]=1
        # A failed or partially applied module load must not contaminate the next candidate.
        [ "$mode" != purge ] || module purge >/dev/null 2>&1 || continue
        module load "$candidate" >/dev/null 2>&1 || continue
        if bric_openssl_version_ok; then
            version="$(bric_openssl_version)"
            BRIC_OPENSSL_VERSION="$version"
            BRIC_OPENSSL_MODULE_SELECTED="$candidate"
            BRIC_OPENSSL_MODULE_LOADED=1
            export BRIC_OPENSSL_VERSION BRIC_OPENSSL_MODULE_SELECTED BRIC_OPENSSL_MODULE_LOADED
            return 0
        fi
    done

    [ "$mode" != purge ] || module purge >/dev/null 2>&1 || true
    BRIC_OPENSSL_ERROR="no loadable OpenSSL module with major version >=${BRIC_OPENSSL_MIN_MAJOR:-3} was found via 'module avail openssl'"
    export BRIC_OPENSSL_ERROR
    return 1
}
if [ "${BRIC_CONFIG:-}" = none ]; then
    : "${BRIC_LOG_DIR:=${TMPDIR:-/tmp}/bric-test-log/${UID:-0}/primary}"
    : "${BRIC_LOG_FALLBACK_DIR:=${TMPDIR:-/tmp}/bric-test-log/${UID:-0}/fallback}"
else
    : "${BRIC_LOG_DIR:=/var/log/bric}"
    : "${BRIC_LOG_FALLBACK_DIR:=$BRIC_HOME/log/fallback/$(_bric_log_host)}"
fi
: "${BRIC_LOG_CAPTURE_STDIO:=1}"
: "${BRIC_LOG_GROUP:=bric}"
: "${BRIC_LOG_ADMIN_GROUP:=bric}"
: "${BRIC_USER_LOG_ROOT:=/var/log/bric/users}"
: "${BRIC_LOG_MAX_MESSAGE:=4000}"
: "${BRIC_REQUIRE_LOGGING:=1}"


# ---------------------------------------------------------------------------------------------
# Event notification: ONE canonical implementation (regola: mai una seconda implementazione).
#   bric_notify EVENT OWNER RUN_ID "detail"
# Does two things, in this order:
#   1. Appends a structured, machine-parseable line to the event log (for root + cron digestion):
#        ISO8601|EVENT|owner|run_id|host|detail|mail=sent/skipped/failed/none
#      Log path: $BRIC_NOTIFY_LOG, default $BRIC_LOG_DIR/notifications.log; if that is not
#      writable, it follows the same configured NFS fallback as the operational logs.
#   2. Best-effort email to <owner>@$BRIC_MAIL_DOMAIN (default ku.dk) via `mail` or `sendmail`.
#      BRIC_NOTIFY_MAIL: off (DEFAULT) | auto. Mail is opt-in — "l'opzionale resta opzionale" —
#      so test suites and dev sessions never spam real mailboxes; production enables it with one
#      line (BRIC_NOTIFY_MAIL=auto) in the service environment. Log lines are ALWAYS written.
# GUARANTEE: bric_notify NEVER fails the calling operation — always returns 0. A broken mailer or
# an unwritable log must never take down an archive or a restore.
# ---------------------------------------------------------------------------------------------
bric_notify() {
    local event="$1" owner="${2:-}" run_id="${3:-}" detail="${4:-}" mail_state="none"
    detail="$(printf '%s' "$detail" | tr '\n|' ' ;' | head -c 500)"

    # -- email (best-effort, before logging so the line records the outcome) --
    if [ "${BRIC_NOTIFY_MAIL:-off}" != off ] && [ -n "$owner" ]; then
        local to="${owner}@${BRIC_MAIL_DOMAIN:-ku.dk}"
        local subj="[BRIC Archive] $event ${run_id:+$run_id}"
        local body="Event:   $event
Run:     ${run_id:-–}
Owner:   $owner
Host:    $(hostname 2>/dev/null || echo '?')
Time:    $(date -u +%Y-%m-%dT%H:%M:%SZ)
Detail:  ${detail:-–}

This is an automated notification from BRIC Archive 2.0."
        if command -v mail >/dev/null 2>&1; then
            printf '%s\n' "$body" | mail -s "$subj" "$to" >/dev/null 2>&1 && mail_state="sent" || mail_state="failed"
        elif command -v sendmail >/dev/null 2>&1; then
            printf 'To: %s\nSubject: %s\n\n%s\n' "$to" "$subj" "$body" | sendmail -t >/dev/null 2>&1 && mail_state="sent" || mail_state="failed"
        else
            mail_state="skipped"     # no mailer on this host: the log line still records the event
        fi
    fi

    # -- structured log line (root-readable; David's cron will digest this file) --
    # Every statement here is ARMORED (|| true): this function runs inside scripts with `set -e`
    # invoked by NON-ROOT users, and e.g. `mkdir -p /var/log/bric` legitimately fails for them.
    # An unprotected line would kill the calling backup/restore — the exact opposite of the
    # guarantee. (Bug found in production: every run died right after "reservation GRANTED".)
    if [ -z "${_BRIC_NOTIFY_PATH:-}" ]; then
        local cand
        bric_log_init
        for cand in "${BRIC_NOTIFY_LOG:-${BRIC_LOG_DIR:-/var/log/bric}/notifications.log}"                     "${_BRIC_LOG_FALLBACK_ROOT:-$(_bric_log_default_fallback)}/notifications.log"; do
            mkdir -p "$(dirname "$cand")" 2>/dev/null || true
            if ( umask 0000; : >> "$cand"; chmod 0666 "$cand" 2>/dev/null || true ) 2>/dev/null; then
                _BRIC_NOTIFY_PATH="$cand"; break
            fi
        done
        [ -n "${_BRIC_NOTIFY_PATH:-}" ] || _BRIC_NOTIFY_PATH=/dev/null
    fi
    printf '%s|%s|%s|%s|%s|%s|mail=%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$event" "${owner:--}" "${run_id:--}" \
        "$(hostname 2>/dev/null || echo '?')" "${detail:--}" "$mail_state" \
        >> "$_BRIC_NOTIFY_PATH" 2>/dev/null || true
    BRIC_LOG_RUN_ID="$run_id" BRIC_LOG_RC=0 bric_event INFO NOTIFY         "event=$event owner=$owner mail=$mail_state detail=$detail"
    log "notify: $event ${run_id:+run=$run_id }${owner:+owner=$owner }(mail=$mail_state)"
    return 0
}

bric_slurm_logdir() {
    local cand probe
    bric_log_init
    for cand in "${BRIC_SLURM_LOGDIR:-}" "${BRIC_LOG_DIR:-/var/log/bric}/slurm"                 "${_BRIC_LOG_FALLBACK_ROOT:-$(_bric_log_default_fallback)}/slurm"; do
        [ -n "$cand" ] || continue
        mkdir -p "$cand" 2>/dev/null || continue
        probe="$cand/.write-test.$$"
        if ( umask 0027; : >"$probe" ) 2>/dev/null; then
            rm -f "$probe" 2>/dev/null || true
            printf '%s' "$cand"; return 0
        fi
    done
    die "no writable Slurm output directory (BRIC_SLURM_LOGDIR / primary log / NFS fallback)"
}

run_status_event() { # run project status detail
    local run="$1" project="$2" status="$3" detail="${4:-}" level=INFO
    case "$status" in FAILED|DENIED|CANCELLED) level=ERROR;; esac
    BRIC_LOG_RUN_ID="$run" BRIC_LOG_PROJECT="$project" bric_event "$level" RUN_STATUS "status=$status detail=$detail"
}
chunk_status_event() { # run project chunk status detail
    local run="$1" project="$2" chunk="$3" status="$4" detail="${5:-}" level=INFO
    case "$status" in ERROR|FAILED) level=ERROR;; esac
    BRIC_LOG_RUN_ID="$run" BRIC_LOG_PROJECT="$project" BRIC_LOG_CHUNK="$chunk"         bric_event "$level" CHUNK_STATUS "status=$status detail=$detail"
}

# GNU *sum utilities prefix the digest with '\' when a filename needs escaping (for example a
# newline). Strip only that output marker; a SHA-256 digest itself is hexadecimal and can never begin
# with a backslash. This keeps checksum verification filename-safe without parsing the filename field.
sha256_file() {
    local line hash
    line="$(sha256sum -- "$1")" || return 1
    hash="${line%% *}"
    hash="${hash#\\}"
    printf '%s' "$hash"
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
# Bytes currently staged on the QNAP bus = the chunk_*.enc blobs physically present. The tape daemon
# removes each blob the instant both tape copies are VERIFIED, so this is the real, live bus usage
# (the cluster catalog's chunks.state only reaches DONE later, in bric-finalize, so it is NOT a valid
# in-flight signal during production). Used by both producer sliding-window gates (bric-chunk.sh and bric-stream-gate.sh).
qnap_inflight_bytes() {
    # Count both fully-published ciphertext and in-progress .enc.part files.  Review 31 counted only
    # chunk_*.enc, which is safe for a single producer but underestimates occupancy once multiple
    # workers can write .enc.part files concurrently.  A disappearing file after tape verification is
    # the expected race handled by -ignore_readdir_race; other NFS errors stay visible/fail-closed.
    find "$BRIC_QNAP" -ignore_readdir_race -type f \
        \( -name 'chunk_*.enc' -o -name 'chunk_*.enc.part' \) -printf '%s\n' |
        awk '{s+=$1} END{print s+0}'
}

qnap_free_bytes() { # current filesystem free bytes for BRIC_QNAP_MNT/BRIC_QNAP
    local target="${BRIC_QNAP_MNT:-$BRIC_QNAP}" avail
    require_cmds df awk
    avail="$(df -P -B1 "$target" 2>/dev/null | awk 'NR==2 {print $4}')" || return 1
    case "$avail" in ''|*[!0-9]*) return 1;; esac
    printf '%s\n' "$avail"
}

qnap_parallel_preflight() { # logical_bytes workers worker_chunk_bytes max_inflight
    # Fail before tape reservation if current QNAP free space cannot contain the worst local staging
    # window for this run.  max_inflight bounds published .enc files; each worker may additionally
    # have one full .enc.part in progress.  Cap the estimate by this operation's logical scope and add
    # 5% framing/headroom.  df already reflects blobs belonging to other active runs.
    local logical="$1" workers="$2" worker_target="$3" maxin="$4" free slots window scope required
    for v in "$logical" "$workers" "$worker_target" "$maxin"; do
        case "$v" in ''|*[!0-9]*) return 2;; esac
    done
    [ "$workers" -ge 1 ] && [ "$worker_target" -gt 0 ] && [ "$maxin" -ge 1 ] || return 2
    slots=$(( maxin + workers ))
    window=$(( slots * worker_target ))
    scope=$logical
    [ "$scope" -gt "$window" ] && scope=$window
    required=$(( scope + scope / 20 ))
    free="$(qnap_free_bytes)" || die "cannot determine free bytes on QNAP staging filesystem before reservation"
    BRIC_LOG_BYTES="$required" bric_event INFO QNAP_SPACE_PREFLIGHT         "free_bytes=$free required_bytes=$required logical_bytes=$logical workers=$workers worker_target=$worker_target max_inflight=$maxin slots=$slots"
    [ "$free" -ge "$required" ] || die "insufficient QNAP staging space before reservation: free=$free bytes, need at least $required bytes for parallel window (workers=$workers max_inflight=$maxin worker_target=$worker_target)"
    log "QNAP staging preflight passed: free=$free required=$required bytes (workers=$workers max_inflight=$maxin)"
}

qnap_probe_failure_limit() {
    # Consecutive failed global-budget probes tolerated before the producer aborts.  While the probe
    # is unknown, producers remain fail-closed (they stage no additional ciphertext) and retry on the
    # normal poll interval.  Environment wins over DB config; no schema migration is required.
    local n="${BRIC_QNAP_PROBE_MAX_FAILURES:-}"
    [ -n "$n" ] || n="$(cfg qnap_probe_max_failures)"
    case "$n" in ''|*[!0-9]*|0) n=12;; esac
    printf '%s\n' "$n"
}

# --- global producer admission (the network is the real bottleneck) -------------------------------
# Only `max_concurrent_producers` backups may be in the PRODUCING phase (tar -> QNAP) at once,
# system-wide. This call BLOCKS until this run may produce, then atomically marks it PRODUCING. The
# slot is released when the run leaves PRODUCING (bric-finalize.sh sets DRAINING as its first action),
# so the next backup streams to the QNAP while this run's already-produced blobs drain to tape.
# (Bus SPACE is bounded separately by the per-chunk sliding window + qnap_budget_bytes gate in
# bric-chunk.sh; this gate only limits how many runs produce at once.)
# Tunables: BRIC_PRODUCER_POLL (s, default 5), BRIC_PRODUCER_WAIT (s, default 86400 then give up).
producer_slot_acquire() {
    local me="$1" maxp poll maxwait t0 res waited q
    maxp="$(cfg max_concurrent_producers)"; case "$maxp" in ''|*[!0-9]*) maxp=1;; esac; [ "$maxp" -lt 1 ] && maxp=1
    poll="${BRIC_PRODUCER_POLL:-5}";        case "$poll" in ''|*[!0-9]*) poll=5;; esac; [ "$poll" -lt 1 ] && poll=1
    maxwait="${BRIC_PRODUCER_WAIT:-86400}"; case "$maxwait" in ''|*[!0-9]*) maxwait=86400;; esac
    t0="$(date +%s)"; q="$(sql_quote "$me")"
    while :; do
        # Atomic: under BEGIN IMMEDIATE the read of the PRODUCING count and our own transition cannot
        # interleave with another acquirer, so at most maxp runs ever hold PRODUCING simultaneously.
        res="$(sqlite3 -batch -cmd '.timeout 60000' "$BRIC_DB" "
            BEGIN IMMEDIATE;
            UPDATE runs SET status='PRODUCING'
              WHERE run_id='$q' AND status IN ('RESERVED','PRODUCING')
                AND (SELECT COUNT(*) FROM runs WHERE status='PRODUCING' AND run_id<>'$q') < $maxp;
            SELECT CASE WHEN (SELECT status FROM runs WHERE run_id='$q')='PRODUCING' THEN 'OK' ELSE 'WAIT' END;
            COMMIT;")"
        [ "$res" = OK ] && { log "producer slot acquired ($me)"; return 0; }
        waited=$(( $(date +%s) - t0 ))
        [ "$waited" -ge "$maxwait" ] && die "timed out after ${maxwait}s waiting for a producer slot"
        producer_slot_reclaim_stale "$q"
        log "another backup is streaming to the QNAP; waiting for a producer slot…"
        sleep "$poll"
    done
}

# Best-effort: free a slot wedged by a producer whose SLURM array job no longer exists (node/job died
# before bric-finalize ran). Requires squeue; a no-op without it (local mode / sim), where finalize's
# afterany dependency already guarantees the slot is released.
producer_slot_reclaim_stale() {
    command -v squeue >/dev/null 2>&1 || return 0
    local me="$1" rid aid
    sql "SELECT run_id||'|'||COALESCE(slurm_array_job,'') FROM runs WHERE status='PRODUCING' AND run_id<>'$me';" \
      | while IFS='|' read -r rid aid; do
            [ -n "$rid" ] && [ -n "$aid" ] || continue
            if [ -z "$(squeue -h -j "$aid" 2>/dev/null)" ]; then
                sql "UPDATE runs SET status='FAILED', error='producer slot reclaimed: array job $aid not running' WHERE run_id='$(sql_quote "$rid")' AND status='PRODUCING';"
                log "reclaimed wedged producer slot from $rid (array $aid gone)"
            fi
        done
    return 0
}

# Reject names that are unsafe in a filesystem path or as a marker directory. project/owner/run_id
# all end up in QNAP paths (where SQL escaping does not protect us), so enforce a strict charset:
#   ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$   (also rejects "..", leading dot/dash, slashes, spaces, ctrl)
valid_name() {
    local n="${1-}"
    [ "${#n}" -ge 1 ] && [ "${#n}" -le 128 ] || return 1
    case "$n" in [A-Za-z0-9]*) ;; *) return 1;; esac
    case "$n" in *[!A-Za-z0-9._-]*) return 1;; esac
    return 0
}

# ---- QNAP layout + atomic markers ----
_bric_marker_event() { # dir name content
    local dir="$1" name="$2" content="${3:-}" level=INFO run project
    run="$(basename "$dir")"; project="$(basename "$(dirname "$dir")")"
    case "$name" in *.ERROR|run.DENIED|run.ABORTED) level=ERROR;; esac
    case "$content" in refused:*|*failed*|*FAIL*) level=ERROR;; esac
    BRIC_LOG_RUN_ID="$run" BRIC_LOG_PROJECT="$project" bric_event "$level" MARKER_PUBLISHED         "marker=$name body=$(printf '%s' "$content" | head -c 1000)"
}

qnap_run_dir() { printf '%s/archive/%s/%s' "$BRIC_QNAP" "$1" "$2"; }   # project, run_id
qnap_restore_dir() { printf '%s/restore/%s/%s' "$BRIC_QNAP" "$1" "$2"; }


# Remove a terminal run directory from the shared QNAP bus only after the cluster catalog records a
# terminal state and the corresponding signed tape receipt has been observed. The bus is transport,
# not archival storage: durable metadata lives in the cluster/tape catalogs and all payload/artifact
# copies live on tape. BRIC_KEEP_TERMINAL_BUS=1 is an operator debugging escape hatch.
bus_cleanup_run_dir() {  # project run_id [expected_status]
    local project="$1" run_id="$2" expected="${3:-}" rd status marker parent
    [ "${BRIC_KEEP_TERMINAL_BUS:-0}" = 1 ] && { log "bus cleanup retained by BRIC_KEEP_TERMINAL_BUS=1: $run_id"; return 0; }
    valid_name "$project" || { warn_log "bus cleanup refused invalid project '$project'"; return 1; }
    case "$run_id" in "$project"__*) :;; *) warn_log "bus cleanup refused run/project mismatch: $run_id / $project"; return 1;; esac
    rd="$(qnap_run_dir "$project" "$run_id")"
    case "$rd" in "$BRIC_QNAP"/archive/"$project"/"$run_id") :;; *) warn_log "bus cleanup path binding failed: $rd"; return 1;; esac
    status="$(sql "SELECT status FROM runs WHERE run_id='$(sql_quote "$run_id")' AND project_name='$(sql_quote "$project")';" 2>/dev/null || true)"
    [ -n "$status" ] || { warn_log "bus cleanup skipped unknown run: $run_id"; return 1; }
    [ -z "$expected" ] || [ "$status" = "$expected" ] || { warn_log "bus cleanup status changed for $run_id: expected=$expected actual=$status"; return 1; }
    case "$status" in
        CLOSED) marker=run.CLOSED;;
        DENIED) marker=run.DENIED;;
        FAILED|CANCELLED) marker=run.ABORT_DONE;;
        *) warn_log "bus cleanup skipped non-terminal run $run_id (status=$status)"; return 1;;
    esac
    [ -d "$rd" ] || return 0
    [ -f "$rd/$marker" ] || { warn_log "bus cleanup deferred for $run_id: missing terminal receipt $marker"; return 1; }
    marker_verify "$rd" "$marker" || { warn_log "bus cleanup deferred for $run_id: invalid signature on $marker"; return 1; }
    rm -rf -- "$rd" 2>/dev/null || true
    if [ -e "$rd" ]; then
        warn_log "bus cleanup FAILED for $run_id: directory still exists: $rd"
        return 1
    fi
    parent="$(dirname "$rd")"
    rmdir -- "$parent" 2>/dev/null || true
    log "bus cleanup complete: removed terminal $status run $run_id"
    return 0
}

bus_cleanup_restore_dir() {  # request_dir
    local rdir="$1" parent
    [ "${BRIC_KEEP_RESTORE_BUS:-0}" = 1 ] && { log "restore bus cleanup retained by BRIC_KEEP_RESTORE_BUS=1: $rdir"; return 0; }
    case "$rdir" in "$BRIC_QNAP"/restore/*/*) :;; *) warn_log "restore bus cleanup refused unsafe path: $rdir"; return 1;; esac
    rm -rf -- "$rdir" 2>/dev/null || true
    [ ! -e "$rdir" ] || { warn_log "restore bus cleanup FAILED: $rdir remains"; return 1; }
    parent="$(dirname "$rdir")"
    rmdir -- "$parent" 2>/dev/null || true
    return 0
}

marker_set() {   # dir name content
    local dir="$1" name="$2" content="${3:-}"
    mkdir -p "$dir"
    printf '%s' "$content" > "$dir/.$name.tmp.$$"
    mv -f "$dir/.$name.tmp.$$" "$dir/$name"      # atomic publish
    _bric_marker_event "$dir" "$name" "$content"
}

# ---- bus authentication (ECDSA P-256 over SHA-256), symmetric. Each side signs the markers it PUBLISHES with its own
# private key (BRIC_BUS_SIGN_KEY) and verifies the markers it CONSUMES with the peer's public key
# (BRIC_BUS_VERIFY_KEY). Cluster: sign=cluster-priv, verify=tape-pub. A signing key is not a data
# secret, so the tape server can sign its receipts and still never hold a key that decrypts data.
# When the relevant key is unset, that direction is a no-op (unsigned), so deployments upgrade safely.
: "${BRIC_BUS_SIGN_KEY:=}"
: "${BRIC_BUS_VERIFY_KEY:=}"
bus_sign_enabled()   { [ -n "$BRIC_BUS_SIGN_KEY" ]   && [ -f "$BRIC_BUS_SIGN_KEY" ]; }
bus_verify_enabled() { [ -n "$BRIC_BUS_VERIFY_KEY" ] && [ -f "$BRIC_BUS_VERIFY_KEY" ]; }
marker_field() { awk -v k="$1" 'index($0,k"=")==1{print substr($0,length(k)+2); exit}' "$2" 2>/dev/null; }   # exact literal key match (robust vs metachars), first value only
# Domain separation: the bytes we sign are NOT the bare marker body but a canonical envelope that binds
# a fixed domain tag + the marker's location (project/run) + its name. This makes a signature
# non-transferable: a valid .sig for one marker cannot be replayed onto a different marker name or a
# different run dir, even if the bodies are byte-identical. Verify rebuilds the prefix from the file's
# REAL location, so relocation breaks the signature cryptographically (not just via the body fields).
_bus_sig_input() {   # dir name bodyfile -> writes the canonical to-sign bytes to stdout
    local dir="$1" name="$2" bodyfile="$3" run proj
    run="$(basename "$dir")"; proj="$(basename "$(dirname "$dir")")"
    printf 'BRIC-MARKER-V1\n%s/%s/%s\n' "$proj" "$run" "$name"
    cat "$bodyfile"
}
marker_set_signed() {   # dir name content  -> publishes <name>.sig (detached) THEN <name>
    local dir="$1" name="$2" content="${3:-}"
    mkdir -p "$dir"
    if bus_sign_enabled; then
        printf '%s' "$content" > "$dir/.$name.body.$$"
        _bus_sig_input "$dir" "$name" "$dir/.$name.body.$$" > "$dir/.$name.signin.$$"
        local sig err
        err="$dir/.$name.err.$$"
        # ECDSA P-256 over SHA-256 via `dgst`. NOT Ed25519: `pkeyutl -rawin` exists only from
        # OpenSSL 3.0, and supekgate (RHEL 8) ships 1.1.1k where Ed25519 has NO command-line
        # signing path at all. `dgst -sha256 -sign` behaves identically on 1.1.1 and 3.x.
        # The signed input (_bus_sig_input: domain tag + project/run/marker + body) is unchanged,
        # so every anti-replay/relocation property is preserved — only the primitive differs.
        sig="$(openssl dgst -sha256 -sign "$BRIC_BUS_SIGN_KEY" "$dir/.$name.signin.$$" 2>"$err" | openssl base64 -A)" || sig=""
        rm -f "$dir/.$name.body.$$" "$dir/.$name.signin.$$"
        if [ -z "$sig" ]; then
            # Never swallow the reason: without it "bus signing failed" is undiagnosable, and the
            # causes are environmental (OpenSSL lacking the primitive, FIPS refusing it,
            # unreadable/empty key). Surface OpenSSL's own words plus the key's state.
            local why; why="$(tr '\n' ' ' < "$err" 2>/dev/null)"; rm -f "$err"
            die "bus signing failed for marker $name (BRIC_BUS_SIGN_KEY=$BRIC_BUS_SIGN_KEY, $(openssl version 2>/dev/null), key $(wc -c <"$BRIC_BUS_SIGN_KEY" 2>/dev/null || echo '?') bytes): ${why:-openssl produced no error text}"
        fi
        rm -f "$err"
        printf '%s' "$sig" > "$dir/.$name.sig.tmp.$$"; mv -f "$dir/.$name.sig.tmp.$$" "$dir/$name.sig"
    fi
    printf '%s' "$content" > "$dir/.$name.tmp.$$"
    mv -f "$dir/.$name.tmp.$$" "$dir/$name"      # publish marker AFTER its signature
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
# Production hardening: when config require_bus_signing=1, refuse to operate unsigned/unverified.
enforce_bus_signing() {
    [ "$(cfg require_bus_signing 2>/dev/null)" = "1" ] || return 0
    bus_sign_enabled   || die "require_bus_signing=1 but BRIC_BUS_SIGN_KEY is unset/missing — refusing to publish unsigned bus markers"
    bus_verify_enabled || die "require_bus_signing=1 but BRIC_BUS_VERIFY_KEY is unset/missing — refusing to trust unverified tape receipts"
}
marker_exists() { [ -e "$1/$2" ]; }
marker_read()   { cat "$1/$2" 2>/dev/null; }
marker_wait()   { # dir name1 name2 timeout_s  -> echoes the first marker that appears, or "" on timeout
    local dir="$1" a="$2" b="$3" t="${4:-3600}" i=0
    while [ "$i" -lt "$t" ]; do
        [ -e "$dir/$a" ] && { echo "$a"; return 0; }
        [ -n "$b" ] && [ -e "$dir/$b" ] && { echo "$b"; return 0; }
        sleep 1; i=$((i+1))
    done
    return 1
}

# ---- key derivation (cluster only; the tape server never does this) ----
# Two purpose-bound keys are derived from the user's secret. Documented once, recoverable by hand.
derive_keys() {
    local user_key="$1"
    ENC_KEY=$(printf '%s:encryption'     "$user_key" | sha256sum | awk '{print $1}')
    HMAC_KEY=$(printf '%s:authentication' "$user_key" | sha256sum | awk '{print $1}')
}
user_key_file() {
    local who="$1" runtime_user
    runtime_user="$(bric_whoami)"
    if [ -n "${BRIC_USER_KEY_FILE:-}" ] && [ "$who" = "$runtime_user" ]; then
        printf '%s' "$BRIC_USER_KEY_FILE"
    else
        printf '%s/%s_user_key.txt' "${BRIC_USER_KEYS_DIR:-$BRIC_KEYS}" "$who"
    fi
}
master_key_file() {
    if [ -n "${BRIC_MASTER_KEY_FILE:-}" ]; then printf '%s' "$BRIC_MASTER_KEY_FILE";
    else printf '%s/master.key' "${BRIC_ADMIN_KEYS:-$BRIC_KEYS}"; fi
}

# Key escrow (break-glass): wrap a user key with the institution master key (base64-armored), and the
# inverse. Stored in users.key_escrow so an admin holding the master key can recover any user's key.
# Master-key escrow wrap/unwrap with Encrypt-then-MAC: the wrapped user key is authenticated by an
# HMAC-SHA256 (master-derived, domain-separated key) verified BEFORE decryption, so an attacker with
# write access to the catalog cannot silently corrupt a wrapped key and have it surface only at
# break-glass. Format: "v2:<hmac_hex>:<ciphertext_b64>". Legacy bare-armored escrows still decrypt.
master_hmac_key() { printf '%s:escrow-auth' "$(cat "$1")" | sha256sum | awk '{print $1}'; }   # $1=master key file
master_wrap()   {   # $1=mkfile ; stdin plaintext -> stdout "v2:<hmac>:<ct_b64>"
    local mk="$1" ct hmac
    ct="$(openssl enc -aes-256-cbc -pbkdf2 -iter 10000 -a -A -salt -pass file:"$mk")" || return 1
    hmac="$(printf '%s' "$ct" | openssl dgst -sha256 -hmac "$(master_hmac_key "$mk")" | awk '{print $NF}')"
    printf 'v2:%s:%s' "$hmac" "$ct"
}
master_unwrap() {   # $1=mkfile ; stdin "v2:<hmac>:<ct_b64>" or legacy bare-armored -> stdout plaintext
    local mk="$1" blob hmac ct want
    blob="$(cat)"
    case "$blob" in
        v2:*)
            blob="${blob#v2:}"; hmac="${blob%%:*}"; ct="${blob#*:}"
            want="$(printf '%s' "$ct" | openssl dgst -sha256 -hmac "$(master_hmac_key "$mk")" | awk '{print $NF}')"
            [ "$hmac" = "$want" ] || { log "ESCROW HMAC verification FAILED — wrapped key is tampered/corrupt; refusing to decrypt"; return 1; }
            printf '%s' "$ct" | openssl enc -d -aes-256-cbc -pbkdf2 -iter 10000 -a -A -pass file:"$mk"
            ;;
        *)  # legacy pre-HMAC escrow (multi-line -a armor): decrypt as-is (unauthenticated)
            printf '%s' "$blob" | openssl enc -d -aes-256-cbc -pbkdf2 -iter 10000 -a -pass file:"$mk"
            ;;
    esac
}
user_is_escrowed() { [ -n "$(sql "SELECT 1 FROM users WHERE username='$(sql_quote "$1")';")" ]; }

# Cluster-private run scratch. chunk_member_list holds the chunk's tar members as a NUL-separated
# list (newline-safe for hostile file names); produced by bric-plan, consumed by bric-chunk.
run_state_dir()     { printf '%s/%s' "$BRIC_RUNSTATE" "$1"; }                       # run_id
chunk_member_list() { printf '%s/%s/chunk_%04d.members' "$BRIC_RUNSTATE" "$1" "$2"; } # run_id, chunk_no

# Resolve the calling person (designated archive user).
# Runtime identity is the real OS/NSS account. BRIC_USER may repeat that identity, but an
# unprivileged caller cannot impersonate another archive owner merely by exporting an environment
# variable. Root and explicitly trusted test/service contexts retain an opt-in override.
bric_whoami() {
    local os requested uid
    os="$(id -un 2>/dev/null || whoami)"
    uid="$(id -u 2>/dev/null || printf 1)"
    requested="${BRIC_USER:-}"
    if [ -z "$requested" ]; then
        if [ "$uid" -eq 0 ] 2>/dev/null && [ -n "${SUDO_USER:-}" ]; then printf '%s' "$SUDO_USER";
        else printf '%s' "$os"; fi
        return 0
    fi
    if [ "$requested" = "$os" ] || [ "$uid" -eq 0 ] 2>/dev/null || [ "${BRIC_ALLOW_USER_OVERRIDE:-0}" = 1 ]; then
        printf '%s' "$requested"
    else
        warn_log "ignoring unsafe BRIC_USER override '$requested' from OS user '$os'"
        printf '%s' "$os"
    fi
}

new_run_id() {  # project -> monotone run id (project__UTCstamp__counter)
    local project="$1" n
    # Atomic increment+read: without BEGIN IMMEDIATE two concurrent callers can both read the same
    # post-increment value (each statement is its own implicit transaction), so two runs starting in
    # the same second could collide on the counter. The explicit write transaction serializes them.
    n="$(sqlite3 -batch -cmd '.timeout 60000' "$BRIC_DB" "
        BEGIN IMMEDIATE;
        UPDATE config SET value=CAST(value AS INTEGER)+1 WHERE key='run_counter';
        SELECT value FROM config WHERE key='run_counter';
        COMMIT;")"
    printf '%s__%s__%04d' "$project" "$(date -u +%Y%m%dT%H%M%SZ)" "$n"
}

# Review 31: user-declared source exclusions are exact relative paths/subtrees, never arbitrary shell
# fragments.  Keeping this grammar deliberately small makes the preflight walk, GNU tar invocation,
# catalog record and 15-year recovery interpretation agree on exactly what was omitted.
bric_normalize_exclude_rel() { # raw path -> normalized relative path on stdout
    local p="${1:-}" seg oldifs
    while [[ "$p" == ./* ]]; do p="${p#./}"; done
    while [ "${p%/}" != "$p" ]; do p="${p%/}"; done
    [ -n "$p" ] && [ "$p" != "." ] || return 1
    case "$p" in /*) return 1;; esac
    oldifs="$IFS"; IFS='/'; read -r -a _bric_ex_parts <<< "$p"; IFS="$oldifs"
    for seg in "${_bric_ex_parts[@]}"; do
        [ -n "$seg" ] && [ "$seg" != "." ] && [ "$seg" != ".." ] || return 1
    done
    printf '%s\n' "$p"
}



# Review 32B5: a logical root is a single stable top-level component used only by the catalog/view.
# It never changes TAR member names or the on-tape format. UTF-8 names are accepted only in NFC form;
# if python3 is unavailable we deliberately accept ASCII only rather than silently mis-normalize Unicode.
bric_validate_logical_root() { # raw root -> validated root on stdout
    local root="${1:-}" nbytes
    [ -n "$root" ] || return 1
    [ "$root" != "." ] && [ "$root" != ".." ] || return 1
    case "$root" in */*|*,*) return 1;; esac
    nbytes="$(LC_ALL=C printf '%s' "$root" | wc -c | tr -d ' ')"
    [ "$nbytes" -le 255 ] || return 1
    # Reject ASCII C0 controls and DEL by byte count. Do not use grep here: embedded newlines are
    # record separators to grep and could otherwise evade a [[:cntrl:]] character match.
    local control_free_bytes non_ascii_bytes
    control_free_bytes="$(LC_ALL=C printf '%s' "$root" | tr -d '\000-\037\177' | wc -c | tr -d ' ')"
    [ "$control_free_bytes" = "$nbytes" ] || return 1
    non_ascii_bytes="$(LC_ALL=C printf '%s' "$root" | tr -d '\040-\176' | wc -c | tr -d ' ')"
    if [ "$non_ascii_bytes" -gt 0 ]; then
        command -v python3 >/dev/null 2>&1 || return 1
        BRIC_LOGICAL_ROOT_CHECK="$root" python3 - <<'PY_NFC' || return 1
import os, sys, unicodedata
s=os.environ.get('BRIC_LOGICAL_ROOT_CHECK','')
try:
    b=s.encode('utf-8','strict')
except UnicodeError:
    sys.exit(1)
if not s or len(b)>255 or s in ('.','..') or '/' in s or '\x00' in s:
    sys.exit(1)
if unicodedata.normalize('NFC',s) != s or any(unicodedata.category(ch).startswith('C') for ch in s):
    sys.exit(1)
PY_NFC
    fi
    printf '%s\n' "$root"
}

bric_default_logical_root() { # declared source path -> validated basename
    local p="${1:-}" root
    [ -n "$p" ] || return 1
    while [ "${p%/}" != "$p" ] && [ "$p" != "/" ]; do p="${p%/}"; done
    root="${p##*/}"
    bric_validate_logical_root "$root"
}

# Additive/re-entrant 32B5 migration. New columns are appended in the same order as cluster_init.sql.
# Legacy logical roots are backfilled from source_path. Canonical paths are filled only when the source
# actually exists and resolves on this host; an unknown canonical path remains NULL and collisions fail safe.
bric_ensure_v32b5_cluster_schema() {
    bric_ensure_v31b_cluster_schema
    local col err rid src root canon
    for col in source_canonical_path logical_root; do
        if [ "$(sqlite3 -batch -cmd '.timeout 60000' "$BRIC_DB" "SELECT COUNT(*) FROM pragma_table_info('runs') WHERE name='$col';")" -eq 0 ]; then
            err="$(mktemp)"
            if ! sqlite3 -batch -cmd '.timeout 60000' "$BRIC_DB" "ALTER TABLE runs ADD COLUMN $col TEXT;" 2>"$err"; then
                # A concurrent migrator may have won the race. Accept only if the column now exists.
                if [ "$(sqlite3 -batch -cmd '.timeout 60000' "$BRIC_DB" "SELECT COUNT(*) FROM pragma_table_info('runs') WHERE name='$col';")" -eq 0 ]; then
                    cat "$err" >&2; rm -f "$err"; return 1
                fi
            fi
            rm -f "$err"
        fi
    done

    while IFS=$'\x1f' read -r -d $'\x1e' rid src root canon; do
        [ -n "$rid" ] || continue
        if [ -z "$root" ] && [ -n "$src" ]; then
            root="$(bric_default_logical_root "$src" 2>/dev/null || true)"
            [ -z "$root" ] || sql "UPDATE runs SET logical_root='$(sql_quote "$root")' WHERE run_id='$(sql_quote "$rid")' AND (logical_root IS NULL OR logical_root='');"
        fi
        if [ -z "$canon" ] && [ -n "$src" ]; then
            # A historical relative source_path has no reliable original working-directory context;
            # resolving it now could silently bind the root to an unrelated path. Only backfill an
            # absolute legacy path that exists on this planner host. Otherwise leave canonical NULL.
            case "$src" in
                /*)
                    if [ -e "$src" ]; then
                        canon="$(readlink -f -- "$src" 2>/dev/null || true)"
                        [ -z "$canon" ] || sql "UPDATE runs SET source_canonical_path='$(sql_quote "$canon")' WHERE run_id='$(sql_quote "$rid")' AND (source_canonical_path IS NULL OR source_canonical_path='');"
                    fi
                    ;;
            esac
        fi
    done < <(sqla "SELECT run_id,COALESCE(source_path,''),COALESCE(logical_root,''),COALESCE(source_canonical_path,'') FROM runs WHERE source_path IS NOT NULL AND ((logical_root IS NULL OR logical_root='') OR (source_canonical_path IS NULL OR source_canonical_path=''));" )
}


# Review 34: additive file-metadata schema. Existing rows intentionally remain mode=NULL and
# metadata_b64='' because mode/ACL/xattrs were never recorded for legacy LARGE_FILE_CHUNK objects.
# Their mtime was already catalogued and can therefore be restored retroactively.
bric_ensure_v34_cluster_schema() {
    bric_ensure_v32b5_cluster_schema
    local err
    if [ "$(sqlite3 -batch -cmd '.timeout 60000' "$BRIC_DB" "SELECT COUNT(*) FROM pragma_table_info('files') WHERE name='mode';")" -eq 0 ]; then
        err="$(mktemp)"
        if ! sqlite3 -batch -cmd '.timeout 60000' "$BRIC_DB" "ALTER TABLE files ADD COLUMN mode INTEGER;" 2>"$err"; then
            [ "$(sqlite3 -batch -cmd '.timeout 60000' "$BRIC_DB" "SELECT COUNT(*) FROM pragma_table_info('files') WHERE name='mode';")" -gt 0 ] || { cat "$err" >&2; rm -f "$err"; return 1; }
        fi
        rm -f "$err"
    fi
    if [ "$(sqlite3 -batch -cmd '.timeout 60000' "$BRIC_DB" "SELECT COUNT(*) FROM pragma_table_info('files') WHERE name='metadata_b64';")" -eq 0 ]; then
        err="$(mktemp)"
        if ! sqlite3 -batch -cmd '.timeout 60000' "$BRIC_DB" "ALTER TABLE files ADD COLUMN metadata_b64 TEXT NOT NULL DEFAULT '';" 2>"$err"; then
            [ "$(sqlite3 -batch -cmd '.timeout 60000' "$BRIC_DB" "SELECT COUNT(*) FROM pragma_table_info('files') WHERE name='metadata_b64';")" -gt 0 ] || { cat "$err" >&2; rm -f "$err"; return 1; }
        fi
        rm -f "$err"
    fi
}

bric_ensure_v31_cluster_schema() {
    sqlite3 -batch -cmd '.timeout 60000' "$BRIC_DB" <<'SQL'
PRAGMA foreign_keys=ON;
CREATE TABLE IF NOT EXISTS run_exclusions (
    run_id       TEXT NOT NULL,
    ordinal      INTEGER NOT NULL,
    rel_path     TEXT NOT NULL,
    reason       TEXT NOT NULL DEFAULT 'user-declared',
    declared_at  TEXT DEFAULT (datetime('now')),
    PRIMARY KEY (run_id, ordinal),
    UNIQUE (run_id, rel_path),
    FOREIGN KEY (run_id) REFERENCES runs(run_id)
);
CREATE TABLE IF NOT EXISTS run_source_scan (
    run_id          TEXT PRIMARY KEY,
    regular_files   INTEGER NOT NULL DEFAULT 0,
    logical_bytes   INTEGER NOT NULL DEFAULT 0,
    allocated_bytes INTEGER NOT NULL DEFAULT 0,
    exclusion_count INTEGER NOT NULL DEFAULT 0,
    scanner_uid     INTEGER,
    scanned_at      TEXT DEFAULT (datetime('now')),
    FOREIGN KEY (run_id) REFERENCES runs(run_id)
);
SQL
}

# Review 31B: additive source-consistency tables. Kept separate from the v31 helper so old callers
# remain valid while new backup/close paths can require the stronger catalog contract explicitly.
bric_ensure_v31b_cluster_schema() {
    bric_ensure_v31_cluster_schema
    sqlite3 -batch -cmd '.timeout 60000' "$BRIC_DB" <<'SQL'
PRAGMA foreign_keys=ON;
CREATE TABLE IF NOT EXISTS run_source_semantics (
    run_id                   TEXT PRIMARY KEY,
    sparse_map_method        TEXT NOT NULL DEFAULT 'gnu-pax-0.1-map',
    allocation_topology      TEXT NOT NULL DEFAULT 'not-guaranteed',
    restore_allocation_effect TEXT NOT NULL DEFAULT 'zero-ranges-may-restore-as-holes',
    source_change_policy     TEXT NOT NULL DEFAULT 'strict',
    source_consistency       TEXT NOT NULL DEFAULT 'pending',
    source_changed_count     INTEGER NOT NULL DEFAULT 0,
    tar_exit_code            INTEGER,
    updated_at               TEXT DEFAULT (datetime('now')),
    FOREIGN KEY (run_id) REFERENCES runs(run_id)
);
CREATE TABLE IF NOT EXISTS run_source_changes (
    run_id          TEXT NOT NULL,
    ordinal         INTEGER NOT NULL,
    kind            TEXT NOT NULL DEFAULT 'FILE_CHANGED_DURING_READ',
    path_text       TEXT NOT NULL,
    path_encoding   TEXT NOT NULL DEFAULT 'gnu-tar-escape',
    diagnostic      TEXT NOT NULL,
    recorded_at     TEXT DEFAULT (datetime('now')),
    PRIMARY KEY (run_id, ordinal),
    FOREIGN KEY (run_id) REFERENCES runs(run_id)
);
INSERT OR IGNORE INTO config(key,value) VALUES('source_change_policy','strict');
SQL
    # Review 31B1: upgrade catalogs created by the short-lived 31B candidate without rewriting data.
    if [ "$(sqlite3 -batch -cmd '.timeout 60000' "$BRIC_DB" "SELECT COUNT(*) FROM pragma_table_info('run_source_semantics') WHERE name='restore_allocation_effect';")" -eq 0 ]; then
        sqlite3 -batch -cmd '.timeout 60000' "$BRIC_DB" "ALTER TABLE run_source_semantics ADD COLUMN restore_allocation_effect TEXT NOT NULL DEFAULT 'zero-ranges-may-restore-as-holes';"
    fi
}
