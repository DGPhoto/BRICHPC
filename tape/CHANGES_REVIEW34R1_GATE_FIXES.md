# Review 34R1 — native gate fixes

Baseline: Review 34 candidate `f66a295e55145509d696eca1ba2f23018f1ca898d191b0071ac0d1311eeedeb7`.
Database migration remains `files-v34-mode-metadata`; physical tape format remains `BRIC-FORMAT-V1`.

Review 34R1 closes the two blockers from the independent native Review 34 gate and the carried multi-user journal-base residual.

## B1 — serial/Slurm planner parser regression

`cluster/scripts/bric-plan.sh` used an unsafe single-quote substitution while SQL-escaping the metadata envelope. Bash balanced that quote much later in the file, so `bash -n` returned success while the parser swallowed the LARGE_FILE_CHUNK loop and the ordinary TAR_PART branch. The Review 34 gate therefore produced 76/82: all six failures were successful-plan users of the serial planner, including the production Slurm path.

The expression now uses the same explicit escaped-quote idiom already used for relative paths:

```bash
qmeta=${fmeta//\'/\'\'}
```

A focused planner probe with ordinary and oversized files now returns a valid run, catalogs all files/chunks, and records a source `2755` oversized file as ordinary mode `0755` (`493` decimal).

## B2 — regular-file special permission bits

Review 34 intentionally does not restore UID/GID. Restoring setuid/setgid bits without restoring the original ownership can therefore change their security meaning. Review 34R1 defines one explicit policy for regular files on both archive paths:

- preserve ordinary `0777` permission bits;
- do **not** archive/restore setuid, setgid or sticky bits on regular files;
- preserve directory mode semantics, including sticky directories.

Implementation:

- LARGE_FILE_CHUNK tar-header consistency compares only `0777`, matching `bric-file-metadata` capture;
- tar-stream TAR_PART regular-file headers are masked to `0777` before writing;
- sparse regular-file TAR_PART generation uses GNU tar `--mode=u-s,g-s,o-t`;
- the serial/Slurm `bric-chunk.sh` adds that GNU tar mode policy only to file-only TAR_PART chunks, never to directory/link metadata chunks.

This removes the false "mode changed" abort for oversized `4755/2755/1755` files and makes threshold behavior consistent. Review 34 tests now include oversized and small setgid fixtures. `run_tar_stream.sh` independently asserts TAR_PART and LARGE_FILE_CHUNK policy.

## Review 33 × Review 34 interaction regression

`run_34_file_metadata_fidelity.sh` now contains an oversized `0444` file below a source directory whose final mode is `000` (when the gate runs as root). It asserts that the file returns `0444`, its historical mtime is restored, and the ancestor finalizes back to `000` without post-restore chmod contaminating the measurement.

## R1 — configured multi-user journal base

When `BRIC_RESTORE_JOURNAL_ROOT` is explicitly configured, it is a shared **base**, and the actual journal remains `<base>/<uid>/...` with the strict mode-0700/ownership/local-filesystem checks from Review 33.

If the configured base is absent, Review 34R1 creates/normalizes it as a sticky `1777` directory so a second UID can create its own private child. If a pre-existing base is not sticky/world-rwx and is not owned by the caller, BRIC fails closed with an explicit diagnostic rather than silently using an unusable shared path. Network filesystems remain rejected for the journal base/root.

The Review 33 transaction test now proves an absent configured base works sequentially for root and `nobody`, producing separate private per-UID roots.

## Scope unchanged

Review 34R1 does not change chunk framing, tape placement, crypto, HMAC, tape daemon code, UID/GID restore semantics, or `BRIC-FORMAT-V1`. The Review 34 additive catalog columns and migration identifier are unchanged.
