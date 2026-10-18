# Review 31B1 — explicit restore allocation effect

Review 31B1 is a narrow follow-up to the ungated 31B candidate. It does not change BRIC-FORMAT-V1, PAX sparse batching, source-consistency classification, tape protocol, restore byte semantics, or daemon behavior.

## Why

On OneFS over NFSv3 the client cannot recover authoritative source extent topology. GNU tar may therefore represent long zero byte ranges sparsely even when those ranges were physically allocated in the source. Byte content remains identical, but the possible allocation-semantic error has a direction: a dense/preallocated zero range may restore as a hole.

## Change

`run_source_semantics` now includes the machine-readable field:

    restore_allocation_effect = zero-ranges-may-restore-as-holes

Together with `allocation_topology = not-guaranteed`, this makes the limitation explicit in the encrypted project catalog and visible through the CLI semantics view. The lazy schema helper adds the column to a database created by the short-lived 31B candidate if necessary.

## Sparse verifier gate

`test/run_tar_stream.sh` creates genuinely sparse files using `truncate` plus positioned writes, feeds them through GNU PAX sparse 0.1 and the production helper/TeeReader verifier, decrypts and restores the batch, compares full logical content, and verifies sparse allocation on restore. This exercises Go `archive/tar` against the exact GNU sparse representation used by production; a parser/reconstruction mismatch makes the helper/test fail.
