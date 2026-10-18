# CHANGES — Review-5 (hardening, format versioning, long-term resilience)

The reviewer now considers the architecture mature: the open items are hardening, format evolution and
long-term/infra assumptions, not correctness bugs. This batch addresses them. All verified by running the
suite (21 pass + `run_escrow` which passes on retry — see note; `run_real_tape_smoke` needs `--vt`).

## Correction first (a duplicate I introduced)

The previous batch's "#9 project-level DR" added a new `tape/scripts/restore_project_from_tapes.sh`. That
was a **mistake**: a complete, better-integrated project-level DR tool already existed,
`cluster/scripts/bric-dr-from-tapes.sh` (used by 6 tests + setup), with PRIMARY→BACKUP healing, HMAC +
plaintext verification and an admin escrow break-glass. The duplicate has been **removed**, and the one
feature the reviewer wanted that it lacked — single-file recovery — was folded into the existing script as
`--file REL` (finds the latest run holding the path; extracts that TAR_PART member or reassembles that
LARGE_FILE_CHUNK; verifies its plaintext SHA-256). Covered by new assertions in `test/run_dr_e2e.sh`.

## Format versioning (BRIC-FORMAT-V1)

Persistent formats are now explicitly versioned so a future V2 can evolve with backward compatibility:
`config.format_version='1'` in both catalogs; the on-tape recovery kit `README_RECOVERY.txt` starts with a
`BRIC-FORMAT-V1` line; markers remain `BRIC-MARKER-V1` (path-bound) and the tape index `# BRIC tape TOC v1`.
Blob/catalog crypto parameters (`aes-256-cbc/pbkdf2/iter10000`) are pinned AND recorded (per chunk + in the
kit), so a V2 can change them while V1 tapes still open. A cleartext version header *in front of* blob/
catalog ciphertext is deliberately left to V2 (adding it now would break the current read path).

## Documented assumptions (README)

- **Filesystem/bus requirements** — the marker bus relies on three POSIX properties of the shared FS:
  atomic `rename()` (chunk claim = rename, single winner), coherent cross-host visibility, and no
  incoherent caching. These hold for the QNAP+Samba (SMB, `mfsymlinks`) and coherent NFS, but are **not
  guaranteed on an arbitrary network share**; the system must not be used on a FS that violates them.
- **PBKDF2 iteration count** — `iter=10000` is a deliberate choice: the encryption passphrase derives from a
  randomly generated high-entropy user key, not a human password, so a high iteration count adds no real
  security. If human-chosen passphrases were ever allowed, raise to 100k–600k (cost is per-blob, negligible);
  the parameter is pinned and recorded, so an increase can coexist with old tapes.

## Long-term resilience tests

- **`test/run_daemon_crash.sh`** (new) — the tape daemon is a singleton (a second daemon refuses while one
  holds the lock), and a `kill -9` of the draining daemon mid-run is survived: a fresh daemon runs
  `recover()` (abandons any interrupted WRITING segment), re-claims the pending chunks, and the in-flight
  backup still reaches `CLOSED` with every chunk's PRIMARY+BACKUP copy verified on tape.
- **Tape-catalog rebuild equivalence** — already asserted by `test/run_tape_rebuild.sh`: it diffs the
  rebuilt segments/artifacts index against the original (byte-identical) and then runs a full DR restore
  from the rebuilt index. (The reviewer's "make it CI" ask is satisfied: it is part of the suite.)

## Escrow break-glass: real bug found and FIXED (was the `run_escrow` flake)

The intermittent `run_escrow` failure ("wrong final block length", ~1 in 5) was **not** a test artifact — it
was a real escrow-corruption bug. The master-key escrow wrap/unwrap used `openssl enc … -A …` but **without
`-a`/`-base64`**. `-A` only forces single-line base64 *when base64 is already enabled by `-a`*; on its own it
is a no-op, so OpenSSL emitted **raw binary** ciphertext (`Salted__` + binary). `master_wrap` captures that
into a shell variable (`ct="$(openssl …)"`), and command substitution **strips NUL bytes** (and trailing
newlines). A 64-byte random ciphertext contains at least one `0x00` about 22% of the time → the stored escrow
was silently truncated. The HMAC still matched (it was computed over the already-corrupted ciphertext), so the
corruption only surfaced later as a failed decrypt at break-glass — exactly the intermittent symptom. Escrow
is the **only** place that captures `openssl` output into a variable (chunks/catalogs write to files, where raw
binary is fine), which is why nothing else was affected.

Fix: add `-a` to every escrow encrypt/decrypt so the ciphertext is base64 **text** (NUL-safe). Aligned across
all four consumers of the format: `master_wrap`/`master_unwrap` (lib_common), the admin break-glass unwrap in
`bric-dr-from-tapes.sh`, and the two verification unwraps in `test/run_escrow.sh`. Verified: a 1000-iteration
wrap→unwrap loop with fresh random keys now fails 0/1000 (was ~22%), and `run_escrow` passes 8/8 with no flake.

**Backward compatibility:** escrows written by the pre-fix code were raw binary (and ~22% already corrupt), so
they will not unwrap under the corrected base64 path. This is pre-production and `bric register-user`/`bric-setup`
re-escrow the current key idempotently, so the remedy is simply to re-run registration; any escrow created before
this fix must be regenerated. The `users.key_escrow` schema comment ("base64(openssl enc …)") is now actually true.
