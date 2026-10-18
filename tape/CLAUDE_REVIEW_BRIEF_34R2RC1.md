# Independent review brief — Review 34R2rc1 B3 payload-safe recovery

Candidate goal: provide a fail-closed, explicitly metadata-degraded payload recovery path for the confirmed Review 34 GNU-tar xattr extraction regression, while preserving `BRIC-FORMAT-V1` and the `files-v34-mode-metadata` database migration.

Baseline Review 34R1 SHA-256: `02e768ba19791ad2959c97793612abd27273b8d292f496513291d15c45bfbb20`.

## Required review/gate

1. Re-derive the exact diff vs Review 34R1 and confirm no tape-side writer/daemon or format changes.
2. Verify manifest, disk file set, bash syntax, static Go helper build and go vet.
3. Confirm normal restore remains strict by default and the new recovery behavior is reachable only through explicit `--allow-metadata-degradation`.
4. Confirm that flag refuses non-empty/symlink destinations before the normal restore submits its tape staging request.
5. Confirm every TAR_PART extraction route under the flag uses `--no-xattrs --no-acls`; tar non-zero status must remain fatal.
6. Reproduce the B3a regression with inherited ACL permissions and confirm the candidate degraded path returns byte-perfect payload instead of zero-byte files.
7. Verify `bric-file-metadata apply ... --allow-degradation` is deterministic, skips only ENOTSUP/EOPNOTSUPP selected xattrs, applies supported user.* entries, and always attempts mtime last. All other errors remain fatal. Strict mode must remain fail-closed.
8. Verify LARGE_FILE_CHUNK degraded metadata status is propagated and persisted, rather than silently reported as exact.
9. Verify restore transaction journal no longer treats base-only getfacl output as a real extended POSIX ACL; strict setfacl/setfattr failures must expose diagnostics.
10. Verify `rtxn_relax_path` checks effective create/write and unlink after chmod.
11. Verify the same payload-safety policy in disaster recovery and ensure the generated standalone restore no longer uses GNU tar xattr/ACL extraction.
12. Verify `RESTORE_DONE` persists `DEGRADED` plus `metadata_fidelity=DEGRADED` when the recovery flag is used.
13. Run the complete native suite serially, including Review 33 transaction/crash/restrictive-directory tests and Review 34 metadata tests.
14. Run the supplied capability probe on the real OneFS destination. Do not infer ACL capability from NFS version alone.
15. Keep `build_state=candidate`. Do not promote this rc as exact metadata fidelity; full Review 34R2 still needs the second TAR_PART metadata pass and a real OneFS gate.
