#!/bin/bash
# Tape I/O abstraction for the tape server.  The changer is serialized only while inventory is
# inspected or media is moved.  Once a tape is loaded, each drive has its own lock, so two drives
# can stream PRIMARY and BACKUP concurrently without concurrent commands touching the same device.
#
#   tape_prepare_pair PRIMARY_VT BACKUP_VT PRIMARY_DRIVE BACKUP_DRIVE
#   tape_append_file VOLUMETAG SRCFILE [DRIVE]      -> echoes the 1-based file number written
#   tape_read_file   VOLUMETAG FILENO DEST [DRIVE]
#   tape_last_file_number VOLUMETAG [DRIVE]
#
# File numbering is 1-based in the catalog. Real tape physical file 0 maps to catalog file 1.

: "${BRIC_TAPE_BACKEND:=sim}"
declare -F die >/dev/null 2>&1 || die() { echo "ERROR: $*" >&2; exit 1; }
declare -F log >/dev/null 2>&1 || log() { printf '[%s] %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$*" >&2; }
# Some hardware-state unit tests source this abstraction without the full daemon common library.
# Logging must remain additive and must never make the I/O abstraction unusable in that context.
declare -F bric_event >/dev/null 2>&1 || bric_event() { :; }
# Standalone hardware-state tests source lib_tape_io.sh without tape/lib_common.sh. Preserve the
# historical fd-9 close behavior in that context; the daemon overrides this helper with the 31C
# multi-namespace implementation from lib_common.  Keep the standalone fallback idempotent too:
# after the first close, a reused fd 9 belongs to the caller/Bash and must not be closed again.
declare -F bric_close_daemon_singleton_fds >/dev/null 2>&1 || bric_close_daemon_singleton_fds() {
    local fd list="${BRIC_TAPE_SINGLETON_FDS-9}" IFS=,
    [ -n "$list" ] && for fd in $list; do
        case "$fd" in ''|*[!0-9]*) continue;; esac
        eval "exec ${fd}>&-" 2>/dev/null || true
    done
    BRIC_TAPE_SINGLETON_FDS=""
    export BRIC_TAPE_SINGLETON_FDS
}
: "${BRIC_TAPELIB:=/var/lib/bric/tapelib}"
: "${BRIC_CHANGER:=/dev/sch0}"
: "${BRIC_DRIVE0:=/dev/nst0}"
: "${BRIC_DRIVE1:=/dev/nst1}"
: "${BRIC_TAPE_DRIVES:=0}"
: "${BRIC_TAPE_BLOCK:=262144}"
: "${BRIC_TAPE_STAGE_READ_BLOCK:=4194304}"  # QNAP staging-file read size; tape writes stay BRIC_TAPE_BLOCK
: "${BRIC_TAPE_VERIFY_POSITION_MODE:=adaptive}" # adaptive | relative | absolute
: "${BRIC_TAPE_BSFM_BYTES_PER_SEC:=210000000}"  # measured reverse-media speed on current LTO-9 drives
: "${BRIC_TAPE_REWIND_MILLISECONDS:=46000}"     # measured rewind fixed cost
: "${BRIC_TAPE_FSF_MILLISECONDS_PER_FILE:=400}" # measured filemark spacing cost
: "${BRIC_CHANGER_LOCK:=/var/lock/bric_changer.lock}"
: "${BRIC_DRIVE_LOCK_PREFIX:=${BRIC_CHANGER_LOCK}.drive}"
: "${BRIC_DRIVE_READY_TIMEOUT:=900}"       # load/spin-up/ready, independently per drive
: "${BRIC_DRIVE_UNLOAD_TIMEOUT:=900}"      # rewind/eject + robotic unload confirmation
: "${BRIC_DRIVE_COMMAND_TIMEOUT:=600}"     # individual mt/mtx control command
: "${BRIC_DRIVE_STATUS_TIMEOUT:=30}"       # one readiness/inventory probe
: "${BRIC_TAPE_IO_TIMEOUT:=21600}"         # one dd stream (6h default for ~1 TB)
: "${BRIC_DRIVE_POLL_SECONDS:=2}"
: "${BRIC_UNLOAD_ON_COMPLETE:=1}"          # return media to slots before CLOSED/STAGED
: "${BRIC_SYSFS_SCSI_TAPE:=/sys/class/scsi_tape}" # test override; production uses kernel sysfs

_run_timed() {  # seconds command [args...]
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout --signal=TERM --kill-after=30 "$secs" "$@"
    else
        "$@"
    fi
}
_epoch_ms() {
    local n; n="$(date +%s%3N 2>/dev/null || true)"
    case "$n" in *[!0-9]*|'') printf '%s000' "$(date +%s)";; *) printf '%s' "$n";; esac
}
_cmd_text() { local x out=""; for x in "$@"; do printf -v x '%q' "$x"; out="${out:+$out }$x"; done; printf '%s' "$out"; }
_run_logged() { # EVENT TIMEOUT COMMAND...
    local event="$1" secs="$2"; shift 2
    local err start end dur rc=0 detail cmd
    err="$(mktemp "${TMPDIR:-/tmp}/bric-cmd.XXXXXX")" || return 1
    start="$(_epoch_ms)"; cmd="$(_cmd_text "$@")"
    bric_event INFO "${event}_BEGIN" "command=$cmd timeout_s=$secs"
    if _run_timed "$secs" "$@" 2>"$err"; then rc=0; else rc=$?; fi
    end="$(_epoch_ms)"; dur=$((end-start))
    detail="$(tr '\r\n|' '   ' <"$err" | head -c 2000)"
    [ -s "$err" ] && cat "$err" >&2
    rm -f "$err"
    if [ "$rc" -eq 0 ]; then
        BRIC_LOG_RC=0 BRIC_LOG_DURATION_MS="$dur" bric_event INFO "${event}_END" "command=$cmd"
    else
        BRIC_LOG_RC="$rc" BRIC_LOG_DURATION_MS="$dur" bric_event ERROR "${event}_FAIL" "command=$cmd stderr=${detail:-none}"
    fi
    return "$rc"
}
_mtx() { _run_timed "$BRIC_DRIVE_COMMAND_TIMEOUT" mtx -f "$BRIC_CHANGER" "$@"; }
_mt()  { local dev="$1"; shift; _run_timed "$BRIC_DRIVE_COMMAND_TIMEOUT" mt -f "$dev" "$@"; }
_drive_dev() { case "$1" in 0) echo "$BRIC_DRIVE0";; 1) echo "$BRIC_DRIVE1";; *) echo "/dev/nst$1";; esac; }
_drive_lock() { printf '%s%s' "$BRIC_DRIVE_LOCK_PREFIX" "$1"; }
# Per-drive timing override. A site may set e.g. BRIC_DRIVE_READY_TIMEOUT_1=1800 for a
# slower drive while keeping the common timeout for the other devices. READY/UNLOAD use
# BRIC_DRIVE_<PHASE>_TIMEOUT_<drive>; tape streaming uses BRIC_TAPE_IO_TIMEOUT_<drive>.
_drive_timeout() {  # READY|UNLOAD drive default
    local kind="$1" D="$2" fallback="$3" var val
    var="BRIC_DRIVE_${kind}_TIMEOUT_${D}"
    val="${!var:-$fallback}"
    case "$val" in ''|*[!0-9]*) die "$var/common timeout must be a non-negative integer (got '$val')";; esac
    printf '%s' "$val"
}
_drive_io_timeout() { # drive default
    local D="$1" fallback="$2" var="BRIC_TAPE_IO_TIMEOUT_${1}" val
    val="${!var:-$fallback}"
    case "$val" in ''|*[!0-9]*) die "$var/common timeout must be a non-negative integer (got '$val')";; esac
    printf '%s' "$val"
}
_first_drive() { local IFS=$' \t\n'; set -- $BRIC_TAPE_DRIVES; [ "$#" -gt 0 ] || die "BRIC_TAPE_DRIVES is empty"; printf '%s' "$1"; }
_mt_filenum() { _mt "$1" status 2>/dev/null | tr 'A-Z' 'a-z' | sed -n 's/.*file number=\([0-9-]*\).*/\1/p' | head -1; }
# Linux st driver options that would break BRIC's physical-file-number invariant:
#   0x10 MT_ST_TWO_FM    close writes two filemarks (and backspaces over the second)
#   0x20 MT_ST_FAST_MTEOM direct EOD positioning; the kernel documents file number as invalid
_tape_st_options() {  # device -> numeric/hex option mask, empty if not a real local char device
    local dev="$1" real base f raw
    [ -c "$dev" ] || return 1
    real="$(readlink -f "$dev" 2>/dev/null || printf '%s' "$dev")"; base="$(basename "$real")"
    f="$BRIC_SYSFS_SCSI_TAPE/$base/options"; [ -r "$f" ] || return 1
    raw="$(tr -d '[:space:]' <"$f")"
    case "$raw" in
        0[xX]*) case "${raw#0?}" in ''|*[!0-9A-Fa-f]*) return 1;; esac ;;
        '') return 1 ;;
        *[!0-9]*) return 1 ;;
    esac
    printf '%s' "$raw"
}
_assert_contiguous_file_mode() {  # device [drive-label]
    local dev="$1" D="${2:-?}" raw val
    raw="$(_tape_st_options "$dev" 2>/dev/null || true)"; [ -n "$raw" ] || return 0
    case "$raw" in 0[xX]*) val=$((raw));; *) val=$((10#$raw));; esac
    if (( val & 0x10 )); then
        BRIC_LOG_RC=1 bric_event ERROR TAPE_DRIVER_OPTIONS_UNSAFE "device=$dev options=$raw flag=MT_ST_TWO_FM"
        die "drive $D uses MT_ST_TWO_FM ($raw): BRIC requires exactly one filemark per close"
    fi
    if (( val & 0x20 )); then
        BRIC_LOG_RC=1 bric_event ERROR TAPE_DRIVER_OPTIONS_UNSAFE "device=$dev options=$raw flag=MT_ST_FAST_MTEOM"
        die "drive $D uses MT_ST_FAST_MTEOM ($raw): file number after eod is not reliable"
    fi
}
_status() {
    local err out rc=0
    err="$(mktemp "${TMPDIR:-/tmp}/bric-status.XXXXXX")" || die "cannot create status diagnostic scratch"
    if out="$(_run_timed "$BRIC_DRIVE_STATUS_TIMEOUT" mtx -f "$BRIC_CHANGER" status 2>"$err")"; then
        rm -f "$err"; printf '%s' "$out"; return 0
    else
        rc=$?
    fi
    BRIC_LOG_RC="$rc" bric_event ERROR CHANGER_STATUS_FAILED         "changer=$BRIC_CHANGER stderr=$(tr '\r\n|' '   ' <"$err" | head -c 2000)"
    [ -s "$err" ] && cat "$err" >&2; rm -f "$err"
    die "mtx status failed (changer $BRIC_CHANGER, rc=$rc)"
}

_wait_drive_ready() {  # drive expected_vt context
    local D="$1" vt="$2" why="${3:-operation}" dev deadline st cur last="" timeout_s
    timeout_s="$(_drive_timeout READY "$D" "$BRIC_DRIVE_READY_TIMEOUT")"
    export BRIC_LOG_DRIVE="$D" BRIC_LOG_VOLUMETAG="$vt"
    bric_event INFO DRIVE_READY_WAIT_BEGIN "context=$why timeout_s=$timeout_s device=$(_drive_dev "$D")"
    dev="$(_drive_dev "$D")"; deadline=$(( $(date +%s) + timeout_s ))
    while [ "$(date +%s)" -le "$deadline" ]; do
        st="$(_status 2>/dev/null || true)"; cur="$(_drive_vt "$st" "$D")"
        if [ "$cur" = "$vt" ] && _run_timed "$BRIC_DRIVE_STATUS_TIMEOUT" mt -f "$dev" status >/dev/null 2>&1; then
            bric_event INFO DRIVE_READY "context=$why device=$dev"
            log "drive $D ready for $why ($vt on $dev)"
            return 0
        fi
        last="changer=${cur:-empty}; mt=$( _run_timed "$BRIC_DRIVE_STATUS_TIMEOUT" mt -f "$dev" status 2>&1 | head -1 || true )"
        sleep "$BRIC_DRIVE_POLL_SECONDS"
    done
    bric_event ERROR DRIVE_READY_TIMEOUT "context=$why timeout_s=$timeout_s last=$last"
    die "drive $D did not become ready for $why within ${timeout_s}s ($vt; $last)"
}

_wait_drive_empty() {  # drive vt context; caller serializes changer operations
    local D="$1" vt="$2" why="${3:-unload}" deadline st cur slot timeout_s
    timeout_s="$(_drive_timeout UNLOAD "$D" "$BRIC_DRIVE_UNLOAD_TIMEOUT")"
    export BRIC_LOG_DRIVE="$D" BRIC_LOG_VOLUMETAG="$vt"
    bric_event INFO DRIVE_EMPTY_WAIT_BEGIN "context=$why timeout_s=$timeout_s"
    deadline=$(( $(date +%s) + timeout_s ))
    while [ "$(date +%s)" -le "$deadline" ]; do
        st="$(_status 2>/dev/null || true)"; cur="$(_drive_vt "$st" "$D")"; slot="$(_vt_slot "$st" "$vt")"
        if [ -z "$cur" ] && [ -n "$slot" ]; then
            bric_event INFO DRIVE_EMPTY "context=$why slot=$slot"
            log "drive $D empty after $why ($vt returned to slot $slot)"
            return 0
        fi
        sleep "$BRIC_DRIVE_POLL_SECONDS"
    done
    bric_event ERROR DRIVE_UNLOAD_TIMEOUT "context=$why timeout_s=$timeout_s"
    die "drive $D did not complete $why within ${timeout_s}s ($vt still loaded or not inventoried)"
}

_changer_unload_confirm_locked() {  # drive vt origin_slot; caller holds changer + drive lock
    local D="$1" vt="$2" os="$3" deadline timeout_s
    timeout_s="$(_drive_timeout UNLOAD "$D" "$BRIC_DRIVE_UNLOAD_TIMEOUT")"
    deadline=$(( $(date +%s) + timeout_s ))
    while [ "$(date +%s)" -le "$deadline" ]; do
        # An earlier unload may have completed asynchronously even if mtx returned non-zero or the
        # caller was interrupted.  Trust confirmed inventory, not the last command's exit status.
        local st cur slot
        st="$(_status 2>/dev/null || true)"; cur="$(_drive_vt "$st" "$D")"; slot="$(_vt_slot "$st" "$vt")"
        if [ -z "$cur" ] && [ -n "$slot" ]; then
            log "drive $D empty after eject/unload ($vt returned to slot $slot)"
            return 0
        fi
        if BRIC_LOG_DRIVE="$D" BRIC_LOG_VOLUMETAG="$vt" _run_logged CHANGER_UNLOAD "$BRIC_DRIVE_COMMAND_TIMEOUT" mtx -f "$BRIC_CHANGER" unload "$os" "$D" >/dev/null; then
            _wait_drive_empty "$D" "$vt" "eject/unload"
            return 0
        fi
        sleep "$BRIC_DRIVE_POLL_SECONDS"
    done
    die "cannot unload $vt from drive $D within ${timeout_s}s"
}

_unload_drive_locked() {  # drive vt origin_slot; caller holds drive + changer locks
    local D="$1" vt="$2" os="$3" dev
    dev="$(_drive_dev "$D")"
    _wait_drive_ready "$D" "$vt" "pre-eject"
    # Some drives block in offline until the cartridge is fully ejected; others return before the
    # robotics may pull it.  mtx unload is therefore retried and inventory-confirmed below.
    BRIC_LOG_DRIVE="$D" BRIC_LOG_VOLUMETAG="$vt"         _run_logged DRIVE_OFFLINE "$BRIC_DRIVE_COMMAND_TIMEOUT" mt -f "$dev" offline >/dev/null ||         bric_event WARN DRIVE_OFFLINE_CONTINUE "offline failed; changer unload will still be attempted"
    _changer_unload_confirm_locked "$D" "$vt" "$os"
}
_drive_vt() { printf '%s\n' "$1" | sed -n "s/^Data Transfer Element $2:Full.*VolumeTag *= *\([A-Za-z0-9][A-Za-z0-9]*\).*/\1/p" | head -1; }
_drive_slot() { printf '%s\n' "$1" | sed -n "s/^Data Transfer Element $2:Full (Storage Element \([0-9][0-9]*\) Loaded).*/\1/p" | head -1; }
_vt_drive() { printf '%s\n' "$1" | sed -n "s/^Data Transfer Element \([0-9][0-9]*\):Full.*VolumeTag *= *$2\([^A-Za-z0-9]\|$\).*/\1/p" | head -1; }
_vt_slot() { printf '%s\n' "$1" | sed -n "s/^[[:space:]]*Storage Element \([0-9][0-9]*\)[ :].*VolumeTag *= *$2\([^A-Za-z0-9]\|$\).*/\1/p" | head -1; }

# Caller holds BRIC_CHANGER_LOCK and the target drive's lock. Never steals a tape from another
# loaded drive: parallel workers must not unload each other's media. tape_prepare_pair handles a
# swapped/preloaded pair before workers start.
_load_on_drive_locked() {  # vt drive -> device; caller holds drive + changer locks
    local vt="$1" D="$2" st cur os slot elsewhere deadline
    st="$(_status)"
    cur="$(_drive_vt "$st" "$D")"
    [ "$cur" = "$vt" ] && { _drive_dev "$D"; return 0; }
    elsewhere="$(_vt_drive "$st" "$vt")"
    [ -z "$elsewhere" ] || die "VolumeTag $vt is loaded in drive $elsewhere, not requested drive $D"
    if [ -n "$cur" ]; then
        os="$(_drive_slot "$st" "$D")"
        [ -n "$os" ] || die "cannot determine origin slot for $cur in drive $D"
        _unload_drive_locked "$D" "$cur" "$os"
        st="$(_status)"
    fi
    slot="$(_vt_slot "$st" "$vt")"
    [ -n "$slot" ] || die "VolumeTag $vt not found in a storage slot of $BRIC_CHANGER"
    local timeout_s; timeout_s="$(_drive_timeout READY "$D" "$BRIC_DRIVE_READY_TIMEOUT")"
    deadline=$(( $(date +%s) + timeout_s ))
    while [ "$(date +%s)" -le "$deadline" ]; do
        # LOAD completion and inventory visibility are not synchronous on every library.  Check the
        # observed state before each retry, so a successful asynchronous load is accepted even when
        # the original mtx invocation returned early/non-zero and a duplicate LOAD is rejected.
        st="$(_status 2>/dev/null || true)"
        [ "$(_drive_vt "$st" "$D")" = "$vt" ] && { _drive_dev "$D"; return 0; }
        BRIC_LOG_DRIVE="$D" BRIC_LOG_VOLUMETAG="$vt" _run_logged CHANGER_LOAD "$BRIC_DRIVE_COMMAND_TIMEOUT" mtx -f "$BRIC_CHANGER" load "$slot" "$D" >/dev/null || true
        sleep "$BRIC_DRIVE_POLL_SECONDS"
    done
    die "mtx load slot $slot -> drive $D did not complete within ${timeout_s}s"
}

# Normalize the two pair tapes onto two distinct drives before the parallel workers are forked.
# Both drive locks plus the changer lock are held in a fixed order, so swapped media can be unloaded
# safely and no other tape operation can observe a half-prepared pair.
tape_prepare_pair() {  # primary_vt backup_vt primary_drive backup_drive
    [ "$BRIC_TAPE_BACKEND" = real ] || return 0
    local pvt="$1" bvt="$2" pd="$3" bd="$4" pdl bdl first second work_rc=0
    bric_event INFO PAIR_PREPARE_BEGIN "primary=$pvt drive_primary=$pd backup=$bvt drive_backup=$bd"
    pdl="$(_drive_lock "$pd")"; bdl="$(_drive_lock "$bd")"
    if [ "$pd" -lt "$bd" ] 2>/dev/null; then first="$pdl"; second="$bdl"; else first="$bdl"; second="$pdl"; fi
    # Do all failure-prone work in a child scope.  Callers deliberately invoke this function under
    # ||/if guards; Bash suppresses errexit for that whole dynamic context, so every critical failure
    # below is converted explicitly to die/exit and the child status is captured before publishing END.
    (
        [ "$pd" != "$bd" ] || die "parallel pair requires two distinct drives (got $pd twice)"
        flock 6 || die "drive lock busy: $first"
        flock 7 || die "drive lock busy: $second"
        flock 8 || die "changer busy"
        bric_close_daemon_singleton_fds
        local st D want cur os slot
        st="$(_status)" || die "cannot read changer status while preparing $pvt/$bvt"
        # First empty any target drive containing the wrong tape. Each drive may take a different
        # amount of time to become ready/eject; _unload_drive_locked waits for that exact drive and
        # confirms the cartridge is back in a slot before the next robotic move.
        for D in "$pd" "$bd"; do
            [ "$D" = "$pd" ] && want="$pvt" || want="$bvt"
            cur="$(_drive_vt "$st" "$D")"
            if [ -n "$cur" ] && [ "$cur" != "$want" ]; then
                os="$(_drive_slot "$st" "$D")"
                [ -n "$os" ] || die "cannot determine origin slot for $cur in drive $D"
                _unload_drive_locked "$D" "$cur" "$os"
                st="$(_status)" || die "cannot refresh changer status after unloading drive $D"
            fi
        done
        # Then issue the two loads. Robotics is serialized, but drive spin-up/readiness is not.
        # _load_on_drive_locked tolerates a changer that acknowledges LOAD before inventory shows the
        # cartridge in the drive; it polls up to that drive's own READY timeout instead of treating
        # the first transient status as a hard failure.
        for D in "$pd" "$bd"; do
            [ "$D" = "$pd" ] && want="$pvt" || want="$bvt"
            _load_on_drive_locked "$want" "$D" >/dev/null
            st="$(_status)" || die "cannot refresh changer status after loading $want on drive $D"
        done
        # Release only the changer lock. Keep both drive locks while readiness is polled in parallel,
        # so no operation can steal either drive during the asymmetric spin-up window.
        flock -u 8 || die "cannot release changer lock after preparing $pvt/$bvt"
        local pp bp prc=0 brc=0
        ( _wait_drive_ready "$pd" "$pvt" "parallel pair prepare" ) & pp=$!
        ( _wait_drive_ready "$bd" "$bvt" "parallel pair prepare" ) & bp=$!
        wait "$pp" || prc=$?
        wait "$bp" || brc=$?
        [ "$prc" -eq 0 ] && [ "$brc" -eq 0 ] || die "parallel pair readiness failed: drive $pd rc=$prc, drive $bd rc=$brc"
    ) 6>"$first" 7>"$second" 8>"$BRIC_CHANGER_LOCK" || work_rc=$?
    if [ "$work_rc" -ne 0 ]; then
        BRIC_LOG_RC="$work_rc" bric_event ERROR PAIR_PREPARE_FAILED             "primary=$pvt drive_primary=$pd backup=$bvt drive_backup=$bd"
        return "$work_rc"
    fi
    bric_event INFO PAIR_PREPARE_END "primary=$pvt drive_primary=$pd backup=$bvt drive_backup=$bd"
    return 0
}

# Run one real tape operation with a dedicated drive lock. The changer lock is held only while the
# correct cartridge is loaded; mt/dd then proceed without blocking the other drive.
_real_drive_dev() {  # vt drive -> device; caller holds drive lock
    local vt="$1" D="$2" dev
    dev="$(
        (
            flock 8 || die "changer busy"
            _load_on_drive_locked "$vt" "$D"
        ) 8>"$BRIC_CHANGER_LOCK"
    )"
    _wait_drive_ready "$D" "$vt" "tape operation"
    printf '%s' "$dev"
}

tape_append_file() {
    local vt="$1" src="$2" D="${3:-}"
    if [ "$BRIC_TAPE_BACKEND" = sim ]; then
        bric_close_daemon_singleton_fds
        export BRIC_LOG_DRIVE="${D:-sim}" BRIC_LOG_VOLUMETAG="$vt"
        BRIC_LOG_BYTES="$(stat -c %s "$src" 2>/dev/null || echo 0)" bric_event INFO TAPE_WRITE_BEGIN "backend=sim source=$(basename "$src")"
        local delay="${BRIC_FAULT_SIM_APPEND_DELAY:-}" dvar
        if [ -n "$D" ]; then dvar="BRIC_FAULT_SIM_APPEND_DELAY_${D}"; [ -n "${!dvar:-}" ] && delay="${!dvar}"; fi
        [ -n "${BRIC_PARALLEL_TRACE:-}" ] && printf 'start|%s|%s|%s|%s\n' "$vt" "${D:-auto}" "${BASHPID:-$$}" "$(date +%s)" >> "$BRIC_PARALLEL_TRACE"
        [ -n "$delay" ] && sleep "$delay"
        local d="$BRIC_TAPELIB/$vt" n
        mkdir -p "$d"
        (
            flock 6 || die "sim volume lock busy: $vt"
            n="$(find "$d" -maxdepth 1 -type f -name 'f_*' | wc -l | tr -d ' ')"; n=$((n+1))
            cp -f "$src" "$d/$(printf 'f_%06d' "$n")"
            [ -n "${BRIC_PARALLEL_TRACE:-}" ] && printf 'end|%s|%s|%s|%s\n' "$vt" "${D:-auto}" "${BASHPID:-$$}" "$(date +%s)" >> "$BRIC_PARALLEL_TRACE"
            BRIC_LOG_BYTES="$(stat -c %s "$src" 2>/dev/null || echo 0)" bric_event INFO TAPE_WRITE_END "backend=sim file_number=$n"
            printf '%s' "$n"
        ) 6>"$BRIC_TAPELIB/.${vt}.lock"
        return 0
    fi
    command -v mtx >/dev/null && command -v mt >/dev/null && command -v dd >/dev/null || die "need mtx, mt, dd for real backend"
    [ -n "$D" ] || D="$(_first_drive)"
    (
        flock 6 || die "drive $D busy"
        bric_close_daemon_singleton_fds
        export BRIC_LOG_DRIVE="$D" BRIC_LOG_VOLUMETAG="$vt"
        local dev idx0 idx1 expected size io_timeout; dev="$(_real_drive_dev "$vt" "$D")"; _assert_contiguous_file_mode "$dev" "$D"; io_timeout="$(_drive_io_timeout "$D" "$BRIC_TAPE_IO_TIMEOUT")"; size="$(stat -c %s "$src" 2>/dev/null || echo 0)"
        BRIC_LOG_BYTES="$size" bric_event INFO TAPE_WRITE_BEGIN "device=$dev source=$(basename "$src")"
        _mt "$dev" setblk 0 >/dev/null 2>&1 || bric_event WARN DRIVE_SETBLK_FAILED "device=$dev continuing with current block mode"
        _run_logged DRIVE_EOD "$BRIC_DRIVE_COMMAND_TIMEOUT" mt -f "$dev" eod || die "drive $D failed to position at EOD"
        idx0="$(_mt_filenum "$dev")"
        case "$idx0" in ''|*[!0-9]*) die "drive $D returned invalid file number at EOD: '${idx0:-empty}'";; esac
        BRIC_LOG_BYTES="$size" _run_logged TAPE_STREAM_WRITE "$io_timeout" dd if="$src" of="$dev" iflag=fullblock ibs="$BRIC_TAPE_STAGE_READ_BLOCK" obs="$BRIC_TAPE_BLOCK" || die "dd write to $dev timed out/failed"
        # Linux's SCSI tape driver writes one flushing filemark when the non-rewinding device is
        # closed after a write.  An additional `mt weof` here would create an empty tape file and
        # make physical numbering advance 1,3,5,... instead of 1,2,3,... .
        _wait_drive_ready "$D" "$vt" "post-write/implicit-filemark"
        idx1="$(_mt_filenum "$dev")"; expected=$((idx0 + 1))
        case "$idx1" in ''|*[!0-9]*)
            BRIC_LOG_RC=1 bric_event ERROR TAPE_FILE_POSITION_MISMATCH "device=$dev before=$idx0 after=${idx1:-empty} expected=$expected"
            die "drive $D returned invalid file number after write: '${idx1:-empty}'"
            ;;
        esac
        if [ "$idx1" -ne "$expected" ]; then
            BRIC_LOG_RC=1 bric_event ERROR TAPE_FILE_POSITION_MISMATCH "device=$dev before=$idx0 after=$idx1 expected=$expected"
            die "unexpected tape file position after write on drive $D: before=$idx0 after=$idx1 expected=$expected"
        fi
        bric_event INFO TAPE_IMPLICIT_FILEMARK_VERIFIED "device=$dev before=$idx0 after=$idx1"
        BRIC_LOG_BYTES="$size" bric_event INFO TAPE_WRITE_END "device=$dev file_number=$idx1"
        printf '%s' "$idx1"
    ) 6>"$(_drive_lock "$D")"
}

# Read the file that was JUST appended on this same drive.  This is deliberately a separate API:
# restore/reverify/sniff/arbitrary reads remain absolute (rewind+fsf).  The fast path is relative,
# so it proves two absolute post-conditions against the catalog file number and falls back to the
# old absolute positioning path on any command error or mismatch.
tape_read_file_immediate() { # VOLUMETAG FILENO DEST [DRIVE]
    local vt="$1" fn="$2" dest="$3" D="${4:-}"
    if [ "$BRIC_TAPE_BACKEND" = sim ]; then
        tape_read_file "$vt" "$fn" "$dest" "$D"
        return $?
    fi
    command -v mtx >/dev/null && command -v mt >/dev/null && command -v dd >/dev/null || die "need mtx, mt, dd for real backend"
    [ -n "$D" ] || D="$(_first_drive)"
    (
        flock 6 || die "drive $D busy"
        bric_close_daemon_singleton_fds
        export BRIC_LOG_DRIVE="$D" BRIC_LOG_VOLUMETAG="$vt"
        local dev io_timeout eod_fn="" landed_fn="" expected_pos fast=0 reason=""
        dev="$(_real_drive_dev "$vt" "$D")"; io_timeout="$(_drive_io_timeout "$D" "$BRIC_TAPE_IO_TIMEOUT")"
        expected_pos=$((fn - 1))
        bric_event INFO TAPE_READ_BEGIN "device=$dev file_number=$fn destination=$(basename "$dest") mode=immediate"
        _mt "$dev" setblk 0 >/dev/null 2>&1 || bric_event WARN DRIVE_SETBLK_FAILED "device=$dev continuing with current block mode"

        # Establish the only condition in which a relative backspace is allowed: the just-written
        # file must still be the physical last file recorded by the append result/catalog.
        if _run_logged DRIVE_EOD "$BRIC_DRIVE_COMMAND_TIMEOUT" mt -f "$dev" eod; then
            eod_fn="$(_mt_filenum "$dev")"
            case "$eod_fn" in ''|*[!0-9]*) reason="invalid-eod-file-number:${eod_fn:-empty}";;
                *) if [ "$eod_fn" -eq "$fn" ]; then
                       bric_event INFO TAPE_IMMEDIATE_EOD_VERIFIED "device=$dev expected=$fn observed=$eod_fn"
                       if _run_logged DRIVE_BSFM "$BRIC_DRIVE_COMMAND_TIMEOUT" mt -f "$dev" bsfm 2; then
                           landed_fn="$(_mt_filenum "$dev")"
                           case "$landed_fn" in ''|*[!0-9]*) reason="invalid-bsfm-file-number:${landed_fn:-empty}";;
                               *) if [ "$landed_fn" -eq "$expected_pos" ]; then
                                      fast=1
                                      bric_event INFO TAPE_IMMEDIATE_POSITION_VERIFIED "device=$dev file_number=$fn position=$landed_fn method=bsfm2"
                                  else
                                      reason="bsfm-landing-mismatch"
                                  fi ;;
                           esac
                       else
                           reason="bsfm-command-failed"
                       fi
                   else
                       reason="eod-file-mismatch"
                   fi ;;
            esac
        else
            reason="eod-command-failed"
        fi

        if [ "$fast" -ne 1 ]; then
            BRIC_LOG_RC=0 bric_event WARN TAPE_IMMEDIATE_POSITION_FALLBACK \
                "device=$dev file_number=$fn reason=$reason expected_eod=$fn observed_eod=${eod_fn:-unknown} expected_position=$expected_pos observed_position=${landed_fn:-unknown} fallback=rewind+fsf"
            _run_logged DRIVE_REWIND "$BRIC_DRIVE_COMMAND_TIMEOUT" mt -f "$dev" rewind || die "drive $D rewind failed during immediate-read fallback"
            [ "$fn" -gt 1 ] && _run_logged DRIVE_FSF "$BRIC_DRIVE_COMMAND_TIMEOUT" mt -f "$dev" fsf "$expected_pos" \
                || { [ "$fn" -le 1 ] || die "drive $D fsf failed during immediate-read fallback"; }
            landed_fn="$(_mt_filenum "$dev")"
            case "$landed_fn" in ''|*[!0-9]*) die "drive $D returned invalid file number after absolute read fallback: '${landed_fn:-empty}'";; esac
            [ "$landed_fn" -eq "$expected_pos" ] || die "drive $D absolute read fallback landed at file $landed_fn, expected $expected_pos"
            bric_event INFO TAPE_ABSOLUTE_POSITION_VERIFIED "device=$dev file_number=$fn position=$landed_fn method=rewind+fsf fallback_from=immediate"
        fi

        _run_logged TAPE_STREAM_READ "$io_timeout" dd if="$dev" of="$dest" bs="$BRIC_TAPE_BLOCK" || die "dd read from $dev timed out/failed"
        _wait_drive_ready "$D" "$vt" "post-read"
        BRIC_LOG_BYTES="$(stat -c %s "$dest" 2>/dev/null || echo 0)" bric_event INFO TAPE_READ_END "device=$dev file_number=$fn mode=immediate method=$([ "$fast" -eq 1 ] && echo bsfm2 || echo absolute-fallback)"
    ) 6>"$(_drive_lock "$D")"
}

tape_read_file() {
    local vt="$1" fn="$2" dest="$3" D="${4:-}"
    if [ "$BRIC_TAPE_BACKEND" = sim ]; then
        export BRIC_LOG_DRIVE="${D:-sim}" BRIC_LOG_VOLUMETAG="$vt"
        bric_event INFO TAPE_READ_BEGIN "backend=sim file_number=$fn destination=$(basename "$dest")"
        if cp -f "$BRIC_TAPELIB/$vt/$(printf 'f_%06d' "$fn")" "$dest"; then
            BRIC_LOG_BYTES="$(stat -c %s "$dest" 2>/dev/null || echo 0)" bric_event INFO TAPE_READ_END "backend=sim file_number=$fn"
            return 0
        fi
        BRIC_LOG_RC=1 bric_event ERROR TAPE_READ_FAIL "backend=sim file_number=$fn"
        return 1
    fi
    command -v mtx >/dev/null && command -v mt >/dev/null && command -v dd >/dev/null || die "need mtx, mt, dd for real backend"
    [ -n "$D" ] || D="$(_first_drive)"
    (
        flock 6 || die "drive $D busy"
        bric_close_daemon_singleton_fds
        export BRIC_LOG_DRIVE="$D" BRIC_LOG_VOLUMETAG="$vt"
        local dev io_timeout; dev="$(_real_drive_dev "$vt" "$D")"; io_timeout="$(_drive_io_timeout "$D" "$BRIC_TAPE_IO_TIMEOUT")"
        bric_event INFO TAPE_READ_BEGIN "device=$dev file_number=$fn destination=$(basename "$dest")"
        _mt "$dev" setblk 0 >/dev/null 2>&1 || bric_event WARN DRIVE_SETBLK_FAILED "device=$dev continuing with current block mode"
        _run_logged DRIVE_REWIND "$BRIC_DRIVE_COMMAND_TIMEOUT" mt -f "$dev" rewind || die "drive $D rewind failed"
        [ "$fn" -gt 1 ] && _run_logged DRIVE_FSF "$BRIC_DRIVE_COMMAND_TIMEOUT" mt -f "$dev" fsf "$((fn - 1))"
        _run_logged TAPE_STREAM_READ "$io_timeout" dd if="$dev" of="$dest" bs="$BRIC_TAPE_BLOCK" || die "dd read from $dev timed out/failed"
        _wait_drive_ready "$D" "$vt" "post-read"
        BRIC_LOG_BYTES="$(stat -c %s "$dest" 2>/dev/null || echo 0)" bric_event INFO TAPE_READ_END "device=$dev file_number=$fn"
    ) 6>"$(_drive_lock "$D")"
}


# Stream a tape file to stdout instead of materializing it on local disk. These APIs are used by
# verification paths: callers may hash/count the stream directly without requiring segment-sized
# scratch space. Restore continues to use tape_read_file(), because restore intentionally publishes
# a materialized ciphertext blob onto the bus.
_tape_sim_stream_file() { # VOLUMETAG FILENO
    local vt="$1" fn="$2" f="$BRIC_TAPELIB/$vt/$(printf 'f_%06d' "$fn")" mode="${BRIC_FAULT_SIM_VERIFY_MODE:-}" size
    export BRIC_LOG_VOLUMETAG="$vt" BRIC_LOG_DRIVE="${BRIC_LOG_DRIVE:-sim}"
    bric_event INFO TAPE_READ_BEGIN "backend=sim file_number=$fn destination=stdout mode=streaming"
    [ -f "$f" ] || { BRIC_LOG_RC=1 bric_event ERROR TAPE_READ_FAIL "backend=sim file_number=$fn missing=yes"; return 1; }
    size="$(stat -c %s "$f" 2>/dev/null || echo 0)"
    case "$mode" in
        io)
            BRIC_LOG_RC=74 bric_event ERROR TAPE_STREAM_READ_FAIL "backend=sim fault=io"
            return 74
            ;;
        short)
            if [ "$size" -gt 0 ]; then head -c "$((size-1))" "$f"; fi
            BRIC_LOG_BYTES="$(( size>0 ? size-1 : 0 ))" bric_event INFO TAPE_READ_END "backend=sim file_number=$fn mode=streaming fault=short"
            return 0
            ;;
        corrupt)
            if [ "$size" -gt 0 ]; then tail -c +2 "$f"; printf '\0'; fi
            BRIC_LOG_BYTES="$size" bric_event INFO TAPE_READ_END "backend=sim file_number=$fn mode=streaming fault=corrupt"
            return 0
            ;;
    esac
    cat "$f" || { local rc=$?; BRIC_LOG_RC="$rc" bric_event ERROR TAPE_STREAM_READ_FAIL "backend=sim file_number=$fn"; return "$rc"; }
    BRIC_LOG_BYTES="$size" bric_event INFO TAPE_READ_END "backend=sim file_number=$fn mode=streaming"
    return 0
}

tape_stream_file_immediate() { # VOLUMETAG FILENO [DRIVE]
    local vt="$1" fn="$2" D="${3:-}"
    if [ "$BRIC_TAPE_BACKEND" = sim ]; then
        _tape_sim_stream_file "$vt" "$fn"
        return $?
    fi
    command -v mtx >/dev/null && command -v mt >/dev/null && command -v dd >/dev/null || die "need mtx, mt, dd for real backend"
    [ -n "$D" ] || D="$(_first_drive)"
    (
        flock 6 || die "drive $D busy"
        bric_close_daemon_singleton_fds
        export BRIC_LOG_DRIVE="$D" BRIC_LOG_VOLUMETAG="$vt"
        local dev io_timeout eod_fn="" landed_fn="" expected_pos fast=0 reason=""
        dev="$(_real_drive_dev "$vt" "$D")"; io_timeout="$(_drive_io_timeout "$D" "$BRIC_TAPE_IO_TIMEOUT")"
        expected_pos=$((fn - 1))
        bric_event INFO TAPE_READ_BEGIN "device=$dev file_number=$fn destination=stdout mode=immediate-stream"
        _mt "$dev" setblk 0 >/dev/null 2>&1 || bric_event WARN DRIVE_SETBLK_FAILED "device=$dev continuing with current block mode"
        if _run_logged DRIVE_EOD "$BRIC_DRIVE_COMMAND_TIMEOUT" mt -f "$dev" eod; then
            eod_fn="$(_mt_filenum "$dev")"
            case "$eod_fn" in ''|*[!0-9]*) reason="invalid-eod-file-number:${eod_fn:-empty}";;
                *) if [ "$eod_fn" -eq "$fn" ]; then
                       bric_event INFO TAPE_IMMEDIATE_EOD_VERIFIED "device=$dev expected=$fn observed=$eod_fn"
                       if _run_logged DRIVE_BSFM "$BRIC_DRIVE_COMMAND_TIMEOUT" mt -f "$dev" bsfm 2; then
                           landed_fn="$(_mt_filenum "$dev")"
                           case "$landed_fn" in ''|*[!0-9]*) reason="invalid-bsfm-file-number:${landed_fn:-empty}";;
                               *) if [ "$landed_fn" -eq "$expected_pos" ]; then
                                      fast=1
                                      bric_event INFO TAPE_IMMEDIATE_POSITION_VERIFIED "device=$dev file_number=$fn position=$landed_fn method=bsfm2"
                                  else reason="bsfm-landing-mismatch"; fi ;;
                           esac
                       else reason="bsfm-command-failed"; fi
                   else reason="eod-file-mismatch"; fi ;;
            esac
        else reason="eod-command-failed"; fi
        if [ "$fast" -ne 1 ]; then
            BRIC_LOG_RC=0 bric_event WARN TAPE_IMMEDIATE_POSITION_FALLBACK \
                "device=$dev file_number=$fn reason=$reason expected_eod=$fn observed_eod=${eod_fn:-unknown} expected_position=$expected_pos observed_position=${landed_fn:-unknown} fallback=rewind+fsf"
            _run_logged DRIVE_REWIND "$BRIC_DRIVE_COMMAND_TIMEOUT" mt -f "$dev" rewind || die "drive $D rewind failed during immediate-read fallback"
            if [ "$fn" -gt 1 ]; then
                _run_logged DRIVE_FSF "$BRIC_DRIVE_COMMAND_TIMEOUT" mt -f "$dev" fsf "$expected_pos" || die "drive $D fsf failed during immediate-read fallback"
            fi
            landed_fn="$(_mt_filenum "$dev")"
            case "$landed_fn" in ''|*[!0-9]*) die "drive $D returned invalid file number after absolute read fallback: '${landed_fn:-empty}'";; esac
            [ "$landed_fn" -eq "$expected_pos" ] || die "drive $D absolute read fallback landed at file $landed_fn, expected $expected_pos"
            bric_event INFO TAPE_ABSOLUTE_POSITION_VERIFIED "device=$dev file_number=$fn position=$landed_fn method=rewind+fsf fallback_from=immediate"
        fi
        # No of= argument: dd streams the tape file to stdout. _run_logged still captures the exact
        # hardware rc/stderr; the verifier outside this function counts and hashes stdout concurrently.
        _run_logged TAPE_STREAM_READ "$io_timeout" dd if="$dev" bs="$BRIC_TAPE_BLOCK" || die "dd read from $dev timed out/failed"
        _wait_drive_ready "$D" "$vt" "post-read"
        bric_event INFO TAPE_READ_END "device=$dev file_number=$fn mode=immediate-stream method=$([ "$fast" -eq 1 ] && echo bsfm2 || echo absolute-fallback)"
    ) 6>"$(_drive_lock "$D")"
}

tape_stream_file() { # VOLUMETAG FILENO [DRIVE]
    local vt="$1" fn="$2" D="${3:-}"
    if [ "$BRIC_TAPE_BACKEND" = sim ]; then
        _tape_sim_stream_file "$vt" "$fn"
        return $?
    fi
    command -v mtx >/dev/null && command -v mt >/dev/null && command -v dd >/dev/null || die "need mtx, mt, dd for real backend"
    [ -n "$D" ] || D="$(_first_drive)"
    (
        flock 6 || die "drive $D busy"
        bric_close_daemon_singleton_fds
        export BRIC_LOG_DRIVE="$D" BRIC_LOG_VOLUMETAG="$vt"
        local dev io_timeout; dev="$(_real_drive_dev "$vt" "$D")"; io_timeout="$(_drive_io_timeout "$D" "$BRIC_TAPE_IO_TIMEOUT")"
        bric_event INFO TAPE_READ_BEGIN "device=$dev file_number=$fn destination=stdout mode=absolute-stream"
        _mt "$dev" setblk 0 >/dev/null 2>&1 || bric_event WARN DRIVE_SETBLK_FAILED "device=$dev continuing with current block mode"
        _run_logged DRIVE_REWIND "$BRIC_DRIVE_COMMAND_TIMEOUT" mt -f "$dev" rewind || die "drive $D rewind failed"
        if [ "$fn" -gt 1 ]; then
            _run_logged DRIVE_FSF "$BRIC_DRIVE_COMMAND_TIMEOUT" mt -f "$dev" fsf "$((fn - 1))" || die "drive $D fsf failed"
        fi
        _run_logged TAPE_STREAM_READ "$io_timeout" dd if="$dev" bs="$BRIC_TAPE_BLOCK" || die "dd read from $dev timed out/failed"
        _wait_drive_ready "$D" "$vt" "post-read"
        bric_event INFO TAPE_READ_END "device=$dev file_number=$fn mode=absolute-stream"
    ) 6>"$(_drive_lock "$D")"
}

# Verification result codes are intentionally distinct from media health policy. The tape I/O layer
# reports what happened; the daemon decides whether a complete-but-wrong stream justifies penalizing
# the cartridge.
#   0  exact byte count and sha256
#   20 transport/local verification failure (read rc, tee/hash/wc, control scratch)
#   21 stream completed cleanly but byte count != expected size (clean short/long media stream)
#   22 exact byte count but sha256 != expected sha
_tape_verify_stream() { # EXPECTED_SIZE EXPECTED_SHA STREAM_FUNCTION ARGS...
    local expected_size="$1" expected_sha="$2"; shift 2
    local ctl fifo countf hashf wpid wc_rc=0 bytes="" got="" rc=0
    local ps=(0 0 0)
    ctl="$(mktemp -d "${TMPDIR:-/tmp}/bric-verify.XXXXXX" 2>/dev/null)" || {
        BRIC_LOG_RC=20 bric_event ERROR TAPE_VERIFY_LOCAL_FAIL "reason=cannot-create-control-dir tmp=${TMPDIR:-/tmp} media_penalty=no"
        return 20
    }
    fifo="$ctl/count.pipe"; countf="$ctl/count"; hashf="$ctl/hash"
    if ! mkfifo "$fifo"; then
        rm -rf "$ctl"
        BRIC_LOG_RC=20 bric_event ERROR TAPE_VERIFY_LOCAL_FAIL "reason=mkfifo-failed media_penalty=no"
        return 20
    fi
    wc -c <"$fifo" >"$countf" & wpid=$!
    # Put the pipeline in an explicit conditional. This remains correct even when a caller itself is
    # running under Bash's errexit-suppressed if/|| dynamic context (the exact Review 31C1 failure).
    if "$@" | tee "$fifo" | sha256sum >"$hashf"; then
        ps=( "${PIPESTATUS[@]}" )
    else
        ps=( "${PIPESTATUS[@]}" )
    fi
    if wait "$wpid"; then wc_rc=0; else wc_rc=$?; fi
    bytes="$(tr -d '[:space:]' <"$countf" 2>/dev/null || true)"
    got="$(awk '{print $1}' "$hashf" 2>/dev/null | head -1)"
    rm -rf "$ctl"
    if [ "${ps[0]:-99}" -ne 0 ] || [ "${ps[1]:-99}" -ne 0 ] || [ "${ps[2]:-99}" -ne 0 ] || [ "$wc_rc" -ne 0 ]; then
        BRIC_LOG_RC=20 bric_event ERROR TAPE_VERIFY_STREAM_FAILED \
            "stream_rc=${ps[0]:-99} tee_rc=${ps[1]:-99} sha_rc=${ps[2]:-99} wc_rc=$wc_rc bytes=${bytes:-unknown} media_penalty=no"
        return 20
    fi
    case "$bytes" in ''|*[!0-9]*)
        BRIC_LOG_RC=20 bric_event ERROR TAPE_VERIFY_LOCAL_FAIL "reason=invalid-byte-count bytes=${bytes:-empty} media_penalty=no"
        return 20;;
    esac
    case "$got" in ''|*[!0-9a-fA-F]* )
        BRIC_LOG_RC=20 bric_event ERROR TAPE_VERIFY_LOCAL_FAIL "reason=invalid-sha256 got=${got:-empty} bytes=$bytes media_penalty=no"
        return 20;;
    esac
    if [ "${#got}" -ne 64 ]; then
        BRIC_LOG_RC=20 bric_event ERROR TAPE_VERIFY_LOCAL_FAIL "reason=invalid-sha256-length length=${#got} bytes=$bytes media_penalty=no"
        return 20
    fi
    if [ "$expected_size" -ge 0 ] 2>/dev/null && [ "$bytes" -ne "$expected_size" ]; then
        BRIC_LOG_RC=21 BRIC_LOG_BYTES="$bytes" bric_event ERROR TAPE_VERIFY_SIZE_MISMATCH \
            "expected_bytes=$expected_size actual_bytes=$bytes sha256=$got media_penalty=caller-policy"
        return 21
    fi
    if [ -n "$expected_sha" ] && [ "$got" != "$expected_sha" ]; then
        BRIC_LOG_RC=22 BRIC_LOG_BYTES="$bytes" bric_event ERROR TAPE_VERIFY_HASH_MISMATCH \
            "expected_sha256=$expected_sha got_sha256=$got bytes=$bytes media_penalty=caller-policy"
        return 22
    fi
    BRIC_LOG_BYTES="$bytes" bric_event INFO TAPE_VERIFY_STREAM_OK "bytes=$bytes sha256=$got scratch=control-only"
    return 0
}

_tape_verify_position_method() { # FILENO EXPECTED_SIZE -> relative | absolute
    local fn="$1" size="$2" mode bps rewind_ms fsf_ms rel_ms abs_ms
    mode="${BRIC_TAPE_VERIFY_POSITION_MODE:-adaptive}"
    case "$mode" in
        relative|absolute) printf '%s\n' "$mode"; return 0;;
        adaptive) :;;
        *) mode=adaptive;;
    esac
    bps="${BRIC_TAPE_BSFM_BYTES_PER_SEC:-210000000}"
    rewind_ms="${BRIC_TAPE_REWIND_MILLISECONDS:-46000}"
    fsf_ms="${BRIC_TAPE_FSF_MILLISECONDS_PER_FILE:-400}"
    case "$bps" in ''|*[!0-9]*|0) bps=210000000;; esac
    case "$rewind_ms" in ''|*[!0-9]*) rewind_ms=46000;; esac
    case "$fsf_ms" in ''|*[!0-9]*) fsf_ms=400;; esac
    case "$fn" in ''|*[!0-9]*|0) fn=1;; esac
    case "$size" in ''|*[!0-9]*) size=0;; esac
    # bsfm 2 traverses the just-written payload backwards, so its dominant cost scales with bytes.
    # Absolute positioning pays one rewind plus approximately one filemark-spacing cost per prior file.
    rel_ms=$(( (size * 1000 + bps - 1) / bps ))
    abs_ms=$(( rewind_ms + (fn - 1) * fsf_ms ))
    if [ "$rel_ms" -le "$abs_ms" ]; then printf 'relative\n'; else printf 'absolute\n'; fi
}

tape_verify_file_immediate() { # VOLUMETAG FILENO EXPECTED_SIZE EXPECTED_SHA [DRIVE]
    local vt="$1" fn="$2" expected_size="$3" expected_sha="$4" D="${5:-}" method bps rewind_ms fsf_ms rel_ms abs_ms
    if [ "$BRIC_TAPE_BACKEND" = sim ]; then
        _tape_verify_stream "$expected_size" "$expected_sha" tape_stream_file_immediate "$vt" "$fn" "$D"
        return $?
    fi
    method="$(_tape_verify_position_method "$fn" "$expected_size")"
    bps="${BRIC_TAPE_BSFM_BYTES_PER_SEC:-210000000}"; case "$bps" in ''|*[!0-9]*|0) bps=210000000;; esac
    rewind_ms="${BRIC_TAPE_REWIND_MILLISECONDS:-46000}"; case "$rewind_ms" in ''|*[!0-9]*) rewind_ms=46000;; esac
    fsf_ms="${BRIC_TAPE_FSF_MILLISECONDS_PER_FILE:-400}"; case "$fsf_ms" in ''|*[!0-9]*) fsf_ms=400;; esac
    rel_ms=$(( (expected_size * 1000 + bps - 1) / bps ))
    abs_ms=$(( rewind_ms + (fn - 1) * fsf_ms ))
    BRIC_LOG_BYTES="$expected_size" bric_event INFO TAPE_VERIFY_POSITION_SELECT \
        "file_number=$fn method=$method estimated_relative_ms=$rel_ms estimated_absolute_ms=$abs_ms bsfm_bytes_per_sec=$bps rewind_ms=$rewind_ms fsf_ms_per_file=$fsf_ms"
    case "$method" in
        relative) _tape_verify_stream "$expected_size" "$expected_sha" tape_stream_file_immediate "$vt" "$fn" "$D";;
        absolute) _tape_verify_stream "$expected_size" "$expected_sha" tape_stream_file "$vt" "$fn" "$D";;
        *) return 20;;
    esac
}

tape_verify_file() { # VOLUMETAG FILENO EXPECTED_SIZE EXPECTED_SHA [DRIVE]
    local vt="$1" fn="$2" expected_size="$3" expected_sha="$4" D="${5:-}"
    _tape_verify_stream "$expected_size" "$expected_sha" tape_stream_file "$vt" "$fn" "$D"
}

tape_sniff_first_block() {
    local vt="$1" fn="$2" dest="$3" D="${4:-}"
    if [ "$BRIC_TAPE_BACKEND" = sim ]; then
        export BRIC_LOG_DRIVE="${D:-sim}" BRIC_LOG_VOLUMETAG="$vt"
        bric_event INFO TAPE_SNIFF_BEGIN "backend=sim file_number=$fn"
        if head -c "$BRIC_TAPE_BLOCK" "$BRIC_TAPELIB/$vt/$(printf 'f_%06d' "$fn")" > "$dest" 2>"$dest.err"; then
            rm -f "$dest.err"
            BRIC_LOG_BYTES="$(stat -c %s "$dest" 2>/dev/null || echo 0)" bric_event INFO TAPE_SNIFF_END "backend=sim file_number=$fn"
            return 0
        fi
        local rc=$? detail; detail="$(tr '\r\n|' '   ' <"$dest.err" | head -c 2000)"; rm -f "$dest.err"
        BRIC_LOG_RC="$rc" bric_event ERROR TAPE_SNIFF_FAIL "backend=sim file_number=$fn stderr=$detail"
        return "$rc"
    fi
    [ -n "$D" ] || D="$(_first_drive)"
    (
        flock 6 || die "drive $D busy"
        bric_close_daemon_singleton_fds
        export BRIC_LOG_DRIVE="$D" BRIC_LOG_VOLUMETAG="$vt"
        local dev io_timeout; dev="$(_real_drive_dev "$vt" "$D")"; io_timeout="$(_drive_io_timeout "$D" "$BRIC_TAPE_IO_TIMEOUT")"
        bric_event INFO TAPE_SNIFF_BEGIN "device=$dev file_number=$fn"
        _mt "$dev" setblk 0 >/dev/null 2>&1 || bric_event WARN DRIVE_SETBLK_FAILED "device=$dev continuing"
        _run_logged DRIVE_REWIND "$BRIC_DRIVE_COMMAND_TIMEOUT" mt -f "$dev" rewind || die "drive $D rewind failed"
        [ "$fn" -gt 1 ] && _run_logged DRIVE_FSF "$BRIC_DRIVE_COMMAND_TIMEOUT" mt -f "$dev" fsf "$((fn - 1))"
        _run_logged TAPE_SNIFF_READ "$io_timeout" dd if="$dev" of="$dest" bs="$BRIC_TAPE_BLOCK" count=1 || die "dd sniff from $dev timed out/failed"
        _wait_drive_ready "$D" "$vt" "post-sniff"
        bric_event INFO TAPE_SNIFF_END "device=$dev file_number=$fn"
    ) 6>"$(_drive_lock "$D")"
}

tape_last_file_number() {
    local vt="$1" D="${2:-}"
    if [ "$BRIC_TAPE_BACKEND" = sim ]; then
        local d="$BRIC_TAPELIB/$vt"; [ -d "$d" ] || { echo 0; return; }
        find "$d" -maxdepth 1 -type f -name 'f_*' | wc -l | tr -d ' '; return 0
    fi
    [ -n "$D" ] || D="$(_first_drive)"
    (
        flock 6 || die "drive $D busy"
        bric_close_daemon_singleton_fds
        export BRIC_LOG_DRIVE="$D" BRIC_LOG_VOLUMETAG="$vt"
        local dev n; dev="$(_real_drive_dev "$vt" "$D")"; _assert_contiguous_file_mode "$dev" "$D"; _run_logged DRIVE_EOD "$BRIC_DRIVE_COMMAND_TIMEOUT" mt -f "$dev" eod || die "drive $D eod failed"
        _wait_drive_ready "$D" "$vt" "last-file query"
        n="$(_mt_filenum "$dev")"
        case "$n" in ''|*[!0-9]*) die "drive $D returned invalid EOD file number: '${n:-empty}'";; esac
        echo "$n"
    ) 6>"$(_drive_lock "$D")"
}

# Return every configured cartridge to a slot.  With two drives, readiness and eject are waited in
# parallel (each drive may take a different time); the robot moves are then serialized under the
# changer lock.  The function returns only after inventory confirms BOTH drives empty.
tape_release_all() {
    [ "$BRIC_TAPE_BACKEND" = real ] || return 0
    bric_event INFO MEDIA_RELEASE_BEGIN "drives=$BRIC_TAPE_DRIVES unload_on_complete=${BRIC_UNLOAD_ON_COMPLETE:-1}"
    [ "${BRIC_UNLOAD_ON_COMPLETE:-1}" = 1 ] || return 0
    local IFS=$' \t\n' drives=() D work_rc=0
    for D in $BRIC_TAPE_DRIVES; do drives+=("$D"); done
    [ "${#drives[@]}" -gt 0 ] || return 0
    if [ "${#drives[@]}" -ge 2 ]; then
        local d0="${drives[0]}" d1="${drives[1]}" l0 l1 first second
        l0="$(_drive_lock "$d0")"; l1="$(_drive_lock "$d1")"
        if [ "$d0" -lt "$d1" ] 2>/dev/null; then first="$l0"; second="$l1"; else first="$l1"; second="$l0"; fi
        work_rc=0
        (
            flock 6 || die "drive lock busy: $first"
            flock 7 || die "drive lock busy: $second"
            bric_close_daemon_singleton_fds
            local st vt0 vt1 os0 os1 p0=0 p1=0 r0=0 r1=0 dev0 dev1 statefile
            statefile="$(mktemp "${TMPDIR:-/tmp}/bric-release.XXXXXX")" || die "cannot create release-state scratch"
            (
                flock 8 || die "changer busy"
                st="$(_status)" || die "cannot read changer status before final release"
                printf '%s\n%s\n%s\n%s\n' "$(_drive_vt "$st" "$d0")" "$(_drive_slot "$st" "$d0")" "$(_drive_vt "$st" "$d1")" "$(_drive_slot "$st" "$d1")"
            ) 8>"$BRIC_CHANGER_LOCK" >"$statefile" || die "cannot snapshot changer state before final release"
            { IFS= read -r vt0; IFS= read -r os0; IFS= read -r vt1; IFS= read -r os1; } <"$statefile"                 || die "cannot read release-state scratch"
            rm -f "$statefile"
            if [ -n "$vt0" ]; then ( _wait_drive_ready "$d0" "$vt0" "final eject" ) & p0=$!; fi
            if [ -n "$vt1" ]; then ( _wait_drive_ready "$d1" "$vt1" "final eject" ) & p1=$!; fi
            [ "$p0" -eq 0 ] || wait "$p0" || r0=$?
            [ "$p1" -eq 0 ] || wait "$p1" || r1=$?
            [ "$r0" -eq 0 ] && [ "$r1" -eq 0 ] || die "drive readiness before final eject failed: $d0 rc=$r0, $d1 rc=$r1"
            dev0="$(_drive_dev "$d0")"; dev1="$(_drive_dev "$d1")"
            p0=0; p1=0; r0=0; r1=0
            if [ -n "$vt0" ]; then ( BRIC_LOG_DRIVE="$d0" BRIC_LOG_VOLUMETAG="$vt0" _run_logged DRIVE_OFFLINE "$BRIC_DRIVE_COMMAND_TIMEOUT" mt -f "$dev0" offline >/dev/null || true ) & p0=$!; fi
            if [ -n "$vt1" ]; then ( BRIC_LOG_DRIVE="$d1" BRIC_LOG_VOLUMETAG="$vt1" _run_logged DRIVE_OFFLINE "$BRIC_DRIVE_COMMAND_TIMEOUT" mt -f "$dev1" offline >/dev/null || true ) & p1=$!; fi
            [ "$p0" -eq 0 ] || wait "$p0" || r0=$?
            [ "$p1" -eq 0 ] || wait "$p1" || r1=$?
            # Even if a drive's explicit offline returned non-zero, let the changer retry unload;
            # some libraries perform the eject as part of mtx unload.
            flock 8 || die "changer busy"
            st="$(_status)" || die "cannot read changer status while confirming final release"
            vt0="$(_drive_vt "$st" "$d0")"; os0="$(_drive_slot "$st" "$d0")"
            vt1="$(_drive_vt "$st" "$d1")"; os1="$(_drive_slot "$st" "$d1")"
            [ -z "$vt0" ] || { [ -n "$os0" ] || die "origin slot unknown for $vt0 in drive $d0"; _changer_unload_confirm_locked "$d0" "$vt0" "$os0"; }
            [ -z "$vt1" ] || { [ -n "$os1" ] || die "origin slot unknown for $vt1 in drive $d1"; _changer_unload_confirm_locked "$d1" "$vt1" "$os1"; }
        ) 6>"$first" 7>"$second" 8>"$BRIC_CHANGER_LOCK" || work_rc=$?
        if [ "$work_rc" -ne 0 ]; then
            BRIC_LOG_RC="$work_rc" bric_event ERROR MEDIA_RELEASE_FAILED                 "drives=$d0,$d1 phase=paired-release confirmed_empty=no"
            return "$work_rc"
        fi
        # Any additional configured drives are handled one by one below.
        drives=("${drives[@]:2}")
    fi
    for D in "${drives[@]}"; do
        work_rc=0
        (
            flock 6 || die "drive $D busy"
            flock 8 || die "changer busy"
            bric_close_daemon_singleton_fds
            local st vt os
            st="$(_status)" || die "cannot read changer status while releasing drive $D"
            vt="$(_drive_vt "$st" "$D")"
            [ -z "$vt" ] && exit 0
            os="$(_drive_slot "$st" "$D")"; [ -n "$os" ] || die "origin slot unknown for $vt in drive $D"
            _unload_drive_locked "$D" "$vt" "$os"
        ) 6>"$(_drive_lock "$D")" 8>"$BRIC_CHANGER_LOCK" || work_rc=$?
        if [ "$work_rc" -ne 0 ]; then
            BRIC_LOG_RC="$work_rc" BRIC_LOG_DRIVE="$D" bric_event ERROR MEDIA_RELEASE_FAILED                 "drive=$D phase=single-release confirmed_empty=no"
            return "$work_rc"
        fi
    done
    bric_event INFO MEDIA_RELEASE_DONE "drives=$BRIC_TAPE_DRIVES confirmed_empty=yes"
    log "all configured drives are empty; media returned to slots"
    return 0
}

tape_list_volumetags() {
    if [ "$BRIC_TAPE_BACKEND" = sim ]; then
        [ -d "$BRIC_TAPELIB" ] && ls "$BRIC_TAPELIB" 2>/dev/null || true; return 0
    fi
    _mtx status 2>/dev/null | sed -n 's/.*VolumeTag *= *\([A-Za-z0-9]\{1,\}\).*/\1/p' | sort -u
}

# Fast, READ-ONLY hardware gate for the real backend (~1-2 s; no-op in sim). Run at the START of any
# process that will drive the library (daemon, DR, rebuild, smoke): it refuses to proceed against
# hardware that is visibly broken, with an explicit diagnosis, instead of failing mid-operation with
# a cryptic mtx/mt error. Deliberately NOT called per-chunk: _load already fails loudly mid-flight,
# and taxing the hot path buys nothing. Escape hatch for hardware troubleshooting sessions:
# BRIC_SKIP_HW_CHECK=1 skips the gate (logged).
# Checks: device nodes exist; mtx status answers; at least one configured drive element is visible;
# changer sense is not the blocking 'manual intervention required' (0x02/04/03) condition.
tape_hw_quickcheck() {
    [ "$BRIC_TAPE_BACKEND" = real ] || return 0
    if [ -n "${BRIC_SKIP_HW_CHECK:-}" ]; then log "hw quickcheck SKIPPED (BRIC_SKIP_HW_CHECK set)"; return 0; fi
    # Callers (the daemon) run with IFS=$'\n\t': localize a space-including IFS or the
    # space-separated BRIC_TAPE_DRIVES list ("0 1") would be treated as ONE element.
    local IFS=$' \t\n'
    [ -e "$BRIC_CHANGER" ] || die "hw quickcheck: changer node missing: $BRIC_CHANGER"
    local D dev seen=0 st
    for D in $BRIC_TAPE_DRIVES; do
        dev="$(_drive_dev "$D")"
        [ -e "$dev" ] || die "hw quickcheck: drive $D node missing: $dev"
        _assert_contiguous_file_mode "$dev" "$D"
    done
    st="$(_mtx status 2>&1)" || die "hw quickcheck: mtx status failed on $BRIC_CHANGER: $(printf '%s' "$st" | head -1) — run tape/bin/bric-library-preflight for a full diagnosis"
    for D in $BRIC_TAPE_DRIVES; do
        printf '%s\n' "$st" | grep -q "^Data Transfer Element $D:" && seen=1
    done
    [ "$seen" = 1 ] || die "hw quickcheck: none of the configured drive elements ($BRIC_TAPE_DRIVES) is visible to the changer — check BRIC_TAPE_DRIVES / cabling; run bric-library-preflight"
    if command -v sg_requests >/dev/null 2>&1; then
        local sense; sense="$(sg_requests -s "$BRIC_CHANGER" 2>&1 || true)"
        if printf '%s' "$sense" | grep -Eqi 'asc=0?x?04.*ascq=0?x?03|manual intervention'; then
            die "hw quickcheck: changer reports 'manual intervention required' (sense 0x02/ASC 0x04/ASCQ 0x03) — robotics BLOCKED; power-cycle the library / open a hardware case. Refusing to start."
        fi
    fi
    log "hw quickcheck passed (changer=$BRIC_CHANGER drives=$BRIC_TAPE_DRIVES)"
    return 0
}

# Performance note for the real backend: the daemon writes PRIMARY then BACKUP per chunk, which on a
# single drive forces a load/unload per copy. With BRIC_TAPE_DRIVES="0 1" the two copies go to two
# drives concurrently (set parallel_drives=2). Otherwise, batching all PRIMARY writes of a run before
# the BACKUP writes minimises mounts; left as an optimisation since correctness is drive-count agnostic.
