#!/bin/bash
# SLURM HealthCheckProgram: drain this node if the archive mounts are not live, so chunk jobs are not
# scheduled onto a node that cannot reach Isilon (read) or the QNAP (write). Re-resume with:
#   scontrol update NodeName=<n> State=RESUME
: "${BRIC_HOME:=/projects/bricsoftware/apps/bric2/cluster}"
: "${BRIC_ISILON_MNT:=/mnt/isilon}"; : "${BRIC_QNAP_MNT:=/mnt/data}"; : "${BRIC_REQUIRE_NFS_BUS:=1}"
if [ -r "$BRIC_HOME/scripts/lib_common.sh" ]; then
    export BRIC_LOG_CAPTURE_STDIO=0
    . "$BRIC_HOME/scripts/lib_common.sh"
    bric_log_process_start "slurm-healthcheck-qnap" "$@"
fi
qfs="$(findmnt -n -T "$BRIC_QNAP_MNT" -o FSTYPE 2>/dev/null | head -1 || stat -f -c %T "$BRIC_QNAP_MNT" 2>/dev/null || true)"
bad_mount=0
mountpoint -q "$BRIC_ISILON_MNT" 2>/dev/null || bad_mount=1
mountpoint -q "$BRIC_QNAP_MNT" 2>/dev/null || bad_mount=1
if [ "${BRIC_REQUIRE_NFS_BUS:-1}" = 1 ]; then
    case "$qfs" in nfs|nfs4|nfs*) :;; *) bad_mount=1;; esac
fi
if [ "$bad_mount" -ne 0 ]; then
    declare -F bric_event >/dev/null 2>&1 && BRIC_LOG_RC=1 bric_event ERROR NODE_MOUNT_HEALTH_FAILED         "isilon=$BRIC_ISILON_MNT qnap=$BRIC_QNAP_MNT qnap_fstype=${qfs:-unknown} action=drain"
    if ! err="$(scontrol update NodeName="$(hostname -s)" State=DRAIN Reason="bric: isilon/qnap mount missing or QNAP bus is not NFS" 2>&1)"; then
        declare -F bric_event >/dev/null 2>&1 && BRIC_LOG_RC=1 bric_event ERROR NODE_DRAIN_FAILED "stderr=$err"
        printf '%s
' "$err" >&2
    else
        declare -F bric_event >/dev/null 2>&1 && bric_event WARN NODE_DRAINED             "reason=isilon/qnap mount missing or non-NFS qnap_fstype=${qfs:-unknown}"
    fi
else
    declare -F bric_event >/dev/null 2>&1 && bric_event INFO NODE_MOUNT_HEALTH_OK         "isilon=$BRIC_ISILON_MNT qnap=$BRIC_QNAP_MNT qnap_fstype=$qfs"
fi
