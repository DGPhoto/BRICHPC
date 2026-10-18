# Review 34R2rc1 — B3 payload-safe recovery candidate

Baseline: Review 34R1 candidate `02e768ba19791ad2959c97793612abd27273b8d292f496513291d15c45bfbb20`.

`Review 34R2rc1` is an emergency **recovery candidate**, not the final Review 34R2 metadata-fidelity release. It provides a fail-closed way to recover and verify payload bytes from Review 34/34R1 archives without exercising GNU tar's xattr extraction path that produced zero-byte files on the field Isilon destination.

The database migration remains `files-v34-mode-metadata`; the physical tape format remains `BRIC-FORMAT-V1`; no tape-side code or archive format changes are introduced.

## Field blocker B3

The failed restore `PPCG_ONT__20261014T110758Z__0019` established a restore-side regression introduced by Review 34 metadata capture:

- GNU tar 1.35 extracts a regular file carrying PAX xattrs by creating it first (`mknodat`), applying xattrs, then reopening it `O_WRONLY` for payload.
- On a destination where the newly-created object inherits restrictive ACL permissions, that reopen can return `EACCES`, leaving a zero-byte file. The field log matched this signature and the mechanism was reproduced under an unprivileged account with inherited ACLs.
- `--no-xattrs --no-acls` returns GNU tar to a single create+write open and the same test restores byte-perfect payload.
- `bric-file-metadata apply` in Review 34R1 was all-or-nothing and iterated Go map entries nondeterministically; an unsupported `system.nfs4_acl` could therefore skip later `user.*` xattrs and prevent mtime application.
- The restore transaction journal also hard-failed POSIX ACL / xattr replay while discarding the underlying stderr diagnostic.

The archived ciphertext/HMAC/tape copies are not implicated. This release changes restore semantics only.

## Explicit degraded-recovery path

`bric restore` and `bric-dr-from-tapes.sh` now accept:

```
--allow-metadata-degradation
```

This is deliberately explicit and restricted:

- the destination must be new/empty and must not be a symlink;
- the check runs before a normal restore submits its tape staging request;
- TAR_PART payload extraction uses GNU tar with `--no-xattrs --no-acls`;
- tar non-zero status remains fatal;
- destination verification remains authoritative for payload integrity;
- if any TAR_PART is involved, the run is permanently reported as metadata `DEGRADED` rather than exact;
- normal strict restore behavior remains the default.

The flag is propagated through the `bric` CLI and Slurm restore job.

## Large-file metadata helper

`bric-file-metadata` is now `34R2rc1` and adds an explicit `--allow-degradation` apply mode.

- selected xattr names are processed in deterministic sorted order;
- unsupported operations (`ENOTSUP`/`EOPNOTSUPP`) are reported and skipped only in explicit degradation mode;
- permission, decoding, malformed-envelope and other errors remain fatal;
- ordinary mode is applied before ACL/xattr state, preserving Review 34 semantics;
- mtime is always attempted last and cannot be skipped merely because an unsupported selected xattr was encountered;
- degraded success returns a distinct status (`4`) so the caller persists the degraded verdict.

Strict mode remains fail-closed.

## Restore transaction journal

- synthesized base `getfacl` entries (`user::`, `group::`, `other::`) are no longer stored as if they were an extended POSIX ACL;
- strict ACL/xattr replay now preserves and reports the real `setfacl` / `setfattr` diagnostic instead of redirecting it to `/dev/null`;
- the explicit empty-destination degradation path does not claim ACL/xattr journal fidelity;
- after `chmod u+rwx`, directory relaxation verifies effective create/write **and unlink** capability with a temporary canary entry. A successful chmod syscall alone is no longer accepted as proof of effective ACL-governed access.

## Disaster recovery / standalone recovery

The same payload-safety rule is applied to disaster-recovery restore when the explicit degradation flag is used.

The standalone restore script embedded by `bric-close.sh` now restores payload/mode/mtime with `--no-xattrs --no-acls` and prints an explicit warning that ACL/xattr fidelity requires BRIC restore tooling. It no longer ships the known zero-byte xattr extraction trap.

## Persisted verdict

Normal restore audit records now distinguish `OK`, `DEGRADED`, and `FAIL`, and persist `metadata_fidelity=DEGRADED` when the operator explicitly uses the recovery path. This is not merely a terminal warning.

## New capability probe

`cluster/scripts/bric-restore-capability-probe.sh` safely measures the destination rather than inferring capability from NFS protocol version. It tests:

- mount/filesystem information;
- effective write after chmod;
- create-close-reopen-O_WRONLY semantics;
- `user.*` xattrs;
- POSIX ACL write/read where tools are present;
- raw `system.nfs4_acl` read/same-blob write;
- optional raw NFSv4 ACL copy from a real source directory;
- optional `nfs4_getfacl`/`nfs4_setfacl` cross-check with strace.

Protocol version alone is not treated as an ACL capability verdict.

## What 34R2rc1 deliberately does NOT claim

This candidate does **not** solve exact TAR_PART ACL/xattr restoration. Full-fidelity Review 34R2 still requires the destination capability result and a second, independent metadata pass over the already-staged TAR_PART stream. That pass must not be coupled to payload extraction with process substitution, `tee` fan-out or FIFOs: tests showed those forms can lose consumer exit status, return before a consumer finishes, or let metadata-consumer failure truncate the payload stream.

The intended full-fidelity design is two sequential, independently checked decrypt passes over the staged QNAP blob: payload first with `--no-xattrs --no-acls`, metadata capture second, followed by post-payload metadata application. No tape re-read, schema migration or tape-format change is required.

## Release status

`build_state=candidate`. Do not promote Review 34R2rc1 as a full metadata-fidelity release. Its purpose is safe, explicitly degraded recovery and field diagnosis while B3c is measured on the real destination.
