#!/bin/bash
#SBATCH --job-name=bric-chunk
#SBATCH --partition=archive
#SBATCH --time=1-00:00:00
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=2
#SBATCH --mem=2G
#SBATCH --requeue
#SBATCH --constraint=qnap
#SBATCH --output=%x_%A_%a.out
# One array task = one chunk. The node needs BOTH Isilon (NFS, read) and the QNAP (NFS, write) mounted;
# the 'qnap' feature/constraint pins the task to nodes that have them. The work is I/O-bound (read +
# tar|openssl stream to NFS), not CPU-bound (AES-NI), so 2 CPUs / 2 GB are plenty for a streaming chunk.
# --time is per chunk: size it for the measured time a 128 GB chunk takes to read+encrypt+write over NFS, with margin for a slow source.
# --requeue is SAFE because bric-chunk is idempotent: a requeued task whose chunk already completed
# exits 0 without re-staging, and the tape server refuses to write a duplicate segment for a VERIFIED
# chunk. BRIC_RUN_ID and the BRIC_* environment are passed by the orchestrator's --export whitelist.
set -euo pipefail
IFS=$'\n\t'
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
. "$HERE/../scripts/lib_common.sh"
bric_log_process_start "slurm-archive-array" "$@"
require_role slurm
bric_require_nfs_bus
# Establish the crypto runtime inside the actual Slurm job, never from the login shell. Keep an
# already compatible OpenSSL; otherwise inspect Environment Modules and try compatible versions
# from newest to oldest. The configured module is preferred but may be unavailable to this UID.
_cleanup_modules(){
    local rc=$? mrc=0
    trap - EXIT
    if [ "${BRIC_OPENSSL_MODULE_LOADED:-0}" = 1 ]; then
        bric_event INFO MODULE_PURGE_BEGIN "module=${BRIC_OPENSSL_MODULE_SELECTED:-unknown}"
        module purge >/dev/null 2>&1 || mrc=$?
        BRIC_LOG_RC="$mrc" bric_event "$([ "$mrc" -eq 0 ] && echo INFO || echo WARN)" MODULE_PURGE_END "module purge rc=$mrc"
    fi
    bric_log_process_end "$rc"
    exit "$rc"
}
trap _cleanup_modules EXIT
trap 'exit 130' INT TERM
bric_event INFO OPENSSL_RESOLVE_BEGIN "minimum_major=${BRIC_OPENSSL_MIN_MAJOR:-3} preferred=${BRIC_SLURM_OPENSSL_MODULE:-none}"
bric_ensure_openssl3 purge || die "${BRIC_OPENSSL_ERROR:-unable to resolve OpenSSL >=${BRIC_OPENSSL_MIN_MAJOR:-3}}"
bric_event INFO OPENSSL_RESOLVE_END "module=${BRIC_OPENSSL_MODULE_SELECTED:-current} version=${BRIC_OPENSSL_VERSION:-$(bric_openssl_version)}"
"$HERE/../scripts/bric-chunk.sh" --run "$BRIC_RUN_ID" --chunk "$SLURM_ARRAY_TASK_ID"
