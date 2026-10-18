# BRIC Archive 2.0 — Review 32B4A: deterministic escrow wrong-key test

Date: 2026-09-14
Base: Review 32B4
Scope: TEST-ONLY correction. No production/runtime code change.

`test/run_escrow.sh` previously tested a wrong master key by feeding the v2 escrow ciphertext directly
into unauthenticated AES-CBC decryption and requiring `openssl enc -d` to return non-zero. That is a
probabilistic assertion: a wrong key can rarely yield syntactically valid PKCS#7 padding, causing
OpenSSL to exit 0 while returning meaningless plaintext.

32B4A exercises the real BRIC v2 contract instead: it feeds the complete `v2:<hmac>:<ciphertext>` blob
to `master_unwrap`, which verifies the master-derived HMAC before attempting decryption. A wrong
master key is therefore rejected deterministically.

No runtime code, database schema, configuration, on-tape format, or 32B4 campaign behavior changed.
