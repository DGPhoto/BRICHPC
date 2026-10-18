#!/bin/bash
# Gate-side operational wrapper and Slurm runtime checks.
set -uo pipefail
export BRIC_CONFIG=none BRIC_ROLE=slurm
REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
fail=0; ok(){ echo "  ok: $*"; }; bad(){ echo "  FAIL: $*"; fail=1; }
WRAP="$REPO/cluster/bin/bric-run"
mkdir -p "$ROOT/bin"
cat > "$ROOT/bin/sbatch" <<'S'
#!/bin/bash
exit 0
S
cat > "$ROOT/bin/openssl" <<'S'
#!/bin/bash
[ "$1" = version ] && { echo 'OpenSSL 1.1.1k FIPS'; exit 0; }
exec /usr/bin/openssl "$@"
S
chmod +x "$ROOT/bin"/*
mkdir -p "$ROOT/bin31"
cat > "$ROOT/bin31/openssl" <<'S'
#!/bin/bash
[ "$1" = version ] && { echo 'OpenSSL 3.1.0 test-module'; exit 0; }
exec /usr/bin/openssl "$@"
S
chmod +x "$ROOT/bin31/openssl"
cat > "$ROOT/module-init.sh" <<S
_BRIC_TEST_BASE_PATH="\$PATH"
module() {
    case "\$1" in
        purge) export PATH="\$_BRIC_TEST_BASE_PATH"; return 0 ;;
        -t)
            [ "\${2:-}" = avail ] || return 1
            printf '%s\n' openssl/1.1.1 openssl/3.1.0 openssl/3.5.7 >&2
            return 0
            ;;
        avail)
            printf '%s\n' openssl/1.1.1 openssl/3.1.0 openssl/3.5.7 >&2
            return 0
            ;;
        load)
            case "\${2:-}" in
                openssl/3.5.7) return 1 ;;  # listed, but denied to this UID
                openssl/3.1.0) export PATH="$ROOT/bin31:\$PATH"; return 0 ;;
                *) return 1 ;;
            esac
            ;;
        *) return 1 ;;
    esac
}
S

echo "=== A) Slurm mode selects the configured module inside jobs ==="
out="$(PATH="$ROOT/bin:$PATH" BRIC_RUN_MODE=slurm BRIC_SLURM_OPENSSL_MODULE=openssl/3.5.7 \
      BRIC_QNAP_MNT="$ROOT/not-mounted" BRIC_QNAP="$ROOT/not-mounted/bric" \
      "$WRAP" backup --project x --source "$ROOT" 2>&1 || true)"
echo "$out" | grep -q "auto-select a loadable module from 'module avail openssl'" \
  && ok "wrapper reports dynamic job-local OpenSSL selection" || bad "dynamic OpenSSL lifecycle not reported"
echo "$out" | grep -q 'module-aware backup sbatch scripts installed' \
  && ok "backup sbatch set found" || bad "backup sbatch set missing"
# Login shell intentionally exposes 1.1.1; Slurm preflight must not reject it.
echo "$out" | grep -q 'below the 3.0 minimum' && bad "Slurm mode still gates on login-shell OpenSSL" || ok "login-shell OpenSSL is irrelevant in Slurm mode"

outr="$(PATH="$ROOT/bin:$PATH" BRIC_RUN_MODE=slurm BRIC_SLURM_OPENSSL_MODULE=openssl/3.5.7 \
      BRIC_QNAP_MNT="$ROOT/not-mounted" BRIC_QNAP="$ROOT/not-mounted/bric" \
      "$WRAP" restore --project x --dest "$ROOT/d" 2>&1 || true)"
echo "$outr" | grep -q 'module-aware restore sbatch script installed' \
  && ok "restore also runs through a module-aware sbatch" || bad "restore sbatch not detected"

echo "=== B) Local mode automatically loads the configured OpenSSL module ==="
outl="$(PATH="$ROOT/bin:$PATH" BRIC_RUN_MODE=local BRIC_MODULE_INIT="$ROOT/module-init.sh" \
       BRIC_SLURM_OPENSSL_MODULE=openssl/3.5.7 BRIC_QNAP_MNT="$ROOT/not-mounted" BRIC_QNAP="$ROOT/not-mounted/bric" \
       "$WRAP" restore --project x --dest "$ROOT/d" 2>&1 || true)"
echo "$outl" | grep -q 'OpenSSL 3.1.0 available for direct restore/local mode (module openssl/3.1.0)' \
  && ok "local mode skipped denied 3.5.7 and loaded available 3.1.0" || { echo "$outl"; bad "dynamic OpenSSL fallback missing"; }

out_current="$(PATH="$ROOT/bin31:$PATH" BRIC_RUN_MODE=local BRIC_MODULE_INIT="$ROOT/does-not-exist" \
       BRIC_QNAP_MNT="$ROOT/not-mounted" BRIC_QNAP="$ROOT/not-mounted/bric" \
       "$WRAP" restore --project x --dest "$ROOT/d" 2>&1 || true)"
echo "$out_current" | grep -q 'OpenSSL 3.1.0 available for direct restore/local mode' \
  && ok "already suitable OpenSSL is kept without initializing modules" \
  || { echo "$out_current"; bad "suitable current OpenSSL was not retained"; }

echo "=== C) hardware preflight is delegated to BRIC_ROLE=tape ==="
echo "$out" | grep -q 'tape hardware preflight must pass on the BRIC_ROLE=tape host' \
  && ok "gate does not inspect remote tape devices" || bad "hardware delegation message missing"

echo "=== D) every sbatch uses the shared dynamic resolver and cleanup trap ==="
for f in orchestrate.sbatch archive_array.sbatch finalize_close.sbatch restore.sbatch; do
  P="$REPO/cluster/slurm/$f"
  [ -x "$P" ] || { bad "$f missing/not executable"; continue; }
  grep -q 'bric_ensure_openssl3 purge' "$P" && grep -q 'trap _cleanup_modules EXIT' "$P" \
    && ok "$f dynamically resolves OpenSSL and cleans up loaded modules" || bad "$f OpenSSL lifecycle incomplete"
done
grep -q 'sbatch --wait' "$REPO/cluster/bin/bric" \
  && ok "restore remains synchronous while running as a Slurm job" || bad "restore is not submitted with sbatch --wait"

echo "=== E) real-user identity and config propagate through Slurm ==="
grep -q 'BRIC_USER BRIC_CONFIG' "$REPO/cluster/bin/bric" \
  && grep -q 'BRIC_USER BRIC_CONFIG' "$REPO/cluster/scripts/bric-orchestrate.sh" \
  && grep -q 'BRIC_QNAP_MNT BRIC_REQUIRE_NFS_BUS' "$REPO/cluster/bin/bric" \
  && grep -q 'BRIC_QNAP_MNT BRIC_REQUIRE_NFS_BUS' "$REPO/cluster/scripts/bric-orchestrate.sh" \
  && ok "identity/config/NFS contract survive both backup submission layers" || bad "backup export propagation incomplete"
grep -q 'BRIC_USER BRIC_CONFIG' "$REPO/cluster/bin/bric" && grep -q 'BRIC_RESTORE_PROJECT' "$REPO/cluster/slurm/restore.sbatch" \
  && ok "restore receives the logical user/config and explicit request" || bad "restore export incomplete"

echo "=== F) recovery recipe remains readable with simulated OpenSSL 1.1.1 ==="
echo genomic-secret > "$ROOT/plain"
PATH="$ROOT/bin:$PATH" openssl enc -aes-256-cbc -pbkdf2 -iter 10000 -salt -pass pass:k -in "$ROOT/plain" -out "$ROOT/blob" 2>/dev/null
got="$(PATH="$ROOT/bin:$PATH" openssl enc -d -aes-256-cbc -pbkdf2 -iter 10000 -pass pass:k -in "$ROOT/blob" 2>/dev/null)"
[ "$got" = genomic-secret ] && ok "recovery format remains version-agnostic" || bad "1.1.1 recovery round-trip failed"

echo "=== G) backup --wait observes terminal failures ==="
grep -q 'FAILED|CANCELLED' "$REPO/cluster/bin/bric" && grep -q 'BRIC_WAIT_TIMEOUT' "$REPO/cluster/bin/bric" \
  && ok "terminal failure stops --wait" || bad "backup --wait terminal handling missing"

echo
[ "$fail" -eq 0 ] && echo "PASS run_wrapper_preflight" || { echo "FAIL run_wrapper_preflight"; exit 1; }
