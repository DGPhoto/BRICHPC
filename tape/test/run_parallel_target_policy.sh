#!/bin/bash
# Review 32A4: segment_target_bytes remains a hard cap on the parallel-specific worker target.
set -euo pipefail
REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
. "$REPO/cluster/scripts/lib_common.sh"
fail(){ echo "FAIL: $*" >&2; exit 1; }
[ "$(stream_worker_chunk_target 128000000000 4 128000000000)" = 128000000000 ] || fail "production 128GB target"
[ "$(stream_worker_chunk_target 128000000000 2 128000000000)" = 128000000000 ] || fail "2-worker explicit target"
[ "$(stream_worker_chunk_target 5242880 4 128000000000)" = 5242880 ] || fail "segment target did not clamp worker target"
[ "$(stream_worker_chunk_target 128000000000 4 0)" = 32000000000 ] || fail "auto 128GB/4"
[ "$(stream_worker_chunk_target 5242880 4 0)" = 1310720 ] || fail "auto reduced target"
[ "$(stream_worker_chunk_target 128000000000 4 123456789)" = 123456789 ] || fail "explicit smaller override"
if stream_worker_chunk_target 128000000000 4 nonsense >/dev/null 2>&1; then fail "invalid override accepted"; fi
echo "PASS parallel worker target policy: segment target is a hard upper bound"
