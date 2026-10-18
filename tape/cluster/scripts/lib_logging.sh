#!/bin/bash
# Standalone durable logging helpers. No catalog, QNAP, or configuration dependency.
# Safe for disaster-recovery tools: callers may set BRIC_REQUIRE_LOGGING=0.
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
    local root="$1" probe
    [ -n "$root" ] || return 1
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
    # Review 31E4: root/system components use /var/log/bric; normal users use a root-provisioned
    # central per-user tree and retain ~/.bric/log only as an emergency fallback.  The effective OS
    # identity, not BRIC_USER, is used for legacy inference so an environment value cannot escape
    # BRIC_USER_LOG_ROOT by path manipulation.
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
    BRIC_LOG_RC=0 bric_event INFO PROCESS_START "cwd=$(pwd) argv=$* log=${_BRIC_LOG_LOCATION:-unknown}:${_BRIC_LOG_CURRENT_ROOT:-none}"
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
