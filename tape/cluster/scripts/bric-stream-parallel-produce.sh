#!/bin/bash
# Review 32A single-run parallel local producer.
# A NUL-safe metadata walk assigns each regular path to exactly one worker, balancing cumulative
# logical bytes. Each worker emits an independent GNU tar stream into the existing tar-aware helper;
# all helpers share one run_id and obtain globally unique chunk numbers through bric-stream-allocate.
# Directories/symlinks/special metadata are emitted once, after data workers, so restrictive directory
# modes are catalogued/restored after file data just as in the one-pass producer.
set -euo pipefail
IFS=$'\n\t'
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"; . "$HERE/lib_common.sh"
require_cmds find tar awk mktemp

RUN_ID=""; PROJECT=""; OWNER=""; SOURCE=""; TARGET=""; WORKERS=""; RUNSTATE=""; RUN_DIR=""
ENC_PASS_FILE=""; HMAC_KEY_FILE=""; TAR_BLOCKING_FACTOR="8192"; PROGRESS_EVERY="5000"
SPARSE_MIN_HOLE="67108864"; SPARSE_MAX_ALLOC="75"; SPARSE_BATCH_TARGET="4294967296"; SOURCE_CHANGE_POLICY="strict"
declare -a EXCLUDES=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        --run) RUN_ID="${2:-}"; shift 2;;
        --project) PROJECT="${2:-}"; shift 2;;
        --owner) OWNER="${2:-}"; shift 2;;
        --source) SOURCE="${2:-}"; shift 2;;
        --target) TARGET="${2:-}"; shift 2;;
        --workers) WORKERS="${2:-}"; shift 2;;
        --runstate) RUNSTATE="${2:-}"; shift 2;;
        --run-dir) RUN_DIR="${2:-}"; shift 2;;
        --enc-pass-file) ENC_PASS_FILE="${2:-}"; shift 2;;
        --hmac-key-file) HMAC_KEY_FILE="${2:-}"; shift 2;;
        --tar-blocking-factor) TAR_BLOCKING_FACTOR="${2:-}"; shift 2;;
        --progress-every) PROGRESS_EVERY="${2:-}"; shift 2;;
        --sparse-min-hole) SPARSE_MIN_HOLE="${2:-}"; shift 2;;
        --sparse-max-allocated-percent) SPARSE_MAX_ALLOC="${2:-}"; shift 2;;
        --sparse-batch-target) SPARSE_BATCH_TARGET="${2:-}"; shift 2;;
        --source-change-policy) SOURCE_CHANGE_POLICY="${2:-}"; shift 2;;
        --exclude) EXCLUDES+=("${2:-}"); shift 2;;
        *) die "parallel producer: unknown option $1";;
    esac
done
for v in RUN_ID PROJECT OWNER SOURCE TARGET WORKERS RUNSTATE RUN_DIR ENC_PASS_FILE HMAC_KEY_FILE; do
    [ -n "${!v}" ] || die "parallel producer: missing --$(printf '%s' "$v" | tr 'A-Z_' 'a-z-')"
done
case "$WORKERS" in ''|*[!0-9]*) die "invalid parallel worker count '$WORKERS'";; esac
[ "$WORKERS" -ge 2 ] && [ "$WORKERS" -le 16 ] || die "parallel workers must be 2..16"
case "$TARGET" in ''|*[!0-9]*|0) die "invalid worker chunk target '$TARGET'";; esac
case "$SOURCE_CHANGE_POLICY" in strict|record) :;; *) die "invalid source change policy '$SOURCE_CHANGE_POLICY'";; esac
SOURCE="$(readlink -f "$SOURCE")"
STREAM="$HERE/../libexec/bric-tar-stream"
ALLOC="$HERE/bric-stream-allocate.sh"
GATE="$HERE/bric-stream-gate.sh"
PUBLISH="$HERE/bric-stream-publish.sh"
for x in "$STREAM" "$ALLOC" "$GATE" "$PUBLISH"; do [ -x "$x" ] || die "parallel producer helper missing/not executable: $x"; done

TMP="$(mktemp -d "${BRIC_LOCAL_TMPDIR:-/tmp}/bric-parallel.XXXXXX")"
# EXIT traps are inherited by backgrounded shell functions.  Without a coordinator guard, the first
# data worker to exit removes the shared TMP directory while the parent still needs status/metadata
# files.  BASHPID (unlike $$) changes in those subshells, so only the coordinator may clean shared
# state.  On coordinator failure, orphan ALLOCATED placeholders are catalog scratch, not durable work.
COORD_BASHPID="$BASHPID"
cleanup(){
    local rc=$?
    [ "$BASHPID" = "$COORD_BASHPID" ] || return 0
    if [ "$rc" -ne 0 ] && [ -n "${RUN_ID:-}" ]; then
        sql "DELETE FROM chunks WHERE run_id='$(sql_quote "$RUN_ID")' AND state='ALLOCATED';" 2>/dev/null || true
    fi
    rm -rf "$TMP"
}
trap cleanup EXIT
mkdir -p "$RUNSTATE/workers"
chmod 700 "$RUNSTATE/workers"

# Build the exact same lexical exclusion/prune scope as source preflight, but persist only relative
# paths locally. Records are NUL-separated so tabs/newlines/leading '-' in names stay lossless.
find_base=(find "$SOURCE" -mindepth 1)
if [ "${#EXCLUDES[@]}" -gt 0 ]; then
    find_base+=( '(' )
    first=1
    for ex in "${EXCLUDES[@]}"; do
        [ "$first" -eq 1 ] || find_base+=( -o )
        find_base+=( -path "$SOURCE/$ex" )
        first=0
    done
    find_base+=( ')' -prune -o )
fi
RAW="$TMP/regular.raw"
ERR="$TMP/find.err"
: > "$ERR"
set +e
"${find_base[@]}" -type f -printf '%s\0%P\0' > "$RAW" 2>"$ERR"
frc=$?
set -e
if [ "$frc" -ne 0 ] || [ -s "$ERR" ]; then
    cat "$ERR" >&2
    die "parallel producer source manifest traversal failed"
fi
META="$TMP/meta.list"
: > "$ERR"
set +e
"${find_base[@]}" ! -type f -printf './%P\0' > "$META" 2>"$ERR"
mrc=$?
set -e
if [ "$mrc" -ne 0 ] || [ -s "$ERR" ]; then
    cat "$ERR" >&2
    die "parallel producer metadata manifest traversal failed"
fi

# Online greedy balancing by logical size. This avoids sorting millions of path records and keeps the
# planning footprint bounded by the NUL manifest itself. Each regular path appears in one worker only.
declare -a totals counts lists
for ((i=0; i<WORKERS; i++)); do
    totals[$i]=0; counts[$i]=0
    lists[$i]="$TMP/worker.$(printf '%02d' "$i").list"
    : > "${lists[$i]}"
done
while IFS= read -r -d '' sz && IFS= read -r -d '' rel; do
    case "$sz" in ''|*[!0-9]*) die "manifest produced invalid size for '$rel'";; esac
    best=0
    for ((i=1; i<WORKERS; i++)); do
        [ "${totals[$i]}" -lt "${totals[$best]}" ] && best=$i
    done
    printf './%s\0' "$rel" >> "${lists[$best]}"
    totals[$best]=$(( totals[$best] + sz ))
    counts[$best]=$(( counts[$best] + 1 ))
done < "$RAW"
rm -f "$RAW"

for ((i=0; i<WORKERS; i++)); do
    log "parallel producer worker=$((i+1))/$WORKERS assigned_files=${counts[$i]} assigned_logical_bytes=${totals[$i]} target=$TARGET"
done

run_worker(){ # id list label [allocator|sequential] [chunk_start]
    # IMPORTANT: do not derive ws/terr/result/status in the same `local` builtin that assigns id.
    # Bash expands all RHS expressions for that builtin before the new local id is visible. 32A/32A2
    # therefore expanded `$id` from the caller's dynamic scope (normally the last data worker,
    # data-03) when the serialized metadata worker was invoked. The metadata worker then overwrote
    # status.data-03/result.data-03 and never created status.metadata, producing the reproducible
    # native-suite ENOENT after the metadata chunk had already been published.
    local id="$1" list="$2" label="$3" mode="${4:-allocator}" chunk_start="${5:-1}"
    local ws="$RUNSTATE/workers/$id"
    local terr="$TMP/tar.$id.err"
    local result="$TMP/result.$id"
    local status="$TMP/status.$id"
    mkdir -p "$ws"; chmod 700 "$ws"
    : > "$terr"
    local tar_args=(--create --file=- --format=pax --blocking-factor="$TAR_BLOCKING_FACTOR" --hard-dereference --acls --xattrs --xattrs-include=user.* --xattrs-include=system.nfs4_acl --sparse --sparse-version=0.1 --warning=all --quoting-style=escape --no-recursion --null --verbatim-files-from -T "$list")
    local stream_args=(--run "$RUN_ID" --project "$PROJECT" --owner "$OWNER" --source "$SOURCE" --target "$TARGET"
        --runstate "$ws" --run-dir "$RUN_DIR" --enc-pass-file "$ENC_PASS_FILE" --hmac-key-file "$HMAC_KEY_FILE"
        --gate "$GATE" --publish "$PUBLISH" --progress-every "$PROGRESS_EVERY"
        --sparse-min-hole "$SPARSE_MIN_HOLE" --sparse-max-allocated-percent "$SPARSE_MAX_ALLOC"
        --sparse-batch-target "$SPARSE_BATCH_TARGET")
    if [ "$mode" = allocator ]; then stream_args+=(--allocate "$ALLOC"); else stream_args+=(--chunk-start "$chunk_start"); fi
    set +e
    ( cd "$SOURCE" && LC_ALL=C tar "${tar_args[@]}" ) 2>"$terr" |
      "$STREAM" "${stream_args[@]}" >"$result"
    local ps=("${PIPESTATUS[@]}")
    set -e
    printf '%s|%s|%s\n' "${ps[0]}" "${ps[1]}" "$label" > "$status"
    return 0
}

aggregate_progress(){
    local files=0 bytes=0 chunks=0 f b c p tmp="$RUNSTATE/progress.tmp.$$"
    for p in "$RUNSTATE"/workers/*/progress; do
        [ -r "$p" ] || continue
        f="$(awk -F= '$1=="files"{print $2}' "$p" 2>/dev/null || echo 0)"
        b="$(awk -F= '$1=="bytes"{print $2}' "$p" 2>/dev/null || echo 0)"
        c="$(awk -F= '$1=="chunks"{print $2}' "$p" 2>/dev/null || echo 0)"
        case "$f" in ''|*[!0-9]*) f=0;; esac; case "$b" in ''|*[!0-9]*) b=0;; esac; case "$c" in ''|*[!0-9]*) c=0;; esac
        files=$((files+f)); bytes=$((bytes+b)); chunks=$((chunks+c))
    done
    printf 'stage=archiving-parallel\nfiles=%s\nbytes=%s\nchunks=%s\nworkers=%s\nupdated=%s\n' \
        "$files" "$bytes" "$chunks" "$WORKERS" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$tmp"
    mv -f "$tmp" "$RUNSTATE/progress"
}

pids=()
active=0
for ((i=0; i<WORKERS; i++)); do
    [ -s "${lists[$i]}" ] || { printf '0|0|data-%02d-empty\n' "$i" > "$TMP/status.data-$i"; continue; }
    worker_id="data-$(printf '%02d' "$i")"
    run_worker "$worker_id" "${lists[$i]}" "$worker_id" allocator 1 &
    pids+=("$!")
    active=$((active+1))
done
[ "$active" -gt 0 ] || log "parallel producer: no regular files; metadata-only archive"

# Update the user-visible aggregate while workers run. 30 s is intentionally low-frequency so status
# telemetry cannot become a shared-catalog/NFS bottleneck. Do not poll worker PIDs with kill -0: an
# exited but not-yet-waited child can remain visible as a zombie and keep the coordinator alive forever.
STOP_WATCH="$TMP/progress.stop"
progress_watcher(){
    while [ ! -e "$STOP_WATCH" ]; do aggregate_progress; sleep 30; done
}
progress_watcher & watcher_pid=$!
log "parallel producer: waiting for $active data worker(s)"
for pid in "${pids[@]}"; do wait "$pid" || true; done
log "parallel producer: all data worker processes exited"
: > "$STOP_WATCH"
kill "$watcher_pid" 2>/dev/null || true
wait "$watcher_pid" 2>/dev/null || true
aggregate_progress

# Do not emit metadata if any data helper failed. tar rc=1 remains classifiable below; chunker rc !=0
# means an incomplete worker and therefore aborts the whole single run.
chunker_bad=0; tar_rc=0
for st in "$TMP"/status.data-*; do
    [ -r "$st" ] || continue
    IFS='|' read -r tr cr label < "$st"
    [ "$cr" -eq 0 ] || { echo "parallel worker $label chunker rc=$cr" >&2; chunker_bad=1; }
    if [ "$tr" -ge 2 ]; then tar_rc=2; elif [ "$tr" -eq 1 ] && [ "$tar_rc" -eq 0 ]; then tar_rc=1; fi
done
[ "$chunker_bad" -eq 0 ] || { cat "$TMP"/tar.data-*.err 2>/dev/null >&2 || true; exit 20; }

# Metadata is tiny and intentionally serialized after regular data. It still uses the same allocator,
# so its TAR_PART(s) belong to this run and follow the same signing/tape pipeline.
if [ -s "$META" ]; then
    meta_start=$(( $(sql "SELECT COALESCE(MAX(chunk_no),0) FROM chunks WHERE run_id='$(sql_quote "$RUN_ID")';") + 1 ))
    log "parallel producer: starting serialized metadata worker at chunk $meta_start"
    run_worker metadata "$META" metadata sequential "$meta_start"
    IFS='|' read -r tr cr label < "$TMP/status.metadata"
    [ "$cr" -eq 0 ] || { cat "$TMP/tar.metadata.err" >&2 || true; exit 20; }
    if [ "$tr" -ge 2 ]; then tar_rc=2; elif [ "$tr" -eq 1 ] && [ "$tar_rc" -eq 0 ]; then tar_rc=1; fi
    log "parallel producer: metadata worker complete"
fi

COMBINED="$TMP/tar.combined.err"
: > "$COMBINED"
for e in "$TMP"/tar.*.err; do [ "$e" = "$COMBINED" ] || { [ -f "$e" ] && cat "$e" >> "$COMBINED"; }; done
set +e
"$HERE/bric-source-consistency.sh" --run "$RUN_ID" --policy "$SOURCE_CHANGE_POLICY" --tar-rc "$tar_rc" --stderr "$COMBINED"
cons_rc=$?
set -e
[ ! -s "$COMBINED" ] || sed 's/^/tar: /' "$COMBINED" >&2
case "$cons_rc" in
    0) :;;
    10) exit 10;;
    *) exit 11;;
esac

left="$(sql "SELECT COUNT(*) FROM chunks WHERE run_id='$(sql_quote "$RUN_ID")' AND state='ALLOCATED';")"
[ "${left:-0}" -eq 0 ] || die "parallel producer completed with $left un-published ALLOCATED chunk(s)"
# Recompute authoritative final aggregates once all workers are done.
sql "UPDATE runs SET n_chunks=(SELECT COUNT(*) FROM chunks WHERE run_id='$(sql_quote "$RUN_ID")'), total_bytes=COALESCE((SELECT SUM(size_bytes) FROM files WHERE run_id='$(sql_quote "$RUN_ID")' AND entry_type='F'),0) WHERE run_id='$(sql_quote "$RUN_ID")';"
N="$(sql "SELECT COUNT(*) FROM chunks WHERE run_id='$(sql_quote "$RUN_ID")';")"
F="$(sql "SELECT COUNT(*) FROM files WHERE run_id='$(sql_quote "$RUN_ID")';")"
B="$(sql "SELECT COALESCE(SUM(size_bytes),0) FROM files WHERE run_id='$(sql_quote "$RUN_ID")' AND entry_type='F';")"
printf 'stage=produced\nfiles=%s\nbytes=%s\nchunks=%s\nworkers=%s\nupdated=%s\n' "$F" "$B" "$N" "$WORKERS" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$RUNSTATE/progress.tmp.$$"
mv -f "$RUNSTATE/progress.tmp.$$" "$RUNSTATE/progress"
printf 'chunks=%s\nentries=%s\nbytes=%s\nworkers=%s\n' "$N" "$F" "$B" "$WORKERS"
