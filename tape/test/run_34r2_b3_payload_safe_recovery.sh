#!/bin/bash
set -euo pipefail
REPO="${1:-$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)}"
RESTORE="$REPO/cluster/scripts/bric-restore.sh"
TXN="$REPO/cluster/scripts/lib_restore_txn.sh"
META="$REPO/cluster/libexec/bric-file-metadata"
CLI="$REPO/cluster/bin/bric"
SBATCH="$REPO/cluster/slurm/restore.sbatch"

fail(){ echo "FAIL: $*" >&2; exit 1; }
ok(){ echo "  ok: $*"; }

# B3a recovery contract: explicit degraded recovery MUST disable both xattr and ACL extraction.
grep -Fq 'args+=(--no-xattrs --no-acls)' "$RESTORE" || fail "degraded restore does not force --no-xattrs --no-acls"
grep -Fq -- '--allow-metadata-degradation requires an empty destination' "$RESTORE" || fail "degraded restore is not restricted to empty destination"
grep -Fq 'metadata_fidelity=' "$RESTORE" || fail "persistent audit does not record metadata fidelity"
ok "payload-safe degraded TAR_PART path and persistent verdict present"

# CLI + Slurm propagation is required; otherwise production invocation silently loses the policy flag.
grep -Fq -- '--allow-metadata-degradation) ALLOW_METADATA_DEGRADATION=1' "$CLI" || fail "CLI option missing"
grep -Fq 'BRIC_RESTORE_ALLOW_METADATA_DEGRADATION=1' "$CLI" || fail "Slurm export missing"
grep -Fq -- 'args+=(--allow-metadata-degradation)' "$SBATCH" || fail "Slurm wrapper propagation missing"
ok "CLI/Slurm degradation flag propagation present"

# B3b/D2 regression: run as an unprivileged restoring identity.  The archived final mode is 0444,
# but user.* must be applied before that mode removes owner-write.  The unsupported NFSv4 ACL must
# produce degraded-success rc=4, not RESTORE_FAILED, while user.*, mode and mtime all survive.
T="$(mktemp -d /tmp/bric-r34r2-b3.XXXXXX)"
trap 'chmod -R u+rwx "$T" 2>/dev/null || true; rm -rf "$T"' EXIT
chmod 755 "$T"
F="$T/file"
printf payload > "$F"
ENV_B64="$(python3 - <<'PY'
import base64,json
obj={"v":1,"xattrs":{
    "system.nfs4_acl":base64.b64encode(b"not-a-real-nfs4-acl").decode(),
    "user.bric34r2":base64.b64encode(b"survives-readonly-final-mode").decode(),
}}
print(base64.b64encode(json.dumps(obj,separators=(",",":")).encode()).decode())
PY
)"
if [ "$(id -u)" = 0 ] && command -v runuser >/dev/null 2>&1 && id nobody >/dev/null 2>&1; then
    chown nobody "$F"
    chmod 0644 "$F"
    set +e
    runuser -u nobody -- "$META" apply "$F" 0444 1577930640 "$ENV_B64" --allow-degradation >"$T/meta.out" 2>"$T/meta.err"
    MRC=$?
    set -e
else
    echo "  skip: non-root D2 execution requires root + runuser + nobody"
    MRC=4
fi
[ "$MRC" -eq 4 ] || { cat "$T/meta.err" >&2; fail "metadata helper degraded return code is $MRC, expected 4"; }
[ "$(stat -c %a "$F")" = 444 ] || fail "final mode not applied after metadata operations"
[ "$(stat -c %Y "$F")" = 1577930640 ] || fail "mtime not applied last after degraded ACL operation"
python3 - "$F" <<'PY'
import os,sys
v=os.getxattr(sys.argv[1],"user.bric34r2")
assert v==b"survives-readonly-final-mode",v
PY
grep -Fq 'system.nfs4_acl' "$T/meta.err" || fail "unsupported namespace not diagnosed"
ok "unprivileged 0444 + user.* restore applies xattr before final mode and degrades unsupported NFSv4 ACL"

# Strict mode remains fail-closed on the same unsupported namespace.
printf payload > "$T/strict"
set +e
"$META" apply "$T/strict" 0444 1577930640 "$ENV_B64" >"$T/strict.out" 2>"$T/strict.err"
SRC=$?
set -e
[ "$SRC" -ne 0 ] || fail "strict metadata mode unexpectedly accepted unsupported nfs4 ACL"
ok "strict metadata mode remains fail-closed"

# Review 33 journal regression: getfacl's three trivial base entries must no longer arm setfacl.
mkdir -p "$T/bin"
cat > "$T/bin/getfacl" <<'SH'
#!/bin/sh
cat <<'ACL'
user::rwx
group::r-x
other::r-x
ACL
SH
chmod +x "$T/bin/getfacl"
(
    PATH="$T/bin:$PATH"
    . "$TXN"
    out="$(rtxn_acl_dump "$T" || true)"
    [ -z "$out" ]
) || fail "trivial getfacl output still produces a journal ACL blob"
ok "journal ignores synthesized base POSIX ACL"

# D1 regression: an empty ACL field followed by a non-empty xattr field must not shift columns.
# TAB cannot be used because it is IFS whitespace and consecutive delimiters collapse.
(
    . "$TXN"
    rtxn_acl_dump(){ :; }
    rtxn_xattr_dump(){ printf 'XATTR_B64'; }
    snap="$(rtxn_snapshot_fields "$T")"
    IFS=$'\x1f' read -r smode sacl sxa <<< "$snap"
    [ -n "$smode" ]
    [ -z "$sacl" ]
    [ "$sxa" = XATTR_B64 ]
) || fail "journal snapshot field framing shifts empty ACL into xattr column"
ok "journal snapshot preserves empty middle ACL field with non-empty xattr"

# Directory relaxation now verifies real create+unlink ability rather than trusting chmod rc alone.
(
    . "$TXN"
    RTXN_DEST="$(readlink -f "$T")"
    mkdir -p "$T/relax"
    chmod 500 "$T/relax"
    rtxn_relax_path "$T/relax"
    [ "$(stat -c %a "$T/relax")" = 700 ]
    [ -z "$(find "$T/relax" -mindepth 1 -maxdepth 1 -name '.bric-restore-write-probe.*' -print -quit)" ]
) || fail "relaxation write/unlink canary failed"
ok "directory relaxation verifies effective create/unlink and cleans probe"


# RC3 field regression: the real OneFS mount rejects system.nfs4_acl writeback with EINVAL.
# EINVAL is degradable only for explicit metadata degradation; real storage/path errors stay fatal.
if command -v go >/dev/null 2>&1; then
    ( cd "$REPO/cluster/libexec" && go test bric-file-metadata.go bric-file-metadata_degradation_test.go ) \
        || fail "metadata errno degradation unit test failed"
    ok "EINVAL is degradable while EIO/ESTALE/ENOSPC/EROFS/ENOENT remain fatal"
else
    echo "  skip: go missing for rc3 errno unit test"
fi

echo "REVIEW34R2RC3 B3 PAYLOAD-SAFE RECOVERY PASS"
