#!/bin/bash
# Review 33R3: restore metadata transaction hardening/regression battery.
set -euo pipefail
IFS=$'\n\t'
REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
LIB="$REPO/cluster/scripts/lib_restore_txn.sh"
command -v sqlite3 >/dev/null 2>&1 || { echo "FAIL: sqlite3 required"; exit 1; }
ROOT="$(mktemp -d)"; uid="$(id -u)"; trap 'chmod -R u+rwx "$ROOT" 2>/dev/null || true; rm -rf "$ROOT"' EXIT
export BRIC_RESTORE_JOURNAL_ROOT="$ROOT/journal"
. "$LIB"
log(){ printf '[test33] %s\n' "$*" >&2; }
warn_log(){ printf '[test33] WARN: %s\n' "$*" >&2; }
ok(){ echo "  ok: $*"; }
bad(){ echo "FAIL: $*" >&2; exit 1; }
mode(){ stat -c '%a' -- "$1"; }
reset_txn(){ RTXN_ACTIVE=0; RTXN_PRESERVE=0; export RTXN_ACTIVE RTXN_PRESERVE; }

DEST="$ROOT/dest"; mkdir -p "$DEST/frozen"; chmod 700 "$DEST/frozen"

# Cross-chunk model.
rtxn_begin "$DEST" test-cross-chunk
rtxn_mark_applying "$DEST/frozen"
chmod 000 "$DEST/frozen"
rtxn_refresh_relax "$DEST/frozen"
[ "$(mode "$DEST/frozen")" = 700 ] || bad "mode-000 directory was not relaxed"
printf later-chunk > "$DEST/frozen/later.dat"
rtxn_sync_destination "$DEST"
rtxn_finalize
{ [ "$(mode "$DEST/frozen")" = 0 ] || [ "$(mode "$DEST/frozen")" = 000 ]; } || bad "final restrictive mode not restored"
ok "mode-000 cross-chunk model finalizes correctly"
chmod 700 "$DEST/frozen"

# Newline path.
NL="$DEST/$(printf 'line\nbreak')"; mkdir -p "$NL"; chmod 500 "$NL"
rtxn_begin "$DEST" test-newline; rtxn_record_existing "$NL"; rtxn_finalize
[ "$(mode "$NL")" = 500 ] || bad "newline directory mode did not round-trip"
ok "newline-containing path round-trips"

# N1: journal setup must not mutate caller umask.
old_umask="$(umask)"; umask 022
UMDEST="$ROOT/umask-dest"; mkdir -p "$UMDEST"
rtxn_begin "$UMDEST" umask-scope
: > "$UMDEST/new-file"
[ "$(stat -c '%a' "$UMDEST/new-file")" = 644 ] || bad "rtxn_begin leaked umask 077 into restore process"
rtxn_finalize; umask "$old_umask"
ok "journal setup leaves caller umask unchanged"

# Journal inside DEST rejected.
mkdir -p "$DEST/inside-journal"
oldroot="$BRIC_RESTORE_JOURNAL_ROOT"; export BRIC_RESTORE_JOURNAL_ROOT="$DEST/inside-journal"
if rtxn_begin "$DEST" illegal-journal 2>/dev/null; then bad "journal inside DEST accepted"; fi
export BRIC_RESTORE_JOURNAL_ROOT="$oldroot"; reset_txn
ok "journal root inside destination rejected"

# Unsafe roots rejected.
mkdir -p "$ROOT/world/$uid"; chmod 0777 "$ROOT/world/$uid"
export BRIC_RESTORE_JOURNAL_ROOT="$ROOT/world"
if rtxn_begin "$DEST" unsafe-root 2>/dev/null; then bad "world-writable per-uid journal root accepted"; fi
rm -rf "$ROOT/world/$uid"; ln -s "$ROOT" "$ROOT/world/$uid"
if rtxn_begin "$DEST" symlink-root 2>/dev/null; then bad "symlink per-uid journal root accepted"; fi
rm -rf "$ROOT/world"; export BRIC_RESTORE_JOURNAL_ROOT="$oldroot"; reset_txn
ok "unsafe journal roots rejected"

# R1: an explicitly configured base may be absent initially and must still support multiple UIDs.
if [ "$(id -u)" = 0 ] && command -v runuser >/dev/null 2>&1 && id nobody >/dev/null 2>&1; then
    MBP="$(mktemp -d /tmp/bric-r33-jbase.XXXXXX)"; chmod 1777 "$MBP"; MBASE="$MBP/journal"
    MROOTDEST="$MBP/root-dest"; MNOBODYDEST="$MBP/nobody-dest"
    export BRIC_RESTORE_JOURNAL_ROOT="$MBASE"; reset_txn
    rtxn_begin "$MROOTDEST" shared-base-root; rtxn_finalize
    [ "$(mode "$MBASE")" = 1777 ] || bad "auto-created configured journal base is not 1777"
    runuser -u nobody -- env BRIC_RESTORE_JOURNAL_ROOT="$MBASE" PATH="$PATH" bash -c '
        set -euo pipefail
        . "'"$LIB"'"
        log(){ :; }; warn_log(){ :; }
        rtxn_begin "'"$MNOBODYDEST"'" shared-base-nobody
        [ "$(stat -c %a -- "$RTXN_DB")" = 600 ]
        rtxn_finalize
    ' || bad "second UID could not use auto-created configured journal base"
    [ -d "$MBASE/0" ] && [ -d "$MBASE/65534" ] || bad "per-UID journal roots missing under shared base"
    chmod -R u+rwx "$MBP" 2>/dev/null || true; rm -rf "$MBP"
    export BRIC_RESTORE_JOURNAL_ROOT="$oldroot"; reset_txn
    ok "configured journal base auto-creates safely for multiple UIDs"
else
    echo "  skip: multi-UID journal-base test requires root + runuser + nobody"
fi

# D1: planted journal cannot target outside DEST.
PDEST="$ROOT/poison-dest"; VICTIM="$ROOT/victim"; mkdir -p "$PDEST" "$VICTIM" "$oldroot"; chmod 700 "$VICTIM" "$oldroot"
canon="$(readlink -f "$PDEST")"; key="$(printf '%s\0%s' "$canon" "$uid" | sha256sum | awk '{print $1}')"; mkdir -p "$oldroot/$uid"; chmod 700 "$oldroot/$uid"; db="$oldroot/$uid/$key.sqlite"
h="$(rtxn_hex "$VICTIM")"
( umask 077; sqlite3 "$db" <<SQL
CREATE TABLE meta(key TEXT PRIMARY KEY,value TEXT NOT NULL);
CREATE TABLE dirs(path_hex TEXT PRIMARY KEY,depth INTEGER NOT NULL,state TEXT NOT NULL,existed INTEGER NOT NULL,mode TEXT,acl_b64 TEXT,xattr_b64 TEXT,relaxed_fp TEXT,updated_epoch INTEGER NOT NULL);
INSERT INTO meta VALUES('format','BRIC-RESTORE-JOURNAL-V1');
INSERT INTO meta VALUES('dest','$(rtxn_sql_quote "$canon")');
INSERT INTO meta VALUES('pid','99999999');
INSERT INTO meta VALUES('proc_start','1');
INSERT INTO dirs VALUES('$h',1,'APPLYING',1,'777','','','',0);
SQL
)
export BRIC_RESTORE_JOURNAL_ROOT="$oldroot"
if rtxn_begin "$PDEST" poison 2>/dev/null; then bad "planted out-of-DEST journal accepted"; fi
[ "$(mode "$VICTIM")" = 700 ] || bad "outside victim was modified"
[ -e "$db" ] || bad "poisoned journal was silently deleted"
rm -f "$db" "$db-wal" "$db-shm"; reset_txn
ok "out-of-DEST planted journal fails closed"

# D3: drift during stale recovery is refused before mutation.
DRIFTDEST="$ROOT/drift-dest"; DRIFT="$DRIFTDEST/drift"; mkdir -p "$DRIFT"; chmod 500 "$DRIFT"
(
  export BRIC_RESTORE_JOURNAL_ROOT="$oldroot"; . "$LIB"; log(){ :; }; warn_log(){ :; }
  rtxn_begin "$DRIFTDEST" crash-drift; rtxn_record_existing "$DRIFT"; exit 0
)
chmod 751 "$DRIFT"
if rtxn_begin "$DRIFTDEST" recover-drift 2>/dev/null; then bad "stale recovery overwrote third-party drift"; fi
[ "$(mode "$DRIFT")" = 751 ] || bad "drift mode changed during recovery"
[ -e "${RTXN_DB:-/nonexistent}" ] || true
# Locate/preserve then clean the journal explicitly.
find "$oldroot" -maxdepth 1 -name '*.sqlite*' -delete 2>/dev/null || true; reset_txn
ok "stale recovery fails closed on metadata drift"

# D5: existed=0 survives recovery and is resumed, not forgotten.
ODEST="$ROOT/orphan-dest"; mkdir -p "$ODEST"
(
  export BRIC_RESTORE_JOURNAL_ROOT="$oldroot"; . "$LIB"; log(){ :; }; warn_log(){ :; }
  rtxn_begin "$ODEST" orphan-crash; rtxn_mark_applying "$ODEST/newdir"; mkdir -p "$ODEST/newdir"; chmod 000 "$ODEST/newdir"; exit 0
)
rtxn_begin "$ODEST" orphan-retry
[ "${RTXN_ACTIVE:-0}" = 1 ] || bad "orphan journal was not resumed"
[ -e "$RTXN_DB" ] || bad "orphan journal was removed"
[ "$(mode "$ODEST/newdir")" = 700 ] || bad "orphan directory was not made traversable"
if rtxn_finalize >/dev/null 2>&1; then bad "unresolved existed=0 row finalized"; fi
chmod 000 "$ODEST/newdir"; rtxn_refresh_relax "$ODEST/newdir"; rtxn_finalize
{ [ "$(mode "$ODEST/newdir")" = 0 ] || [ "$(mode "$ODEST/newdir")" = 000 ]; } || bad "orphan final metadata not captured"
ok "tar-created directory state survives crash until retry resolves it"

# N3: live PID with missing proc_start remains active (conservative fallback).
LDEST="$ROOT/live-dest"; mkdir -p "$LDEST"; rtxn_begin "$LDEST" live-owner
rtxn_sql "DELETE FROM meta WHERE key='proc_start';"
ACTIVE_DB="$RTXN_DB"
if ( export BRIC_RESTORE_JOURNAL_ROOT="$oldroot"; . "$LIB"; rtxn_begin "$LDEST" second 2>/dev/null ); then bad "live journal with unknown proc_start treated as stale"; fi
rm -f "$ACTIVE_DB" "$ACTIVE_DB-wal" "$ACTIVE_DB-shm"; reset_txn
ok "unknown live process identity blocks concurrent restore"

# PID reuse: dead identity token mismatch is stale and recoverable.
RDEST="$ROOT/reuse-dest"; RDIR="$RDEST/d"; mkdir -p "$RDIR"; chmod 750 "$RDIR"
rtxn_begin "$RDEST" pid-reuse; rtxn_record_existing "$RDIR"
rtxn_sql "UPDATE meta SET value='$(rtxn_sql_quote "$$")' WHERE key='pid'; UPDATE meta SET value='definitely-not-current' WHERE key='proc_start';"
reset_txn
rtxn_begin "$RDEST" pid-reuse-recover; rtxn_finalize
[ "$(mode "$RDIR")" = 750 ] || bad "PID-reuse stale journal did not recover"
ok "PID reuse with different start token is stale"

# G3: an existing symlinked ancestor must never be relaxed or journaled through to an outside target.
SDEST="$ROOT/symlink-dest"; OUTSIDE="$ROOT/victim-outside"; mkdir -p "$SDEST" "$OUTSIDE"; chmod 500 "$OUTSIDE"
ln -s "$OUTSIDE" "$SDEST/linkdir"
rtxn_begin "$SDEST" symlink-escape
if rtxn_prepare_ancestors "linkdir/child.dat" >/dev/null 2>&1; then bad "symlinked ancestor was accepted for relaxation"; fi
[ "$(mode "$OUTSIDE")" = 500 ] || bad "symlink escape modified outside target"
rtxn_abort >/dev/null 2>&1 || true
reset_txn
ok "symlinked ancestor cannot escape live relaxation outside DEST"

# G3 stale-journal path: lexical containment is not enough when an ancestor is a symlink.
SJDEST="$ROOT/symlink-journal-dest"; SJOUT="$ROOT/symlink-journal-outside"; mkdir -p "$SJDEST" "$SJOUT"; chmod 500 "$SJOUT"
ln -s "$SJOUT" "$SJDEST/linkdir"
canon="$(readlink -f "$SJDEST")"; key="$(printf '%s\0%s' "$canon" "$uid" | sha256sum | awk '{print $1}')"; mkdir -p "$oldroot/$uid"; chmod 700 "$oldroot/$uid"; sjdb="$oldroot/$uid/$key.sqlite"
h="$(rtxn_hex "$SJDEST/linkdir")"
( umask 077; sqlite3 "$sjdb" <<SQL
CREATE TABLE meta(key TEXT PRIMARY KEY,value TEXT NOT NULL);
CREATE TABLE dirs(path_hex TEXT PRIMARY KEY,depth INTEGER NOT NULL,state TEXT NOT NULL,existed INTEGER NOT NULL,mode TEXT,acl_b64 TEXT,xattr_b64 TEXT,relaxed_fp TEXT,updated_epoch INTEGER NOT NULL);
INSERT INTO meta VALUES('format','BRIC-RESTORE-JOURNAL-V1');
INSERT INTO meta VALUES('dest','$(rtxn_sql_quote "$canon")');
INSERT INTO meta VALUES('pid','99999999');
INSERT INTO meta VALUES('proc_start','1');
INSERT INTO dirs VALUES('$h',1,'APPLYING',1,'500','','','',0);
SQL
)
if rtxn_begin "$SJDEST" symlink-journal 2>/dev/null; then bad "stale journal symlink escape was accepted"; fi
[ "$(mode "$SJOUT")" = 500 ] || bad "stale journal symlink escape modified outside target"
[ -e "$sjdb" ] || bad "unsafe symlink journal was silently removed"
rm -f "$sjdb" "$sjdb-wal" "$sjdb-shm"; reset_txn
ok "stale journal cannot escape DEST through a symlinked ancestor"

# ACL + xattr namespace/roundtrip when available.
ACL="$DEST/acl"; mkdir -p "$ACL"; chmod 750 "$ACL"
if command -v setfacl >/dev/null 2>&1 && command -v getfacl >/dev/null 2>&1 && setfacl -m u:$(id -u):r-x "$ACL" 2>/dev/null; then
    before_acl="$(getfacl -cp -- "$ACL")"; rtxn_begin "$DEST" acl-roundtrip; rtxn_record_existing "$ACL"; rtxn_finalize
    [ "$before_acl" = "$(getfacl -cp -- "$ACL")" ] || bad "ACL changed"
    ok "ACL preserved"
else echo "  skip: ACL tooling/filesystem unavailable"; fi
XA="$DEST/xattr"; mkdir -p "$XA"
if command -v setfattr >/dev/null 2>&1 && command -v getfattr >/dev/null 2>&1 && setfattr -n user.bric_review33 -v sentinel "$XA" 2>/dev/null; then
    dump="$(rtxn_xattr_dump "$XA" | base64 -d 2>/dev/null || true)"
    printf '%s' "$dump" | grep -q 'user.bric_review33' || bad "user xattr absent from snapshot"
    printf '%s' "$dump" | grep -Eq '(^|[[:space:]])(system|security|trusted)\.' && bad "non-user xattr namespace captured"
    rtxn_begin "$DEST" xattr-roundtrip; rtxn_record_existing "$XA"; rtxn_finalize
    [ "$(getfattr -n user.bric_review33 --only-values "$XA" 2>/dev/null || true)" = sentinel ] || bad "user xattr lost"
    ok "only user.* xattrs are transaction-snapshotted and preserved"
else echo "  skip: xattr tooling/filesystem unavailable"; fi

echo "PASS: Review 33R3 restore metadata transaction"
