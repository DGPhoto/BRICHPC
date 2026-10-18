#!/bin/bash
# Review 32B5R2 gate follow-up: DR must not conflate a sha256 read failure with unequal bytes.
set -euo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
TMP="$(mktemp -d /tmp/bric-32b5-drverify.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# Load the actual helper definitions from the DR script without executing DR argument parsing.
extract_fn() {
    local name="$1"
    awk -v n="$name" '
      $0 ~ "^" n "\\(\\) \\{" {on=1; depth=0}
      on {print; for(i=1;i<=length($0);i++){c=substr($0,i,1); if(c=="{")depth++; else if(c=="}")depth--} if(depth==0){exit}}
    ' "$ROOT/cluster/scripts/bric-dr-from-tapes.sh"
}
log(){ printf '%s\n' "$*" >> "$TMP/log"; }
eval "$(extract_fn sha256_file)"
eval "$(extract_fn dr_verify_file)"
eval "$(extract_fn dr_log_verify_summary)"

printf 'payload\n' > "$TMP/file"
want="$(sha256sum "$TMP/file" | awk '{print $1}')"
: > "$TMP/log"
dr_verify_file logical/file "$TMP/file" "$want"
grep -q '^VERIFIED-DESTINATION: logical/file$' "$TMP/log"
[ "${DR_VERIFY_DESTINATION:-0}" -eq 1 ]

: > "$TMP/log"
if dr_verify_file logical/file "$TMP/file" "0000000000000000000000000000000000000000000000000000000000000000"; then
    echo 'FAIL: real digest mismatch accepted' >&2; exit 1
fi
grep -q '^CHECKSUM-MISMATCH: logical/file$' "$TMP/log"
[ "${DR_VERIFY_MISMATCH:-0}" -eq 1 ]


: > "$TMP/log"
dr_verify_file logical/file "$TMP/file" ""
grep -q '^NO-DIGEST: logical/file ' "$TMP/log"
[ "${DR_VERIFY_NODIGEST:-0}" -eq 1 ]

mkdir -p "$TMP/fakebin"
cat > "$TMP/fakebin/sha256sum" <<'SH'
#!/bin/sh
exit 13
SH
chmod +x "$TMP/fakebin/sha256sum"
: > "$TMP/log"
PATH="$TMP/fakebin:$PATH" dr_verify_file logical/file "$TMP/file" "$want"
grep -q '^VERIFIED-STREAM: logical/file ' "$TMP/log"
if grep -q 'CHECKSUM-MISMATCH' "$TMP/log"; then echo 'FAIL: unreadable destination misclassified as checksum mismatch' >&2; exit 1; fi
[ "${DR_VERIFY_STREAM:-0}" -eq 1 ]
dr_log_verify_summary
grep -q '^DR verification summary: VERIFIED-DESTINATION=1 VERIFIED-STREAM=1 NO-DIGEST=1 CHECKSUM-MISMATCH=1$' "$TMP/log"
grep -q '^1 object(s) VERIFIED-STREAM only ' "$TMP/log"

# Verify both DR call sites use the tri-state helper rather than discarding sha256_file's return code.
[ "$(grep -c 'dr_verify_file ' "$ROOT/cluster/scripts/bric-dr-from-tapes.sh")" -ge 2 ]

echo 'PASS: DR distinguishes destination mismatch, re-read failure and readable no-digest objects'
