#!/bin/bash
# Safe restore-destination capability probe for Review 34R2 B3.
# Creates and removes only a private .bric-capability-probe.* directory inside DEST.
set -u
IFS=$'\n\t'

DEST=""; SOURCE_DIR=""
while [ "$#" -gt 0 ]; do case "$1" in
    --dest) DEST="${2:-}"; shift 2;;
    --source-dir) SOURCE_DIR="${2:-}"; shift 2;;
    -h|--help) echo "usage: bric-restore-capability-probe.sh --dest DIR [--source-dir EXISTING_DIR_WITH_NFS4_ACL]"; exit 0;;
    *) echo "unknown option: $1" >&2; exit 2;;
esac; done
[ -n "$DEST" ] || { echo "--dest is required" >&2; exit 2; }
[ -d "$DEST" ] && [ ! -L "$DEST" ] || { echo "destination must be an existing real directory: $DEST" >&2; exit 2; }

P="$DEST/.bric-capability-probe.$$"
mkdir "$P" || { echo "cannot create probe directory in $DEST" >&2; exit 1; }
cleanup(){ chmod -R u+rwx "$P" 2>/dev/null || true; rm -rf -- "$P"; }
trap cleanup EXIT INT TERM

echo '=== MOUNT ==='
findmnt -T "$P" -o TARGET,SOURCE,FSTYPE,OPTIONS 2>&1 || true
stat -f -c 'statfs=%T' "$P" 2>/dev/null || true

echo; echo '=== TOOLS ==='
for c in getfacl setfacl getfattr setfattr nfs4_getfacl nfs4_setfacl python3 strace; do
    printf '%-18s %s\n' "$c" "$(command -v "$c" 2>/dev/null || echo MISSING)"
done

echo; echo '=== EFFECTIVE DIRECTORY WRITE AFTER chmod u+rwx ==='
mkdir "$P/relax"
chmod 555 "$P/relax" 2>/dev/null || true
chmod u+rwx "$P/relax"; crc=$?
printf 'chmod rc=%s mode=%s\n' "$crc" "$(stat -c %a "$P/relax" 2>/dev/null || echo '?')"
python3 - "$P/relax/probe" <<'PY'
import os,sys
p=sys.argv[1]
try:
    fd=os.open(p,os.O_CREAT|os.O_EXCL|os.O_WRONLY,0o600); os.write(fd,b'x'); os.close(fd)
    print('create+write: OK')
    os.unlink(p); print('unlink: OK')
except OSError as e:
    print(f'create/write/unlink: FAILED errno={e.errno} {e.strerror}')
PY

echo; echo '=== CREATE -> CLOSE -> REOPEN O_WRONLY ==='
python3 - "$P/reopen" <<'PY'
import os,sys,stat
p=sys.argv[1]
try:
    fd=os.open(p,os.O_CREAT|os.O_EXCL|os.O_RDONLY,0o600); os.close(fd)
    st=os.stat(p); print(f'CREATE: OK mode={stat.S_IMODE(st.st_mode):04o}')
except OSError as e:
    print(f'CREATE: FAILED errno={e.errno} {e.strerror}'); raise SystemExit(10)
try:
    fd=os.open(p,os.O_WRONLY); os.write(fd,b'BRIC\n'); os.close(fd)
    print('REOPEN-WRITE: OK')
except OSError as e:
    print(f'REOPEN-WRITE: FAILED errno={e.errno} {e.strerror}'); raise SystemExit(20)
PY
printf 'reopen probe rc=%s\n' "$?"

echo; echo '=== USER XATTR ==='
python3 - "$P/userx" <<'PY'
import os,sys
p=sys.argv[1]; open(p,'wb').close()
try:
    os.setxattr(p,'user.bric_probe',b'ok'); v=os.getxattr(p,'user.bric_probe')
    print(f'user.* set/get: OK value={v!r}')
except OSError as e:
    print(f'user.* set/get: FAILED errno={e.errno} {e.strerror}')
PY

echo; echo '=== POSIX ACL ==='
touch "$P/posix"
if command -v setfacl >/dev/null 2>&1 && command -v getfacl >/dev/null 2>&1; then
    setfacl -m "u:$(id -u):rw-" "$P/posix" 2>"$P/posix.err"; prc=$?
    printf 'setfacl rc=%s' "$prc"; [ ! -s "$P/posix.err" ] || printf ' stderr=%s' "$(tr '\n' ' ' <"$P/posix.err")"; echo
    getfacl -cp "$P/posix" 2>&1 | sed 's/^/  /'
else
    echo 'POSIX ACL tools missing'
fi

echo; echo '=== RAW system.nfs4_acl SAME-OBJECT ROUND TRIP ==='
python3 - "$P/nfs4" <<'PY'
import os,sys
p=sys.argv[1]; open(p,'wb').close(); name='system.nfs4_acl'
try:
    b=os.getxattr(p,name); print(f'GET: OK bytes={len(b)}')
except OSError as e:
    print(f'GET: FAILED errno={e.errno} {e.strerror}'); raise SystemExit(10)
try:
    os.setxattr(p,name,b); print('SET-SAME: OK')
except OSError as e:
    print(f'SET-SAME: FAILED errno={e.errno} {e.strerror}'); raise SystemExit(20)
PY
printf 'raw same-object rc=%s\n' "$?"

if [ -n "$SOURCE_DIR" ]; then
    echo; echo '=== RAW NFSv4 ACL FROM ACTUAL SOURCE DIRECTORY ==='
    [ -d "$SOURCE_DIR" ] || echo "source directory not found: $SOURCE_DIR"
    if [ -d "$SOURCE_DIR" ]; then
        mkdir "$P/nfs4-target"
        python3 - "$SOURCE_DIR" "$P/nfs4-target" <<'PY'
import os,sys
src,dst=sys.argv[1:3]; name='system.nfs4_acl'
try:
    b=os.getxattr(src,name); print(f'GET-SOURCE: OK bytes={len(b)}')
except OSError as e:
    print(f'GET-SOURCE: FAILED errno={e.errno} {e.strerror}'); raise SystemExit(10)
try:
    os.setxattr(dst,name,b); print('SET-TARGET: OK')
except OSError as e:
    print(f'SET-TARGET: FAILED errno={e.errno} {e.strerror}'); raise SystemExit(20)
try:
    c=os.getxattr(dst,name); print(f'VERIFY-GET: OK bytes={len(c)} equal={c==b}')
except OSError as e:
    print(f'VERIFY-GET: FAILED errno={e.errno} {e.strerror}'); raise SystemExit(30)
PY
        printf 'actual-ACL round-trip rc=%s\n' "$?"
    fi
fi

echo; echo '=== OPTIONAL nfs4-acl-tools CROSS-CHECK ==='
if command -v nfs4_getfacl >/dev/null 2>&1 && command -v nfs4_setfacl >/dev/null 2>&1; then
    nfs4_getfacl "$P/nfs4" >"$P/nfs4.txt" 2>"$P/nfs4-get.err"; grc=$?
    echo "nfs4_getfacl rc=$grc"
    if [ "$grc" -eq 0 ]; then
        sed 's/^/  /' "$P/nfs4.txt"
        if command -v strace >/dev/null 2>&1; then
            strace -f -e trace=getxattr,setxattr -o "$P/nfs4.strace" nfs4_setfacl -S "$P/nfs4.txt" "$P/nfs4"; src=$?
            echo "nfs4_setfacl rc=$src"
            sed 's/^/  /' "$P/nfs4.strace"
        else
            nfs4_setfacl -S "$P/nfs4.txt" "$P/nfs4"; echo "nfs4_setfacl rc=$?"
        fi
    else
        sed 's/^/  /' "$P/nfs4-get.err"
    fi
else
    echo 'nfs4-acl-tools missing'
fi

echo; echo '=== END PROBE ==='
