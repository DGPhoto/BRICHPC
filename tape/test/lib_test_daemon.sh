#!/bin/bash
# Review 33R3 test-only process-group helpers. Background tape-daemon loops must be started with
# setsid so descendants remain in a private process group and teardown cannot race rm -rf.
bric_test_stop_group(){
    local pid="${1:-0}" sig="${2:-TERM}"
    case "$pid" in ''|*[!0-9]*) return 0;; esac
    [ "$pid" -gt 1 ] || return 0
    # Test group leaders are created with setsid. Probe the process group, not only the leader: the
    # leader may have exited while a child is still writing the simulated tape DB.
    if kill -0 -- "-$pid" 2>/dev/null; then
        kill -s "$sig" -- "-$pid" 2>/dev/null || true
    elif kill -0 "$pid" 2>/dev/null; then
        kill -s "$sig" "$pid" 2>/dev/null || true
    else
        return 0
    fi
    wait "$pid" 2>/dev/null || true
}
bric_test_rmrf_retry(){
    local p="$1"
    rm -rf -- "$p" 2>/dev/null || { sleep 1; rm -rf -- "$p"; }
}
