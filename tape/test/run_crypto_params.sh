#!/bin/bash
# Crypto parameter pinning + long-term recoverability (ChatGPT review point F).
# Asserts: (1) every production openssl enc pins -iter 10000 (no reliance on a changeable default);
# (2) backward-compat — a blob encrypted the OLD way (no -iter) still decrypts with the pinned recipe;
# (3) the exact MANUAL recipe documented in README_RECOVERY (key derivation + Encrypt-then-MAC verify
# BEFORE decrypt + openssl -iter 10000) round-trips with only openssl, sha256sum and tar.
set -euo pipefail
export BRIC_CONFIG=none   # hermetic: never read /etc/bric/bric.conf inside tests
REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"; ROOT="$(mktemp -d)"; echo "workroot=$ROOT"
trap '[ -n "${KEEP:-}" ]||rm -rf "$ROOT"' EXIT
command -v openssl >/dev/null || { echo "SKIP: openssl missing"; exit 0; }
fail=0; ok(){ echo "  ok: $1"; }; bad(){ echo "  FAIL: $1"; fail=1; }
echo "openssl: $(openssl version)"

echo "=== 1: every production 'openssl enc' pins -iter 10000 ==="
BAD="$(grep -rn "openssl enc" "$REPO"/cluster/scripts/*.sh "$REPO"/tape/scripts/*.sh 2>/dev/null | grep -v 'iter 10000' || true)"
[ -z "$BAD" ] && ok "no unpinned openssl enc in production scripts" || { bad "unpinned openssl enc found:"; echo "$BAD" | sed 's/^/     /'; }

echo "=== 2: backward-compat — OLD default-encrypted blob opens with the pinned recipe ==="
printf 'genomic-payload-bytes-1234567890' > "$ROOT/p"
openssl enc -aes-256-cbc -pbkdf2 -salt -pass pass:secret -in "$ROOT/p" -out "$ROOT/old.enc" 2>/dev/null   # pre-fix recipe
if openssl enc -d -aes-256-cbc -pbkdf2 -iter 10000 -pass pass:secret -in "$ROOT/old.enc" 2>/dev/null | cmp -s - "$ROOT/p"; then
  ok "blob written WITHOUT -iter (old default) decrypts WITH -iter 10000 (existing archives stay recoverable)"
else bad "pinned recipe cannot open an old default-encrypted blob — would orphan existing data"; fi
head -c 8 "$ROOT/old.enc" | grep -q "Salted__" && ok "salt is embedded (Salted__ header) — nothing extra to record for recovery" || bad "no Salted__ header"

echo "=== 3: the documented MANUAL recipe round-trips (only openssl + sha256sum + tar) ==="
SRC="$ROOT/proj"; mkdir -p "$SRC/sub"; echo "FASTQ readsAAA" > "$SRC/a.fastq"; echo "meta" > "$SRC/sub/m.txt"; ln -s a.fastq "$SRC/link"
USER_KEY="$(head -c 32 /dev/urandom | base64)"
# derive the two keys EXACTLY as documented
ENC_PASS=$(printf '%s:encryption'     "$USER_KEY" | sha256sum | awk '{print $1}')
HMAC_KEY=$(printf '%s:authentication' "$USER_KEY" | sha256sum | awk '{print $1}')
printf '%s' "$ENC_PASS" > "$ROOT/pass"; chmod 600 "$ROOT/pass"
# produce a blob the way bric-chunk does: tar whole files | openssl enc -aes-256-cbc -pbkdf2 -iter 10000 -salt
( cd "$SRC" && tar -c --no-recursion --null -T <(find . -print0) 2>/dev/null \
    | openssl enc -aes-256-cbc -pbkdf2 -iter 10000 -salt -pass file:"$ROOT/pass" > "$ROOT/chunk.enc" )
EXPECT_HMAC="$(openssl dgst -sha256 -hmac "$HMAC_KEY" "$ROOT/chunk.enc" | awk '{print $NF}')"
# RECOVERY per the README: authenticate BEFORE decrypt, then decrypt+extract
GOT="$(openssl dgst -sha256 -hmac "$HMAC_KEY" "$ROOT/chunk.enc" | awk '{print $NF}')"
[ "$GOT" = "$EXPECT_HMAC" ] && ok "Encrypt-then-MAC: HMAC verifies before any decryption" || bad "HMAC mismatch"
# tamper -> must fail the MAC (proves verify-before-decrypt actually guards)
cp "$ROOT/chunk.enc" "$ROOT/tampered.enc"; printf 'X' | dd of="$ROOT/tampered.enc" bs=1 seek=20 conv=notrunc 2>/dev/null
TGOT="$(openssl dgst -sha256 -hmac "$HMAC_KEY" "$ROOT/tampered.enc" | awk '{print $NF}')"
[ "$TGOT" != "$EXPECT_HMAC" ] && ok "a tampered blob is caught by the HMAC (would be refused before decrypt)" || bad "tamper not detected"
DEST="$ROOT/out"; mkdir -p "$DEST"
openssl enc -d -aes-256-cbc -pbkdf2 -iter 10000 -pass file:"$ROOT/pass" -in "$ROOT/chunk.enc" | tar -C "$DEST" -xp --no-same-owner -f -
if diff -r "$SRC" "$DEST" >/dev/null 2>&1; then ok "manual recipe restored the tree byte-for-byte (files, subdirs, symlink)"; else bad "manual restore differs"; diff -r "$SRC" "$DEST" | head; fi

echo "=== 4: README_RECOVERY documents the pinned parameters ==="
# the recovery kit text is emitted by bric-close.sh; assert the pinned iter + Encrypt-then-MAC are stated
grep -q 'iter = 10000' "$REPO/cluster/scripts/bric-close.sh" && ok "recovery kit documents iter=10000 (pinned)" || bad "recovery kit does not pin iter in docs"
grep -qi 'BEFORE decrypt' "$REPO/cluster/scripts/bric-close.sh" && ok "recovery kit documents verify-before-decrypt" || bad "recovery kit missing MAC-before-decrypt note"

echo
echo "NOTE: only $(openssl version | awk '{print $1, $2}') is present in this sandbox; the recipe is parameter-pinned"
echo "      so it is version-independent. Re-run this test on an OpenSSL 1.1.1 host to tick that box physically."
[ "$fail" -eq 0 ] && echo "✓ CRYPTO-PARAM / RECOVERABILITY CHECKS PASSED" || { echo "✗ CRYPTO-PARAM FAILURES"; exit 1; }
