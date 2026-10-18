#!/bin/bash
# Apply Review 32B1 chunk/performance policy to an EXISTING cluster catalog.
# Static code update deliberately never mutates catalogs; run this explicitly after all active work is CLOSED.
set -euo pipefail
IFS=$'\n\t'
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
. "$HERE/lib_common.sh"
require_role slurm
require_cmds sqlite3 find

MAXP=1
WORKERS=4
SEGMENT_TARGET=128000000000
WORKER_CHUNK=128000000000
TARBF=8192
SHOW=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --max-producers) MAXP="${2:-}"; shift 2;;
        --stream-workers) WORKERS="${2:-}"; shift 2;;
        --segment-target-bytes) SEGMENT_TARGET="${2:-}"; shift 2;;
        --worker-chunk-bytes) WORKER_CHUNK="${2:-}"; shift 2;;
        --tar-blocking-factor) TARBF="${2:-}"; shift 2;;
        --show) SHOW=1; shift;;
        -h|--help)
            cat <<'USAGE'
Usage: bric-performance-apply.sh [--max-producers N] [--stream-workers N]
                                  [--segment-target-bytes BYTES]
                                  [--worker-chunk-bytes BYTES]
                                  [--tar-blocking-factor N] [--show]

Applies Review 32B1 chunk/performance policy rows in the existing cluster catalog.
Refuses to modify configuration while archive/restore work is active.
Defaults:
  max_concurrent_producers=1       (run-level slots)
  stream_parallel_workers=4        (inside one project/run)
  segment_target_bytes=128000000000 (128 GB decimal restore-latency bound)
  stream_worker_chunk_bytes=128000000000
  tar_blocking_factor=8192          (4 MiB outer GNU tar record)
USAGE
            exit 0;;
        *) die "unknown option: $1";;
    esac
done

case "$MAXP" in ''|*[!0-9]*|0) die "--max-producers must be a positive integer";; esac
case "$WORKERS" in ''|*[!0-9]*|0) die "--stream-workers must be a positive integer";; esac
case "$SEGMENT_TARGET" in ''|*[!0-9]*|0) die "--segment-target-bytes must be a positive integer";; esac
case "$WORKER_CHUNK" in ''|*[!0-9]*|0) die "--worker-chunk-bytes must be a positive integer";; esac
case "$TARBF" in ''|*[!0-9]*|0) die "--tar-blocking-factor must be a positive integer";; esac
[ "$MAXP" -le 32 ] || die "--max-producers >32 refused"
[ "$WORKERS" -le 16 ] || die "--stream-workers >16 refused"
[ "$TARBF" -le 131072 ] || die "--tar-blocking-factor is implausibly large"

show_values() {
    sqlite3 -header -column "$BRIC_DB" "SELECT key,value FROM config WHERE key IN ('segment_target_bytes','max_concurrent_producers','stream_parallel_workers','stream_worker_chunk_bytes','tar_blocking_factor') ORDER BY key;"
}
if [ "$SHOW" -eq 1 ]; then show_values; exit 0; fi

[ "${EUID:-$(id -u)}" -eq 0 ] || die "performance policy changes must be applied as root"
active="$(sqlite3 -batch -cmd '.timeout 60000' "$BRIC_DB" "SELECT COUNT(*) FROM runs WHERE status IN ('PLANNING','RESERVED','PRODUCING','DRAINING','CLOSING','RESTORING');")"
[ "$active" = 0 ] || die "$active active run(s) found; wait until all work is terminal before changing performance policy"
if [ -d "$BRIC_QNAP/restore" ]; then
    pending=0
    while IFS= read -r req; do
        d="$(dirname "$req")"; [ -e "$d/request.STAGED" ] || pending=$((pending+1))
    done < <(find "$BRIC_QNAP/restore" -mindepth 3 -maxdepth 3 -type f -name request 2>/dev/null)
    [ "$pending" -eq 0 ] || die "$pending active restore request(s) found; wait/cancel before changing performance policy"
fi

printf 'Before:\n'; show_values
sqlite3 -batch -cmd '.timeout 60000' "$BRIC_DB" <<SQL
BEGIN IMMEDIATE;
INSERT INTO config(key,value) VALUES('segment_target_bytes','$SEGMENT_TARGET')
  ON CONFLICT(key) DO UPDATE SET value=excluded.value;
INSERT INTO config(key,value) VALUES('max_concurrent_producers','$MAXP')
  ON CONFLICT(key) DO UPDATE SET value=excluded.value;
INSERT INTO config(key,value) VALUES('stream_parallel_workers','$WORKERS')
  ON CONFLICT(key) DO UPDATE SET value=excluded.value;
INSERT INTO config(key,value) VALUES('stream_worker_chunk_bytes','$WORKER_CHUNK')
  ON CONFLICT(key) DO UPDATE SET value=excluded.value;
INSERT INTO config(key,value) VALUES('tar_blocking_factor','$TARBF')
  ON CONFLICT(key) DO UPDATE SET value=excluded.value;
COMMIT;
SQL
printf '\nAfter:\n'; show_values
printf '\nReview 32B1 chunk/producer policy applied. segment_target_bytes=%s bytes.\n' "$SEGMENT_TARGET"
