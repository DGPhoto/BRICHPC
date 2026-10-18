#!/bin/bash
# Review 31B: GNU tar drives one source walk; sparse decisions use the PAX map rather than st_blocks,
# batches verify the exact tar bytes while encrypting, and V1 restore/OpenSSL compatibility is retained.
set -euo pipefail
REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/src/sub" "$T/src/empty" "$T/run" "$T/q"
printf 'hello\n' > "$T/src/a.txt"
head -c 15000 /dev/urandom > "$T/src/large.bin"
ln -s ../a.txt "$T/src/sub/link"
printf secret-pass > "$T/enc"; printf hmac-key > "$T/hmac"
cat > "$T/gate" <<'EOS'
#!/bin/sh
exit 0
EOS
cat > "$T/publish" <<'EOS'
#!/bin/bash
set -e
chunk=""; type=""; ff=""; sha=""; hm=""
while [ "$#" -gt 0 ]; do case "$1" in
  --chunk) chunk="$2"; shift 2;; --type) type="$2"; shift 2;; --sha) sha="$2"; shift 2;; --hmac) hm="$2"; shift 2;; --file-finalize) ff="$2"; shift 2;; *) shift;; esac; done
[ -z "$ff" ] || printf 'file|%s\n' "$ff" >> "$PUBLOG"
[ -z "$chunk" ] || printf 'chunk|%s|%s|%s|%s\n' "$chunk" "$type" "$sha" "$hm" >> "$PUBLOG"
EOS
chmod +x "$T/gate" "$T/publish"; export PUBLOG="$T/publish.log"
# Review 31B: production sparse-batch default remains conservative on mutable HPC trees.
"$REPO/cluster/libexec/bric-tar-stream" --help 2>&1 | grep -A1 'sparse-batch-target' | grep -q 'default 4294967296'
grep -q "('sparse_batch_target_bytes','4294967296')" "$REPO/cluster/sql/cluster_init.sql"
grep -q 'SPARSE_BATCH_TARGET=4294967296' "$REPO/cluster/scripts/bric-stream-backup.sh"
! grep -q 'Stat_t.*Blocks\|\.Blocks' "$REPO/cluster/libexec/bric-tar-stream.go" || { echo "FAIL: sparse classification still depends on st_blocks" >&2; exit 1; }
! grep -q 'func hashSourceFile' "$REPO/cluster/libexec/bric-tar-stream.go" || { echo "FAIL: third sparse source read helper still present" >&2; exit 1; }
grep -q 'GNU.sparse.map' "$REPO/cluster/libexec/bric-tar-stream.go"
echo "✓ Review 31B sparse batching uses GNU PAX maps, not st_blocks, and has no third source read"
(cd "$T/src" && tar -cf - --format=pax --blocking-factor=8192 --hard-dereference -- .) |
  "$REPO/cluster/libexec/bric-tar-stream" --run r --project p --owner u --source "$T/src" \
    --target 6000 --runstate "$T/run" --run-dir "$T/q" --enc-pass-file "$T/enc" \
    --hmac-key-file "$T/hmac" --gate "$T/gate" --publish "$T/publish" --progress-every 100000 > "$T/result"
grep -q '^chunks=' "$T/result"
grep -q '^chunk|.*|TAR_PART|' "$T/publish.log"
grep -q '^chunk|.*|LARGE_FILE_CHUNK|' "$T/publish.log"
grep -q '^file|large.bin$' "$T/publish.log"
# Every normal chunk is a valid independent tar and is OpenSSL enc compatible. Do not assume
# filesystem enumeration order: the oversized file may be emitted before directory/TAR_PART members.
mkdir "$T/out"
while IFS='|' read -r _ chunk kind _ _; do
  [ "$kind" = TAR_PART ] || continue
  enc="$T/q/chunk_$(printf '%04d' "$chunk").enc"
  openssl enc -d -aes-256-cbc -pbkdf2 -iter 10000 -pass file:"$T/enc" -in "$enc" | tar -C "$T/out" -xf -
done < "$T/publish.log"
[ -d "$T/out/sub" ]

# SHA-256 and HMAC are computed over the ciphertext and match the OpenSSL tooling used by restore.
IFS='|' read -r _ hash_chunk _ want_sha want_hm < <(grep '^chunk|' "$T/publish.log" | head -1)
hash_blob="$T/q/chunk_$(printf '%04d' "$hash_chunk").enc"
[ "$(sha256sum "$hash_blob" | awk '{print $1}')" = "$want_sha" ]
[ "$(openssl dgst -sha256 -hmac hmac-key "$hash_blob" | awk '{print $NF}')" = "$want_hm" ]
# Reassemble only the raw large-file pieces and compare.
: > "$T/large.rest"
while read -r c; do openssl enc -d -aes-256-cbc -pbkdf2 -iter 10000 -pass file:"$T/enc" -in "$T/q/$c" >> "$T/large.rest"; done < <(
  awk -F'|' '$1=="chunk" && $3=="LARGE_FILE_CHUNK"{printf "chunk_%04d.enc\n",$2}' "$T/publish.log")
cmp -s "$T/src/large.bin" "$T/large.rest"
echo "✓ tar-driven streaming chunks and OpenSSL compatibility passed"

# Review 34R1 security policy: regular-file setuid/setgid/sticky bits are deliberately not restored.
# This must be identical for TAR_PART and LARGE_FILE_CHUNK; directory sticky bits are a separate concern.
mkdir -p "$T/mode-src" "$T/mode-run" "$T/mode-q" "$T/mode-out"
printf small > "$T/mode-src/small-sgid.bin"; chmod 2755 "$T/mode-src/small-sgid.bin"
head -c 15000 /dev/urandom > "$T/mode-src/large-sgid.bin"; chmod 2755 "$T/mode-src/large-sgid.bin"
cat > "$T/mode-publish" <<'EOS'
#!/bin/bash
set -e
chunk=""; type=""; ff=""; fmode=""
while [ "$#" -gt 0 ]; do case "$1" in
  --chunk) chunk="$2"; shift 2;; --type) type="$2"; shift 2;;
  --file-finalize) ff="$2"; shift 2;; --file-mode) fmode="$2"; shift 2;; *) shift;; esac; done
[ -z "$ff" ] || printf 'file|%s|%s\n' "$ff" "$fmode" >> "$MODEPUB"
[ -z "$chunk" ] || printf 'chunk|%s|%s\n' "$chunk" "$type" >> "$MODEPUB"
EOS
chmod +x "$T/mode-publish"; export MODEPUB="$T/mode-publish.log"
(cd "$T/mode-src" && tar -cf - --format=pax -- .) |
  "$REPO/cluster/libexec/bric-tar-stream" --run mode --project p --owner u --source "$T/mode-src" \
    --target 6000 --runstate "$T/mode-run" --run-dir "$T/mode-q" --enc-pass-file "$T/enc" \
    --hmac-key-file "$T/hmac" --gate "$T/gate" --publish "$T/mode-publish" --progress-every 100000 > "$T/mode.result"
grep -q '^file|large-sgid.bin|0755$' "$MODEPUB"
while IFS='|' read -r _ chunk kind; do
  [ "$kind" = TAR_PART ] || continue
  openssl enc -d -aes-256-cbc -pbkdf2 -iter 10000 -pass file:"$T/enc" -in "$T/mode-q/chunk_$(printf '%04d' "$chunk").enc" | tar -C "$T/mode-out" -xpf -
done < "$MODEPUB"
[ "$(stat -c %a "$T/mode-out/small-sgid.bin")" = 755 ]
echo "✓ Review 34R1 regular-file special bits are cleared consistently on TAR_PART and LARGE_FILE_CHUNK"

# Materially sparse PAX members preserve holes without forcing one tape chunk per file.  Multiple
# sparse files are re-read by one GNU tar process and emitted as one ordinary, independent TAR_PART;
# existing V1 restore semantics therefore remain sufficient.
mkdir -p "$T/sparse-src" "$T/sparse-run" "$T/sparse-q" "$T/sparse-out" "$T/sparse-one"
truncate -s 1073741824 "$T/sparse-src/sparse.bin"
printf x | dd of="$T/sparse-src/sparse.bin" bs=1 seek=1048576 conv=notrunc status=none
truncate -s 536870912 "$T/sparse-src/sparse2.bin"
printf y | dd of="$T/sparse-src/sparse2.bin" bs=1 seek=2097152 conv=notrunc status=none
: > "$T/sparse-publish.log"
export PUBLOG="$T/sparse-publish.log"
(cd "$T/sparse-src" && tar -cf - --format=pax --sparse --sparse-version=0.1 -- .) |
  "$REPO/cluster/libexec/bric-tar-stream" --run sparse --project p --owner u --source "$T/sparse-src" \
    --target 6000000 --runstate "$T/sparse-run" --run-dir "$T/sparse-q" --enc-pass-file "$T/enc" \
    --hmac-key-file "$T/hmac" --gate "$T/gate" --publish "$T/publish" --progress-every 100000 \
    --sparse-batch-target 67108864 >"$T/sparse.out" 2>"$T/sparse.err"
grep -q 'queued sparse file "sparse.bin"' "$T/sparse.err"
grep -q 'queued sparse file "sparse2.bin"' "$T/sparse.err"
grep -q 'sparse_map_data=' "$T/sparse.err"
grep -q 'preserved 2 sparse file(s) in batched TAR_PART chunk' "$T/sparse.err"
grep -q 'sparse_map_payload_estimate=' "$T/sparse.err"
[ "$(grep -c '^chunk|.*|TAR_PART|' "$T/sparse-publish.log")" -eq 1 ] || {
  echo "FAIL: two small materially sparse files did not batch into one TAR_PART" >&2
  cat "$T/sparse-publish.log" >&2
  exit 1
}
IFS='|' read -r _ sparse_chunk sparse_kind _ _ < <(grep '^chunk|' "$T/sparse-publish.log")
[ "$sparse_kind" = TAR_PART ]
sparse_blob="$T/sparse-q/chunk_$(printf '%04d' "$sparse_chunk").enc"
openssl enc -d -aes-256-cbc -pbkdf2 -iter 10000 -pass file:"$T/enc" -in "$sparse_blob" |
  tar -C "$T/sparse-out" -xf -
cmp -s "$T/sparse-src/sparse.bin" "$T/sparse-out/sparse.bin"
cmp -s "$T/sparse-src/sparse2.bin" "$T/sparse-out/sparse2.bin"
[ "$(stat -c %s "$T/sparse-out/sparse.bin")" = 1073741824 ]
[ "$(stat -c %s "$T/sparse-out/sparse2.bin")" = 536870912 ]
for f in sparse.bin sparse2.bin; do
  src_blocks=$(stat -c %b "$T/sparse-src/$f")
  out_blocks=$(stat -c %b "$T/sparse-out/$f")
  [ "$out_blocks" -le $((src_blocks + 32)) ] || {
    echo "FAIL: restored sparse allocation expanded for $f: source=$src_blocks blocks restore=$out_blocks blocks" >&2
    exit 1
  }
done
# Existing single-file restore logic selects one member from the same batched TAR_PART.
openssl enc -d -aes-256-cbc -pbkdf2 -iter 10000 -pass file:"$T/enc" -in "$sparse_blob" |
  tar -C "$T/sparse-one" -xf - -- sparse2.bin
cmp -s "$T/sparse-src/sparse2.bin" "$T/sparse-one/sparse2.bin"
[ ! -e "$T/sparse-one/sparse.bin" ]
echo "✓ multiple sparse files batch into one V1 TAR_PART; full and single-file restore preserve holes"


# Scale regression: a directory with many materially sparse small files must batch by estimated
# payload, not regress to one tape chunk per sparse file.  A 1 MiB test target should reduce 100
# members to a small number of TAR_PARTs while every tar remains independently readable.
mkdir -p "$T/many-src" "$T/many-run" "$T/many-q" "$T/many-out"
for i in $(seq -w 1 100); do
  f="$T/many-src/s_$i.bin"
  truncate -s 8388608 "$f"
  printf z | dd of="$f" bs=1 seek=$((10#$i * 4096)) conv=notrunc status=none
done
: > "$T/many-publish.log"
export PUBLOG="$T/many-publish.log"
(cd "$T/many-src" && tar -cf - --format=pax --sparse --sparse-version=0.1 -- .) |
  "$REPO/cluster/libexec/bric-tar-stream" --run many --project p --owner u --source "$T/many-src" \
    --target 33554432 --runstate "$T/many-run" --run-dir "$T/many-q" --enc-pass-file "$T/enc" \
    --hmac-key-file "$T/hmac" --gate "$T/gate" --publish "$T/publish" --progress-every 100000 \
    --sparse-batch-target 1048576 >"$T/many.out" 2>"$T/many.err"
many_chunks=$(grep -c '^chunk|.*|TAR_PART|' "$T/many-publish.log")
[ "$many_chunks" -lt 20 ] || {
  echo "FAIL: 100 sparse files produced $many_chunks TAR_PARTs; batching ineffective" >&2
  exit 1
}
while IFS='|' read -r _ chunk kind _ _; do
  [ "$kind" = TAR_PART ] || continue
  openssl enc -d -aes-256-cbc -pbkdf2 -iter 10000 -pass file:"$T/enc" \
    -in "$T/many-q/chunk_$(printf '%04d' "$chunk").enc" | tar -C "$T/many-out" -xf -
done < "$T/many-publish.log"
[ "$(find "$T/many-out" -type f -name 's_*.bin' | wc -l)" -eq 100 ]
cmp -s "$T/many-src/s_001.bin" "$T/many-out/s_001.bin"
cmp -s "$T/many-src/s_100.bin" "$T/many-out/s_100.bin"
echo "✓ sparse batching scale: 100 sparse files -> $many_chunks independent V1 TAR_PART chunk(s)"


# Files with only small alignment holes must not each become a separate tape TAR_PART. They are
# normalized into the ordinary tar stream; only materially sparse files retain independent sparse
# TAR_PART treatment.
mkdir -p "$T/light-src" "$T/light-run" "$T/light-q"
dd if=/dev/urandom of="$T/light-src/light.bin" bs=1M count=7 status=none
truncate -s 8388608 "$T/light-src/light.bin"
printf ordinary > "$T/light-src/ordinary.txt"
: > "$T/light-publish.log"
export PUBLOG="$T/light-publish.log"
(cd "$T/light-src" && tar -cf - --format=pax --sparse --sparse-version=0.1 -- .) |
  "$REPO/cluster/libexec/bric-tar-stream" --run light --project p --owner u --source "$T/light-src" \
    --target 33554432 --runstate "$T/light-run" --run-dir "$T/light-q" --enc-pass-file "$T/enc" \
    --hmac-key-file "$T/hmac" --gate "$T/gate" --publish "$T/publish" --progress-every 100000 \
    --sparse-min-hole 67108864 --sparse-max-allocated-percent 75 \
    >"$T/light.out" 2>"$T/light.err"
grep -q 'normalized lightly sparse file "light.bin"' "$T/light.err"
! grep -q 'preserved sparse file "light.bin"' "$T/light.err"
mkdir -p "$T/light-out"
while IFS='|' read -r _ chunk kind _ _; do
  [ "$kind" = TAR_PART ] || continue
  openssl enc -d -aes-256-cbc -pbkdf2 -iter 10000 -pass file:"$T/enc" \
    -in "$T/light-q/chunk_$(printf '%04d' "$chunk").enc" | tar -C "$T/light-out" -xf -
done < "$T/light-publish.log"
cmp -s "$T/light-src/light.bin" "$T/light-out/light.bin"
cmp -s "$T/light-src/ordinary.txt" "$T/light-out/ordinary.txt"
echo "✓ lightly sparse files are aggregated into normal TAR_PART chunks"
