# Review 31 — source integrity, explicit scope, and LTO throughput

Review 31 consolidates the failures and performance pathologies exposed by the real LTO-9 smoke runs.
It keeps `BRIC-FORMAT-V1` and the existing read-back verification model.

## 1. Source readability is now a pre-reservation invariant

`bric backup` traverses the exact included source scope as the calling UID before any reservation is
requested. Regular files must be readable; directories must be readable and traversable. Traversal
errors are fatal. A backup can therefore no longer spend hours writing append-only media only to fail
at tar EOF because a subtree was inaccessible.

The detached producer inherits the scan result. Direct/internal stream invocation performs the same
scan if no validated result is present. Any permission/read failure that appears after preflight is
still fatal and is reported explicitly as a source-integrity change; BRIC never silently omits data.

The scan also records regular-file count, logical bytes and allocated bytes for the exact included
scope. `bric status` can show scanned progress using logical bytes, avoiding the invalid comparison of
ciphertext size with `du -sb` on sparse trees.

## 2. Explicit exclusions are first-class archive metadata

`--exclude RELPATH` may be repeated. It denotes an exact relative file/directory subtree, not an
arbitrary shell/glob expression. Each target must exist at preflight time; absolute paths, `.`/`..`
components and duplicates are refused.

Declared exclusions are pruned by both the preflight traversal and GNU tar, stored in the new
`run_exclusions` catalog table, copied into `catalog_project.enc`, and viewable with:

    bric exclusions PROJECT [--run RUN_ID]

This distinguishes intentional archive scope from accidental missing data in future DR.

## 3. Sparse batching from 30AH is the production granularity fix

Materially sparse files are batched into multi-member GNU sparse `TAR_PART`s instead of forcing one
physical tape file per sparse member. The default batch target is 64 GiB estimated payload and remains
configurable. Existing restore and DR paths are unchanged because every payload is still an ordinary
independent V1 tar archive.

## 4. Tape daemon immediately rescans after observable progress

The daemon no longer sleeps the full polling interval after it has just completed a reservation,
chunk receipt, stale-claim reclaim, abort, close, or restore-stage transition. It immediately rescans
the bus, allowing READY work published during the preceding tape operation to start without a
manufactured 5–10 second idle gap. When no progress occurs it retains normal polling, avoiding a busy
loop on blocked/incomplete requests.

## 5. Additive catalog schema only

Two additive tables are introduced lazily at the first Review-31 backup:

- `run_exclusions`
- `run_source_scan`

No existing table or row is rewritten. Older runs remain readable. The tables are included in the
user-key-encrypted project catalog on tape.

## Compatibility

- on-tape format: `BRIC-FORMAT-V1` unchanged
- ciphertext format/HMAC: unchanged
- tape daemon read-back verification: unchanged
- bus marker protocol: unchanged
- existing tapes/restores: unchanged
