#!/bin/bash
# Review 32A: serialize parallel-stream capacity accounting and chunk-number allocation.
# Every worker calls this BEFORE opening a new chunk. Under one per-run flock we:
#   1) count published ciphertext bytes + full-target budgets for ALLOCATED chunks,
#   2) run the ordinary QNAP/tape-capacity gate (which may extend reservation),
#   3) atomically reserve MAX(chunk_no)+1 as state=ALLOCATED.
# This preserves the invariant that no parallel worker starts a chunk beyond reserved tape capacity.
set -euo pipefail
IFS=$'\n\t'
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"; . "$HERE/lib_common.sh"
require_cmds sqlite3 flock
RUN_ID=""; TYPE=""; GATE=""; TARGET=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --run) RUN_ID="${2:-}"; shift 2;;
        --type) TYPE="${2:-}"; shift 2;;
        --gate) GATE="${2:-}"; shift 2;;
        --target) TARGET="${2:-}"; shift 2;;
        *) die "stream allocator: unknown option $1";;
    esac
done
[ -n "$RUN_ID" ] && [ -n "$TYPE" ] && [ -n "$GATE" ] && [ -n "$TARGET" ] \
    || die "usage: bric-stream-allocate --run RUN --type TYPE --gate CMD --target BYTES"
case "$TYPE" in TAR_PART|LARGE_FILE_CHUNK) :;; *) die "invalid chunk type '$TYPE'";; esac
case "$TARGET" in ''|*[!0-9]*|0) die "invalid chunk target '$TARGET'";; esac
[ -x "$GATE" ] || die "stream gate is not executable: $GATE"

RUNSTATE="$(run_state_dir "$RUN_ID")"
mkdir -p "$RUNSTATE"

# Member lists live in BRIC_RUNSTATE because they may need to be visible across archive nodes, but
# the allocator mutex is host-local: flock(2) on the users' NFSv3 home can transiently return ENOLCK
# (observed on real hardware in Review 32B2).  Keep correctness locks on a local filesystem.
LOCKROOT="${BRIC_LOCAL_LOCK_DIR:-${BRIC_LOCAL_TMPDIR:-/tmp}/bric-locks-$(id -u)}"
umask 077
mkdir -p "$LOCKROOT"
[ -d "$LOCKROOT" ] && [ ! -L "$LOCKROOT" ] || die "local lock root is not a safe directory: $LOCKROOT"
[ "$(stat -c %u "$LOCKROOT")" = "$(id -u)" ] || die "local lock root is not owned by uid $(id -u): $LOCKROOT"
LOCKFS="$(stat -f -c %T "$LOCKROOT" 2>/dev/null || echo unknown)"
case "$LOCKFS" in nfs|nfs4|cifs|smb2|9p|fuse.sshfs) die "BRIC_LOCAL_LOCK_DIR must be local, not $LOCKFS: $LOCKROOT";; unknown) die "cannot determine filesystem type for BRIC_LOCAL_LOCK_DIR: $LOCKROOT";; esac
LOCK="$LOCKROOT/chunk-allocate.$RUN_ID.lock"
exec 9>"$LOCK"
flock -x 9
log "parallel allocator lock acquired run=$RUN_ID type=$TYPE target=$TARGET lock=$LOCK fs=$LOCKFS"

qrun="$(sql_quote "$RUN_ID")"
IFS='|' read -r committed allocated <<EOF_STATE
$(sqlc "SELECT COALESCE(SUM(CASE WHEN state<>'ALLOCATED' THEN size_bytes ELSE 0 END),0), COALESCE(SUM(CASE WHEN state='ALLOCATED' THEN 1 ELSE 0 END),0) FROM chunks WHERE run_id='$qrun';")
EOF_STATE
case "$committed" in ''|*[!0-9]*) committed=0;; esac
case "$allocated" in ''|*[!0-9]*) allocated=0;; esac
# One target for the chunk about to be allocated, plus one full target for every worker currently
# producing an ALLOCATED chunk.  Add the framing margin ONLY to that outstanding budget: committed
# ciphertext is already exact and must not be inflated again (otherwise a 70 TB run can reserve an
# unnecessary extra tape pair near the end solely because 5% was repeatedly applied to old bytes).
outstanding=$(( (allocated + 1) * TARGET ))
margin=$(( outstanding / 20 ))
required=$(( committed + outstanding + margin ))
log "parallel allocator capacity check run=$RUN_ID committed=$committed allocated=$allocated required=$required"
"$GATE" --run "$RUN_ID" --required-total "$required" >/dev/null
log "parallel allocator capacity gate passed run=$RUN_ID required=$required"

out="$(sqlite3 -batch -cmd '.timeout 60000' "$BRIC_DB" <<SQL
PRAGMA foreign_keys=ON;
BEGIN IMMEDIATE;
INSERT INTO chunks(run_id,chunk_no,type,size_bytes,state)
SELECT '$qrun',COALESCE(MAX(chunk_no),0)+1,'$TYPE',0,'ALLOCATED'
  FROM chunks
 WHERE run_id='$qrun';
SELECT chunk_no FROM chunks WHERE rowid=last_insert_rowid();
COMMIT;
SQL
)"
log "parallel allocator sqlite allocation result run=$RUN_ID value=$out"
case "$out" in ''|*[!0-9]*) die "chunk allocator returned invalid value '$out'";; esac
printf '%s\n' "$out"
