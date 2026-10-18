#!/bin/bash
# Review 32B4 source-integrity gate.
# Default mode is fail-closed: every included path must be readable/traversable before tape
# reservation. --force keeps the preflight but converts precisely identified unreadable paths into
# automatic, auditable exclusions. Unknown traversal/I/O failures remain fatal even in force mode.
set -euo pipefail
IFS=$'\n\t'
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
. "$HERE/lib_common.sh"

SOURCE=""; FORCE=0; FORCE_EXCLUDE_FILE=""
declare -a EXCLUDES=() FORCED_EXCLUDES=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        --source) [ "$#" -ge 2 ] || die "source preflight: --source requires a value"; SOURCE="$2"; shift 2;;
        --exclude)
            [ "$#" -ge 2 ] || die "source preflight: --exclude requires a relative path"
            n="$(bric_normalize_exclude_rel "$2" || true)"
            [ -n "$n" ] || die "invalid exclusion '$2' (use a relative subtree path without . or .. components)"
            EXCLUDES+=("$n"); shift 2;;
        --force) FORCE=1; shift;;
        --force-exclude-file)
            [ "$#" -ge 2 ] || die "source preflight: --force-exclude-file requires a path"
            FORCE_EXCLUDE_FILE="$2"; shift 2;;
        *) die "source preflight: unknown option $1";;
    esac
done
[ -n "$SOURCE" ] || die "usage: bric-source-preflight --source DIR [--exclude RELPATH ...] [--force --force-exclude-file FILE]"
[ -d "$SOURCE" ] || die "source not found or not a directory: $SOURCE"
SOURCE="$(readlink -f "$SOURCE")"
if [ "$FORCE" -eq 1 ]; then
    [ -n "$FORCE_EXCLUDE_FILE" ] || die "source preflight: --force requires --force-exclude-file so omissions remain auditable"
    case "$FORCE_EXCLUDE_FILE" in /*) :;; *) die "source preflight: --force-exclude-file must be absolute";; esac
    umask 077
    mkdir -p "$(dirname "$FORCE_EXCLUDE_FILE")"
    : > "$FORCE_EXCLUDE_FILE"
    chmod 600 "$FORCE_EXCLUDE_FILE"
fi

# Duplicate operator exclusions are almost certainly a command-line mistake; reject instead of
# recording an ambiguous scope twice. Every declared target must exist now so a typo cannot become a
# silent omission.
declare -A SEEN=()
for ex in "${EXCLUDES[@]}"; do
    [ -z "${SEEN[$ex]:-}" ] || die "duplicate exclusion: $ex"
    SEEN[$ex]=1
    [ -e "$SOURCE/$ex" ] || [ -L "$SOURCE/$ex" ] || die "declared exclusion does not exist under source: $ex"
done

T="$(mktemp -d "${BRIC_LOCAL_TMPDIR:-/tmp}/bric-source-preflight.XXXXXX")"
trap 'rm -rf "$T"' EXIT
BAD="$T/bad"; ERR="$T/find.err"; STATS="$T/stats"
: > "$BAD"; : > "$ERR"; : > "$STATS"

build_find_base() {
    local -n _out=$1
    shift
    local -a _ex=("$@")
    _out=(find "$SOURCE")
    if [ "${#_ex[@]}" -gt 0 ]; then
        _out+=( '(' )
        local first=1 ex
        for ex in "${_ex[@]}"; do
            [ "$first" -eq 1 ] || _out+=( -o )
            _out+=( -path "$SOURCE/$ex" )
            first=0
        done
        _out+=( ')' -prune -o )
    fi
}

# Permission scan. A bad directory is pruned after being recorded, so one inaccessible directory is
# represented once rather than as hundreds of derivative child failures. Symlinks are archived as
# links and do not require read permission on their targets.
declare -a find_base=()
build_find_base find_base "${EXCLUDES[@]}"
set +e
"${find_base[@]}" \
  \( -type d \( ! -readable -o ! -executable \) -print0 -prune \) -o \
  \( ! -type d ! -type l ! -readable -print0 \) \
  >"$BAD" 2>"$ERR"
find_rc=$?
set -e

bad_count=0; root_bad=0
while IFS= read -r -d '' p; do
    bad_count=$((bad_count+1))
    rel="${p#"$SOURCE"/}"; [ "$p" != "$SOURCE" ] || rel='.'
    if [ -d "$p" ]; then
        reason="unreadable-or-untraversable-directory"
    else
        reason="unreadable-file"
    fi

    if [ "$FORCE" -eq 1 ] && [ "$rel" != '.' ]; then
        printf '  [WARN] FORCE will skip source path: %q (%s)\n' "$rel" "$reason" >&2
        printf '%s\0%s\0' "$rel" "$reason" >> "$FORCE_EXCLUDE_FILE"
        FORCED_EXCLUDES+=("$rel")
    else
        printf '  [WARN] source path is not readable/traversable: %q (%s)\n' "$rel" "$reason" >&2
        [ "$rel" != '.' ] || root_bad=1
    fi
done < "$BAD"

# Anything emitted by find itself is an unclassified traversal/I/O error. --force deliberately does
# not hide such errors: unlike the permission predicates above, BRIC cannot prove what subtree would
# be omitted, so continuing would make the archive scope unknowable.
if [ -s "$ERR" ]; then
    while IFS= read -r line; do printf '  [FAIL] source traversal: %s\n' "$line" >&2; done < "$ERR"
fi
if [ "$find_rc" -ne 0 ] || [ -s "$ERR" ] || [ "$root_bad" -ne 0 ] || { [ "$FORCE" -ne 1 ] && [ "$bad_count" -ne 0 ]; }; then
    if [ "$FORCE" -eq 1 ]; then
        printf '  [FAIL] force mode only skips precisely identified unreadable paths; unclassified traversal/root failures remain fatal\n' >&2
    else
        printf '  [FAIL] source integrity preflight failed before tape reservation because unreadable/untraversable paths were found; fix permissions or rerun with --force to skip and audit those paths. --exclude remains an explicit operator-selected scope exclusion.\n' >&2
    fi
    exit 1
fi

if [ "$FORCE" -eq 1 ] && [ "$bad_count" -gt 0 ]; then
    printf '  [WARN] FORCE summary: %d unreadable path(s) will be omitted, logged and cataloged\n' "$bad_count" >&2
fi

# Rebuild the exact included scope after automatic force exclusions, then size only what will really be
# archived. This makes reservation/progress denominators agree with the actual tar scope.
declare -a ALL_EXCLUDES=("${EXCLUDES[@]}" "${FORCED_EXCLUDES[@]}") scan_base=()
build_find_base scan_base "${ALL_EXCLUDES[@]}"
: > "$ERR"
set +e
"${scan_base[@]}" -type f -printf '%s %b\n' >"$STATS" 2>"$ERR"
stats_rc=$?
set -e
if [ "$stats_rc" -ne 0 ] || [ -s "$ERR" ]; then
    while IFS= read -r line; do printf '  [FAIL] source sizing traversal: %s\n' "$line" >&2; done < "$ERR"
    printf '  [FAIL] source sizing changed/failed after permission scan; refusing to reserve tape\n' >&2
    exit 1
fi
IFS='|' read -r files logical allocated <<EOF_STATS
$(awk '{n++; logical+=$1; alloc+=($2*512)} END{printf "%d|%.0f|%.0f\n",n,logical,alloc}' "$STATS")
EOF_STATS
files="${files:-0}"; logical="${logical:-0}"; allocated="${allocated:-0}"

printf '  [ok]   source scope traversable/readable after exclusions: %s regular file(s)\n' "$files" >&2
printf '  [info] source scope bytes: logical=%s storage_accounted=%s exclusions=%s forced=%s\n' \
    "$logical" "$allocated" "${#ALL_EXCLUDES[@]}" "${#FORCED_EXCLUDES[@]}" >&2
if [ "${#EXCLUDES[@]}" -gt 0 ]; then
    for ex in "${EXCLUDES[@]}"; do printf '  [info] declared exclusion: %q\n' "$ex" >&2; done
fi
# Machine-readable success record consumed by bric-run/stream-backup; human diagnostics stay stderr.
printf '%s|%s|%s|%s|%s\n' "$files" "$logical" "$allocated" "${#ALL_EXCLUDES[@]}" "$(id -u)"
