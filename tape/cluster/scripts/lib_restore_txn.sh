#!/bin/bash
# Review 33R3 restore metadata transaction.
# Keeps destination directories traversable while payload is restored/verified, then reapplies the
# metadata that the archive restored. The SQLite journal is private, host-local, bound to one
# canonical DEST, and survives crashes so restrictive directory modes cannot strand a restore.
#
# This helper does NOT claim that BRIC-FORMAT-V1 archives source ACLs/xattrs. ACL/xattr snapshots
# only protect destination metadata while BRIC temporarily relaxes directory traversal.

rtxn_log(){
    if declare -F log >/dev/null 2>&1; then log "$*"; else printf '[restore-txn] %s\n' "$*" >&2; fi
}
rtxn_warn(){
    if declare -F warn_log >/dev/null 2>&1; then warn_log "$*"; else printf '[restore-txn] WARN: %s\n' "$*" >&2; fi
}
rtxn_sql_quote(){ printf '%s' "$1" | sed "s/'/''/g"; }
rtxn_sql(){ sqlite3 -batch -cmd '.timeout 60000' "$RTXN_DB" "$1"; }
rtxn_sqla(){ sqlite3 -batch -cmd '.timeout 60000' "$RTXN_DB" '.mode ascii' "$1"; }
rtxn_hex(){ printf '%s' "$1" | od -An -tx1 -v | tr -d ' \n'; }
rtxn_unhex_var(){ local __var="$1" h="${2:-}" esc; esc="$(printf '%s' "$h" | sed 's/../\\x&/g')"; printf -v "$__var" '%b' "$esc"; }
rtxn_b64_file(){ base64 | tr -d '\n'; }
rtxn_b64_decode(){ printf '%s' "$1" | base64 -d 2>/dev/null; }
rtxn_depth(){ local x="$1" n=0; while [[ "$x" == */* ]]; do n=$((n+1)); x="${x#*/}"; done; printf '%s' "$n"; }

rtxn_proc_start_token(){
    local pid="$1" line rest
    [ -r "/proc/$pid/stat" ] || return 1
    IFS= read -r line < "/proc/$pid/stat" || return 1
    rest="${line##*) }"
    [ "$rest" != "$line" ] || return 1
    # /proc/PID/stat field 22 (starttime) is field 20 after removing "pid (comm) ".
    awk '{print $20}' <<< "$rest"
}

rtxn_path_lex_normalize(){ # absolute path; lexical normalization only, newline-safe
    local p="$1" rest part out="" idx; local -a stack=()
    case "$p" in /*) :;; *) return 1;; esac
    rest="${p#/}"
    while :; do
        part="${rest%%/*}"
        case "$part" in
            ''|.) :;;
            ..)
                [ "${#stack[@]}" -gt 0 ] || return 1
                idx=$(( ${#stack[@]} - 1 )); unset "stack[$idx]";;
            *) stack+=("$part");;
        esac
        [ "$rest" = "$part" ] && break
        rest="${rest#*/}"
    done
    for part in "${stack[@]}"; do out="$out/$part"; done
    [ -n "$out" ] || out=/
    printf '%s' "$out"
}
rtxn_path_under_dest(){
    local p="$1" dest="$2" norm
    norm="$(rtxn_path_lex_normalize "$p")" || return 1
    case "$norm" in "$dest"|"$dest"/*) return 0;; *) return 1;; esac
}

# Live mutation guard: require lexical containment, reject symlink components, and also require the
# path resolved through existing filesystem objects to stay below the canonical destination.
# readlink -m is intentional here: APPLYING rows may name a directory that tar has not created yet.
rtxn_live_path_safe(){
    local p="$1" dest="${2:-${RTXN_DEST:-}}" norm rel cur rest part resolved
    [ -n "$dest" ] || { rtxn_warn "restore transaction destination is unset"; return 1; }
    norm="$(rtxn_path_lex_normalize "$p")" || { rtxn_warn "invalid restore path: $p"; return 1; }
    rtxn_path_under_dest "$norm" "$dest" || { rtxn_warn "restore path escapes destination: $p"; return 1; }
    if [ "$norm" != "$dest" ]; then
        rel="${norm#"$dest"/}"; cur="$dest"; rest="$rel"
        while [ -n "$rest" ]; do
            part="${rest%%/*}"; cur="$cur/$part"
            [ ! -L "$cur" ] || { rtxn_warn "symlinked restore ancestor refused: $cur"; return 1; }
            [ -e "$cur" ] || break
            [ "$rest" = "$part" ] && break
            rest="${rest#*/}"
        done
    fi
    resolved="$(readlink -m -- "$norm")" || return 1
    case "$resolved" in "$dest"|"$dest"/*) return 0;;
        *) rtxn_warn "resolved restore path escapes destination: $p -> $resolved"; return 1;;
    esac
}


rtxn_prepare_journal_base(){ # configured shared base -> canonical base
    local base="$1" mode mode_num fs canon owner
    if [ -e "$base" ] || [ -L "$base" ]; then
        [ -d "$base" ] && [ ! -L "$base" ] || { rtxn_warn "restore journal base is not a safe directory: $base"; return 1; }
    else
        # A configured base is shared between UIDs. Create it like /tmp; privacy is enforced on <base>/<uid>.
        ( umask 022; mkdir -p -- "$base" ) || return 1
    fi
    [ -d "$base" ] && [ ! -L "$base" ] || { rtxn_warn "restore journal base is not a safe directory: $base"; return 1; }
    fs="$(stat -f -c %T -- "$base" 2>/dev/null || echo unknown)"
    case "$fs" in nfs|nfs4|cifs|smb2|9p|fuse.sshfs) rtxn_warn "restore journal base must be local, not $fs: $base"; return 1;;
        unknown|'') rtxn_warn "cannot determine filesystem type for restore journal base: $base"; return 1;; esac
    mode="$(stat -c %a -- "$base" 2>/dev/null || echo '')"
    owner="$(stat -c %u -- "$base" 2>/dev/null || echo x)"
    case "$mode" in ''|*[!0-7]*) rtxn_warn "cannot determine restore journal base mode: $base"; return 1;; esac
    mode_num=$((8#$mode))
    # If this caller created/owns the configured base, normalize it to a sticky shared directory.
    if { [ $((mode_num & 01000)) -eq 0 ] || [ $((mode_num & 0007)) -ne 0007 ]; } && [ "$owner" = "$(id -u)" ]; then
        chmod 1777 -- "$base" || return 1
        mode="$(stat -c %a -- "$base" 2>/dev/null || echo '')"; mode_num=$((8#$mode))
    fi
    [ $((mode_num & 01000)) -ne 0 ] && [ $((mode_num & 0007)) -eq 0007 ] || {
        rtxn_warn "configured restore journal base must be sticky and world rwx (1777-style): $base mode=$mode"; return 1;
    }
    canon="$(readlink -f -- "$base")" || return 1
    printf '%s' "$canon"
}

rtxn_prepare_journal_root(){ # root -> canonical root
    local root="$1" uid mode mode_num fs canon
    uid="$(id -u)"
    if [ -e "$root" ] || [ -L "$root" ]; then
        [ -d "$root" ] && [ ! -L "$root" ] || { rtxn_warn "restore journal root is not a safe directory: $root"; return 1; }
    else
        # Scope the restrictive umask to creation only. Never change the restore process's umask.
        ( umask 077; mkdir -p -- "$root" ) || return 1
    fi
    [ -d "$root" ] && [ ! -L "$root" ] || { rtxn_warn "restore journal root is not a safe directory: $root"; return 1; }
    [ "$(stat -c %u -- "$root" 2>/dev/null || echo x)" = "$uid" ] || { rtxn_warn "restore journal root is not owned by uid $uid: $root"; return 1; }
    mode="$(stat -c %a -- "$root" 2>/dev/null || echo '')"
    case "$mode" in ''|*[!0-7]*) rtxn_warn "cannot determine restore journal root mode: $root"; return 1;; esac
    mode_num=$((8#$mode))
    [ $((mode_num & 0022)) -eq 0 ] || { rtxn_warn "restore journal root is group/other writable: $root mode=$mode"; return 1; }
    fs="$(stat -f -c %T -- "$root" 2>/dev/null || echo unknown)"
    case "$fs" in nfs|nfs4|cifs|smb2|9p|fuse.sshfs) rtxn_warn "restore journal root must be local, not $fs: $root"; return 1;;
        unknown|'') rtxn_warn "cannot determine filesystem type for restore journal root: $root"; return 1;; esac
    chmod 700 -- "$root" || return 1
    canon="$(readlink -f -- "$root")" || return 1
    printf '%s' "$canon"
}

rtxn_validate_journal_file(){
    local db="$1" uid mode mode_num
    uid="$(id -u)"
    [ -f "$db" ] && [ ! -L "$db" ] || { rtxn_warn "restore journal is not a safe regular file: $db"; return 1; }
    [ "$(stat -c %u -- "$db" 2>/dev/null || echo x)" = "$uid" ] || { rtxn_warn "restore journal is not owned by uid $uid: $db"; return 1; }
    mode="$(stat -c %a -- "$db" 2>/dev/null || echo '')"
    case "$mode" in ''|*[!0-7]*) return 1;; esac
    mode_num=$((8#$mode))
    [ $((mode_num & 0022)) -eq 0 ] || { rtxn_warn "restore journal is group/other writable: $db mode=$mode"; return 1; }
    return 0
}

rtxn_acl_dump(){
    local p="$1" raw
    command -v getfacl >/dev/null 2>&1 || return 0
    raw="$(getfacl -cp -- "$p" 2>/dev/null || true)"
    # getfacl synthesizes user::/group::/other:: from ordinary mode bits even when no extended
    # POSIX ACL exists. Do not arm a later setfacl for that trivial case; chmod restores it exactly.
    printf '%s\n' "$raw" | grep -Eq '^(default:|user:[^:]|group:[^:]|mask::)' || return 0
    printf '%s\n' "$raw" | rtxn_b64_file
}
rtxn_xattr_dump(){
    local p="$1"
    # Explicit metadata-degradation is permitted only for a fresh/empty destination by bric-restore.
    # Do not snapshot ACL/xattr state that this recovery mode has explicitly declared non-authoritative.
    [ "${BRIC_RESTORE_ALLOW_METADATA_DEGRADATION:-0}" != 1 ] || return 0
    command -v getfattr >/dev/null 2>&1 || return 0
    # Review 34 keeps user.* plus the explicitly supported NFSv4 ACL xattr.  POSIX ACLs remain
    # handled by getfacl/setfacl; security.*, trusted.* and other system.* namespaces stay excluded.
    getfattr -d -m '^(user\.|system\.nfs4_acl$)' --absolute-names -- "$p" 2>/dev/null | rtxn_b64_file
}
rtxn_fields_fingerprint(){ # mode acl_b64 xattr_b64
    printf '%s\n%s\n%s' "$1" "$2" "$3" | sha256sum | awk '{print $1}'
}
rtxn_fingerprint(){
    local p="$1" mode acl xa
    [ -d "$p" ] || { printf 'MISSING'; return 0; }
    mode="$(stat -c '%a' -- "$p" 2>/dev/null || printf '?')"
    acl="$(rtxn_acl_dump "$p" 2>/dev/null || true)"
    xa="$(rtxn_xattr_dump "$p" 2>/dev/null || true)"
    rtxn_fields_fingerprint "$mode" "$acl" "$xa"
}
rtxn_snapshot_fields(){ # path -> mode<US>acl_b64<US>xattr_b64
    local p="$1" mode acl xa
    mode="$(stat -c '%a' -- "$p")" || return 1
    acl="$(rtxn_acl_dump "$p" 2>/dev/null || true)"
    xa="$(rtxn_xattr_dump "$p" 2>/dev/null || true)"
    # Use ASCII Unit Separator, not TAB: TAB is IFS whitespace and consecutive TABs collapse,
    # shifting xattr data into the ACL field when acl_b64 is empty.
    printf '%s\x1f%s\x1f%s\n' "$mode" "$acl" "$xa"
}
rtxn_apply_snapshot(){ # path existed mode acl_b64 xattr_b64
    local p="$1" existed="$2" mode="$3" acl="$4" xa="$5" t
    if [ "$existed" != 1 ]; then
        # A tar-created directory has no pre-crash metadata snapshot. Keep it traversable for retry,
        # but signal an unresolved orphan so the journal is never discarded silently.
        [ ! -d "$p" ] || chmod u+rwx -- "$p" 2>/dev/null || true
        return 3
    fi
    [ -d "$p" ] || { rtxn_warn "journal target disappeared: $p"; return 1; }
    chmod u+rwx -- "$p" 2>/dev/null || true
    if [ "${BRIC_RESTORE_ALLOW_METADATA_DEGRADATION:-0}" != 1 ]; then
        if [ -n "$acl" ] && command -v setfacl >/dev/null 2>&1; then
            t="$(mktemp)" || return 1
            if ! rtxn_b64_decode "$acl" >"$t"; then rm -f "$t"; return 1; fi
            if ! setfacl --set-file="$t" -- "$p" 2>"$t.err"; then
                rtxn_warn "cannot restore POSIX ACL for $p: $(tr '\n' ' ' <"$t.err" 2>/dev/null || true)"
                rm -f "$t" "$t.err"; return 1
            fi
            rm -f "$t" "$t.err"
        fi
    elif [ -n "$acl" ]; then
        rtxn_warn "metadata degradation: POSIX ACL journal replay skipped for $p"
    fi
    chmod "$mode" -- "$p" || return 1
    if [ "${BRIC_RESTORE_ALLOW_METADATA_DEGRADATION:-0}" != 1 ]; then
        if [ -n "$xa" ] && command -v setfattr >/dev/null 2>&1; then
            t="$(mktemp)" || return 1
            if ! rtxn_b64_decode "$xa" >"$t"; then rm -f "$t"; return 1; fi
            if ! setfattr --restore="$t" 2>"$t.err"; then
                rtxn_warn "cannot restore xattrs/NFSv4 ACL for $p: $(tr '\n' ' ' <"$t.err" 2>/dev/null || true)"
                rm -f "$t" "$t.err"; return 1
            fi
            rm -f "$t" "$t.err"
        fi
    elif [ -n "$xa" ]; then
        rtxn_warn "metadata degradation: xattr/NFSv4 ACL journal replay skipped for $p"
    fi
    return 0
}
rtxn_relax_path(){
    local p="$1" probe
    rtxn_live_path_safe "$p" "$RTXN_DEST" || return 1
    [ ! -L "$p" ] || return 0
    [ -d "$p" ] || return 0
    chmod u+rwx -- "$p" || return 1
    # chmod(2) success is not proof of effective create/delete permission on ACL-governed NFS.
    # Verify the property the restore actually needs before allowing tar/dd to continue.
    probe="$p/.bric-restore-write-probe.${BASHPID:-$$}.${RANDOM:-0}"
    if ! ( umask 077; : > "$probe" ) 2>/dev/null; then
        rtxn_warn "directory relaxation returned success but create/write is still denied: $p"
        return 1
    fi
    if ! rm -f -- "$probe" 2>/dev/null; then
        rtxn_warn "directory relaxation permits create but not unlink: $p"
        return 1
    fi
    return 0
}

rtxn_validate_db_binding(){ # validates meta.dest + every row before any mutation
    local expected="$1" meta_hex meta_dest h p
    meta_hex="$(rtxn_sql "SELECT hex(value) FROM meta WHERE key='dest';" 2>/dev/null || true)"
    [ -n "$meta_hex" ] || { rtxn_warn "restore journal has no destination binding: $RTXN_DB"; return 2; }
    rtxn_unhex_var meta_dest "$meta_hex"
    [ "$meta_dest" = "$expected" ] || { rtxn_warn "restore journal destination mismatch: expected $expected"; return 2; }
    while IFS= read -r h; do
        [ -n "$h" ] || continue
        rtxn_unhex_var p "$h"
        rtxn_path_under_dest "$p" "$expected" || { rtxn_warn "restore journal path escapes destination; refusing recovery: $p"; return 2; }
        rtxn_live_path_safe "$p" "$expected" || { rtxn_warn "restore journal path is unsafe after resolution; refusing recovery: $p"; return 2; }
    done < <(rtxn_sql "SELECT path_hex FROM dirs ORDER BY depth ASC,length(path_hex) ASC;" 2>/dev/null)
    return 0
}

rtxn_recover_db(){ # existing journal path; RTXN_DEST must be current canonical DEST
    local db="$1" old_db="${RTXN_DB:-}" h state existed mode acl xa fp p now expected rc=0 orphan=0 apply_rc
    RTXN_DB="$db"
    [ -s "$RTXN_DB" ] || { rm -f "$RTXN_DB"; RTXN_DB="$old_db"; return 0; }
    rtxn_validate_db_binding "$RTXN_DEST" || { rc=$?; RTXN_DB="$old_db"; return "$rc"; }

    # Fail closed on third-party drift BEFORE changing any mode. APPLYING is excluded because tar may
    # legitimately have changed it before the crash. RELAXED must match its post-relax fingerprint;
    # RECORDED must still match its stored snapshot.
    while IFS=$'\x1f' read -r -d $'\x1e' h state existed mode acl xa fp; do
        rtxn_unhex_var p "$h"
        [ "$existed" = 1 ] || continue
        [ -d "$p" ] || { rtxn_warn "restore journal target disappeared: $p"; RTXN_DB="$old_db"; return 2; }
        case "$state" in
            RELAXED)
                if [ -n "$fp" ]; then now="$(rtxn_fingerprint "$p")"; [ "$now" = "$fp" ] || { rtxn_warn "metadata drift detected during stale recovery; refusing to modify $p"; RTXN_DB="$old_db"; return 2; }; fi;;
            RECORDED)
                expected="$(rtxn_fields_fingerprint "$mode" "$acl" "$xa")"; now="$(rtxn_fingerprint "$p")"
                [ "$now" = "$expected" ] || { rtxn_warn "metadata drift detected before relaxation; refusing to modify $p"; RTXN_DB="$old_db"; return 2; };;
        esac
    done < <(rtxn_sqla "SELECT path_hex,state,existed,COALESCE(mode,''),COALESCE(acl_b64,''),COALESCE(xattr_b64,''),COALESCE(relaxed_fp,'') FROM dirs ORDER BY depth ASC,length(path_hex) ASC;")

    rtxn_log "recovering stale restore metadata journal: $RTXN_DB"
    while IFS=$'\x1f' read -r -d $'\x1e' h state; do
        rtxn_unhex_var p "$h"
        [ ! -d "$p" ] || chmod u+rwx -- "$p" 2>/dev/null || rc=1
    done < <(rtxn_sqla "SELECT path_hex,state FROM dirs ORDER BY depth ASC,length(path_hex) ASC;")

    while IFS=$'\x1f' read -r -d $'\x1e' h state existed mode acl xa; do
        rtxn_unhex_var p "$h"
        if rtxn_apply_snapshot "$p" "$existed" "$mode" "$acl" "$xa"; then apply_rc=0; else apply_rc=$?; fi
        case "$apply_rc" in 0) :;; 3) orphan=1;; *) rc=1;; esac
    done < <(rtxn_sqla "SELECT path_hex,state,existed,COALESCE(mode,''),COALESCE(acl_b64,''),COALESCE(xattr_b64,'') FROM dirs ORDER BY depth DESC,length(path_hex) DESC;")

    if [ "$rc" -ne 0 ]; then
        rtxn_warn "stale restore journal recovery incomplete; journal preserved at $RTXN_DB"
        RTXN_DB="$old_db"; return 1
    fi
    if [ "$orphan" -ne 0 ]; then
        rtxn_warn "stale restore journal contains tar-created directory state; keeping journal for restore retry"
        RTXN_DB="$old_db"; return 3
    fi
    rm -f "$RTXN_DB" "$RTXN_DB-wal" "$RTXN_DB-shm"
    rtxn_log "stale restore metadata journal recovered"
    RTXN_DB="$old_db"
    return 0
}

rtxn_resume_existing(){ # stale journal with unresolved existed=0 rows, already validated/recovered
    local pid proc
    pid="${BASHPID:-$$}"; proc="$(rtxn_proc_start_token "$pid" 2>/dev/null || true)"
    rtxn_sql "INSERT INTO meta(key,value) VALUES('pid','$(rtxn_sql_quote "$pid")') ON CONFLICT(key) DO UPDATE SET value=excluded.value;
              INSERT INTO meta(key,value) VALUES('proc_start','$(rtxn_sql_quote "$proc")') ON CONFLICT(key) DO UPDATE SET value=excluded.value;
              INSERT INTO meta(key,value) VALUES('started_epoch','$(date +%s)') ON CONFLICT(key) DO UPDATE SET value=excluded.value;"
    RTXN_ACTIVE=1; RTXN_PRESERVE=0
    export RTXN_ACTIVE RTXN_PRESERVE RTXN_DB RTXN_DEST
    rtxn_log "restore metadata transaction resumed: $RTXN_DB"
}

rtxn_begin(){ # DEST label
    local dest="$1" label="${2:-restore}" root base uid key canon_base canon_root canon_dest existing_pid existing_proc current_proc rec_rc pid proc
    command -v sqlite3 >/dev/null 2>&1 || { rtxn_warn "sqlite3 missing: cannot start restore metadata transaction"; return 1; }
    command -v base64 >/dev/null 2>&1 || { rtxn_warn "base64 missing: cannot start restore metadata transaction"; return 1; }
    mkdir -p -- "$dest" || return 1
    canon_dest="$(readlink -f -- "$dest")" || return 1
    uid="$(id -u)"
    if [ -n "${BRIC_RESTORE_JOURNAL_ROOT:-}" ]; then
        base="${BRIC_RESTORE_JOURNAL_ROOT%/}"
        canon_base="$(rtxn_prepare_journal_base "$base")" || return 1
        root="$canon_base/$uid"
    else
        root="/var/tmp/bric-restore-journal-$uid"
    fi
    canon_root="$(rtxn_prepare_journal_root "$root")" || return 1
    case "$canon_root/" in "$canon_dest/"*) rtxn_warn "journal root must be outside restore destination: $canon_root"; return 1;; esac
    key="$(printf '%s\0%s' "$canon_dest" "$uid" | sha256sum | awk '{print $1}')"
    RTXN_DB="$canon_root/$key.sqlite"; RTXN_DEST="$canon_dest"; export RTXN_DB RTXN_DEST

    if [ -e "$RTXN_DB" ] || [ -L "$RTXN_DB" ]; then
        rtxn_validate_journal_file "$RTXN_DB" || return 2
        existing_pid="$(sqlite3 -batch "$RTXN_DB" "SELECT value FROM meta WHERE key='pid';" 2>/dev/null || true)"
        existing_proc="$(sqlite3 -batch "$RTXN_DB" "SELECT value FROM meta WHERE key='proc_start';" 2>/dev/null || true)"
        if [ -n "$existing_pid" ] && kill -0 "$existing_pid" 2>/dev/null; then
            current_proc="$(rtxn_proc_start_token "$existing_pid" 2>/dev/null || true)"
            # Unknown process identity is treated conservatively as live. Only a proven start-token
            # mismatch is PID reuse and therefore stale.
            if [ -z "$existing_proc" ] || [ -z "$current_proc" ] || [ "$current_proc" = "$existing_proc" ]; then
                rtxn_warn "another restore metadata transaction appears active for $canon_dest (pid=$existing_pid)"
                return 1
            fi
            rtxn_warn "restore journal pid $existing_pid was reused; treating journal as stale"
        fi
        if rtxn_recover_db "$RTXN_DB"; then rec_rc=0; else rec_rc=$?; fi
        case "$rec_rc" in
            0) :;;
            3) rtxn_resume_existing; return 0;;
            *) return "$rec_rc";;
        esac
    fi

    pid="${BASHPID:-$$}"; proc="$(rtxn_proc_start_token "$pid" 2>/dev/null || true)"
    # Scope umask to journal creation only; do not narrow restored LARGE_FILE_CHUNK permissions.
    ( umask 077; sqlite3 -batch "$RTXN_DB" <<SQL
PRAGMA journal_mode=WAL;
PRAGMA synchronous=FULL;
CREATE TABLE meta(key TEXT PRIMARY KEY,value TEXT NOT NULL);
CREATE TABLE dirs(
 path_hex TEXT PRIMARY KEY,
 depth INTEGER NOT NULL,
 state TEXT NOT NULL CHECK(state IN ('RECORDED','APPLYING','RELAXED')),
 existed INTEGER NOT NULL,
 mode TEXT,
 acl_b64 TEXT,
 xattr_b64 TEXT,
 relaxed_fp TEXT,
 updated_epoch INTEGER NOT NULL
);
INSERT INTO meta VALUES('format','BRIC-RESTORE-JOURNAL-V1');
INSERT INTO meta VALUES('dest','$(rtxn_sql_quote "$canon_dest")');
INSERT INTO meta VALUES('label','$(rtxn_sql_quote "$label")');
INSERT INTO meta VALUES('pid','$(rtxn_sql_quote "$pid")');
INSERT INTO meta VALUES('proc_start','$(rtxn_sql_quote "$proc")');
INSERT INTO meta VALUES('started_epoch','$(date +%s)');
SQL
    ) || return 1
    chmod 600 -- "$RTXN_DB" 2>/dev/null || true
    RTXN_ACTIVE=1; RTXN_PRESERVE=0; export RTXN_ACTIVE RTXN_PRESERVE
    rtxn_log "restore metadata transaction started: $RTXN_DB"
}

rtxn_record_existing(){
    local p="$1" h snap mode acl xa fp depth
    rtxn_live_path_safe "$p" "$RTXN_DEST" || return 1
    [ ! -L "$p" ] || return 0
    [ -d "$p" ] || return 0
    h="$(rtxn_hex "$p")"; depth="$(rtxn_depth "$p")"
    if [ "$(rtxn_sql "SELECT COUNT(*) FROM dirs WHERE path_hex='$h';")" -eq 0 ]; then
        snap="$(rtxn_snapshot_fields "$p")" || return 1
        IFS=$'\x1f' read -r mode acl xa <<< "$snap"
        rtxn_sql "INSERT INTO dirs(path_hex,depth,state,existed,mode,acl_b64,xattr_b64,relaxed_fp,updated_epoch) VALUES('$h',$depth,'RECORDED',1,'$(rtxn_sql_quote "$mode")','$(rtxn_sql_quote "$acl")','$(rtxn_sql_quote "$xa")','',$(date +%s));"
    fi
    rtxn_relax_path "$p" || return 1
    fp="$(rtxn_fingerprint "$p")"
    rtxn_sql "UPDATE dirs SET state='RELAXED',relaxed_fp='$(rtxn_sql_quote "$fp")',updated_epoch=$(date +%s) WHERE path_hex='$h';"
}

rtxn_prepare_ancestors(){
    local rel="$1" part cur="$RTXN_DEST" rest parent
    parent="${rel%/*}"; [ "$parent" != "$rel" ] || return 0
    rest="$parent"
    while [ -n "$rest" ]; do
        part="${rest%%/*}"; cur="$cur/$part"
        if [ -d "$cur" ]; then rtxn_record_existing "$cur" || return 1; else break; fi
        [ "$rest" = "$part" ] && break; rest="${rest#*/}"
    done
}

rtxn_mark_applying(){
    local p="$1" h snap mode acl xa count depth
    rtxn_live_path_safe "$p" "$RTXN_DEST" || return 1
    [ ! -L "$p" ] || return 0
    h="$(rtxn_hex "$p")"; depth="$(rtxn_depth "$p")"; count="$(rtxn_sql "SELECT COUNT(*) FROM dirs WHERE path_hex='$h';")"
    if [ "$count" -eq 0 ]; then
        if [ -d "$p" ]; then
            snap="$(rtxn_snapshot_fields "$p")" || return 1; IFS=$'\x1f' read -r mode acl xa <<< "$snap"
            rtxn_sql "INSERT INTO dirs(path_hex,depth,state,existed,mode,acl_b64,xattr_b64,relaxed_fp,updated_epoch) VALUES('$h',$depth,'APPLYING',1,'$(rtxn_sql_quote "$mode")','$(rtxn_sql_quote "$acl")','$(rtxn_sql_quote "$xa")','',$(date +%s));"
        else
            rtxn_sql "INSERT INTO dirs(path_hex,depth,state,existed,mode,acl_b64,xattr_b64,relaxed_fp,updated_epoch) VALUES('$h',$depth,'APPLYING',0,'','','','',$(date +%s));"
        fi
    else
        rtxn_sql "UPDATE dirs SET state='APPLYING',relaxed_fp='',updated_epoch=$(date +%s) WHERE path_hex='$h';"
    fi
}

rtxn_refresh_relax(){
    local p="$1" h snap mode acl xa fp depth
    rtxn_live_path_safe "$p" "$RTXN_DEST" || return 1
    [ ! -L "$p" ] || return 0
    [ -d "$p" ] || return 0
    h="$(rtxn_hex "$p")"; depth="$(rtxn_depth "$p")"; snap="$(rtxn_snapshot_fields "$p")" || return 1
    IFS=$'\x1f' read -r mode acl xa <<< "$snap"
    rtxn_sql "INSERT INTO dirs(path_hex,depth,state,existed,mode,acl_b64,xattr_b64,relaxed_fp,updated_epoch)
      VALUES('$h',$depth,'RECORDED',1,'$(rtxn_sql_quote "$mode")','$(rtxn_sql_quote "$acl")','$(rtxn_sql_quote "$xa")','',$(date +%s))
      ON CONFLICT(path_hex) DO UPDATE SET depth=excluded.depth,state='RECORDED',existed=1,mode=excluded.mode,acl_b64=excluded.acl_b64,xattr_b64=excluded.xattr_b64,relaxed_fp='',updated_epoch=excluded.updated_epoch;"
    rtxn_relax_path "$p" || return 1; fp="$(rtxn_fingerprint "$p")"
    rtxn_sql "UPDATE dirs SET state='RELAXED',relaxed_fp='$(rtxn_sql_quote "$fp")',updated_epoch=$(date +%s) WHERE path_hex='$h';"
}

rtxn_sync_destination(){
    local dest="$1"
    if sync -f "$dest" 2>/dev/null; then return 0; fi
    rtxn_warn "sync -f is unavailable/failed for $dest; falling back to global sync"
    sync
}

rtxn_finalize(){
    local h state existed mode acl xa fp p now expected rc=0 apply_rc
    [ "${RTXN_ACTIVE:-0}" = 1 ] || return 0
    # Never discard unresolved tar-created directory state.
    if [ "$(rtxn_sql "SELECT COUNT(*) FROM dirs WHERE existed=0;")" -gt 0 ]; then
        rtxn_warn "restore metadata transaction has unresolved tar-created directory state; journal preserved"
        RTXN_PRESERVE=1; export RTXN_PRESERVE; return 3
    fi
    while IFS=$'\x1f' read -r -d $'\x1e' h state existed mode acl xa fp; do
        rtxn_unhex_var p "$h"; [ "$existed" = 1 ] || continue
        if [ "$state" = RELAXED ] && [ -d "$p" ] && [ -n "$fp" ]; then
            now="$(rtxn_fingerprint "$p")"; [ "$now" = "$fp" ] || { rtxn_warn "metadata drift detected; refusing to finalize $p"; RTXN_PRESERVE=1; export RTXN_PRESERVE; return 2; }
        elif [ "$state" = RECORDED ] && [ -d "$p" ]; then
            expected="$(rtxn_fields_fingerprint "$mode" "$acl" "$xa")"; now="$(rtxn_fingerprint "$p")"
            [ "$now" = "$expected" ] || { rtxn_warn "metadata drift detected; refusing to finalize $p"; RTXN_PRESERVE=1; export RTXN_PRESERVE; return 2; }
        fi
    done < <(rtxn_sqla "SELECT path_hex,state,existed,COALESCE(mode,''),COALESCE(acl_b64,''),COALESCE(xattr_b64,''),COALESCE(relaxed_fp,'') FROM dirs ORDER BY depth DESC,length(path_hex) DESC;")
    while IFS=$'\x1f' read -r -d $'\x1e' h state existed mode acl xa; do
        rtxn_unhex_var p "$h"
        if rtxn_apply_snapshot "$p" "$existed" "$mode" "$acl" "$xa"; then apply_rc=0; else apply_rc=$?; fi
        [ "$apply_rc" -eq 0 ] || rc=1
    done < <(rtxn_sqla "SELECT path_hex,state,existed,COALESCE(mode,''),COALESCE(acl_b64,''),COALESCE(xattr_b64,'') FROM dirs ORDER BY depth DESC,length(path_hex) DESC;")
    [ "$rc" -eq 0 ] || { RTXN_PRESERVE=1; export RTXN_PRESERVE; return 1; }
    rm -f "$RTXN_DB" "$RTXN_DB-wal" "$RTXN_DB-shm"; RTXN_ACTIVE=0; export RTXN_ACTIVE
    rtxn_log "restore metadata transaction finalized"
}

rtxn_abort(){
    local rc
    [ "${RTXN_ACTIVE:-0}" = 1 ] || return 0
    [ "${RTXN_PRESERVE:-0}" = 0 ] || return 1
    rtxn_warn "restore interrupted; replaying directory metadata journal"
    if rtxn_recover_db "$RTXN_DB"; then rc=0; else rc=$?; fi
    if [ "$rc" -eq 0 ]; then RTXN_ACTIVE=0; export RTXN_ACTIVE; return 0; fi
    RTXN_PRESERVE=1; export RTXN_PRESERVE; return "$rc"
}
