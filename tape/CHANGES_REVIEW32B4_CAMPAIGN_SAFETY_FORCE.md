# BRIC Archive 2.0 — Review 32B4: campaign safety, dedicated local locks, audited `--force`

Date: 2026-09-14
Base: Review 32B3
Scope: production handoff hardening for the phased PPCG_ONT campaign.

## 1. CLOSED terminal barrier regression coverage

32B4 retains the 32B3 catalog-authoritative irreversible CLOSED barrier discovered by the physical
multi-pair smoke. It adds restart/stale-marker and same-project/different-run isolation coverage so a
late ABORT can never de-terminalize a CLOSED run and an abort for one run cannot fence another run of
the same project.

## 2. Dedicated host-local allocator lock deployment

`BRIC_LOCAL_LOCK_DIR` no longer derives from `BRIC_LOG_DIR` or `BRIC_USER_LOG_ROOT`.
`bric-setup-user` provisions a dedicated per-user directory under
`BRIC_LOCAL_LOCK_ROOT` (default `/var/lib/bric/locks/users/<user>`), mode 0700 and owned by the user.
Onboarding verifies that the root is on a host-local filesystem; the allocator independently checks
again at runtime and fails closed on NFS/NFS4/CIFS/SMB/9p/sshfs.

Shared `BRIC_RUNSTATE` remains shared because member lists may need cross-node visibility. Only the
single-host allocator mutex is local.

## 3. Source readability: default fail, explicit force, explicit exclude

The three contracts are intentionally distinct.

### Default

`bric backup PROJECT SOURCE` performs source preflight before tape reservation. Every included path
that is unreadable or an untraversable directory is emitted to stderr/log as `[WARN]`. The list is not
truncated. After reporting all identified problems, preflight exits non-zero and no tape is reserved.

### `--force`

`bric backup PROJECT SOURCE --force` still performs the full preflight. Precisely identified unreadable
paths are omitted from that run, each omission is logged, and each is stored in `run_exclusions` with
reason `force-unreadable`. Source sizing and reservation are recomputed over the remaining readable
scope. The detached job repeats the complete omission list in its durable job log.

`--force` is not equivalent to `--skip-preflight`: unclassified traversal/I/O failures remain fatal.

### `--exclude RELPATH`

`--exclude` is an a-priori operator scope decision, not a permission error. The declared path is pruned
before readability validation/tar, logged informationally, and stored in `run_exclusions` with reason
`user-declared`. It does not require `--force` and is not reported as a forced omission.

## Compatibility

- No on-tape format change (`BRIC-FORMAT-V1`).
- No database schema migration.
- Existing 32B1 128 GB/progressive-restore policy remains unchanged.
