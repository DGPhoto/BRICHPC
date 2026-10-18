# Review 34R2rc2 — recovery gate fixes

Baseline: Review 34R2rc1 emergency recovery candidate.

Review 34R2rc2 keeps the rc1 payload-safe recovery design and closes the two defects found by the independent native/non-root gate. It remains a **candidate**, not the final full-fidelity Review 34R2. Database migration remains `files-v34-mode-metadata`; tape format remains `BRIC-FORMAT-V1`; `tape/**` is unchanged.

## D1 — restore-journal empty-field corruption

rc1 filtered trivial synthesized POSIX ACLs out of the journal. That made `acl_b64` legitimately empty while `xattr_b64` could remain non-empty. `rtxn_snapshot_fields()` encoded fields with TAB and callers decoded them with `IFS=$'\t' read`; TAB is IFS whitespace, so consecutive TABs collapse and xattr data shifted into the ACL column. Finalize then handed an xattr dump to `setfacl`.

rc2 uses ASCII Unit Separator (`0x1f`) for the internal snapshot tuple and all three call sites decode with the same non-whitespace separator. Empty middle fields are preserved.

## D2 — read-only LARGE_FILE_CHUNK metadata under an unprivileged restore

rc1 applied the archived ordinary mode before selected xattrs. For a restored file whose final mode is `0444`, an unprivileged owner could then receive `EACCES` while setting `user.*`; rc1 treated that as fatal even under explicit metadata degradation, so payload verification could be green while the overall restore returned `RESTORE_FAILED`.

rc2 applies metadata in this order:

1. temporarily retain/add owner-write while metadata is being applied;
2. remove stale selected metadata and apply `user.*`;
3. install the final ordinary mode;
4. apply ACL xattrs after chmod, so chmod cannot rewrite ACL masks/semantics;
5. apply mtime last.

Strict mode remains fail-closed. Under explicit `--allow-degradation`, `ENOTSUP`, `EOPNOTSUPP`, `EACCES` and `EPERM` are degradable **only for selected xattr/ACL metadata operations**. Path, payload, decoding, malformed-envelope, chmod and verification errors remain fatal. Degraded metadata returns helper status 4 and is persisted by the restore as `metadata_fidelity=DEGRADED`.

## Gate additions

`test/run_34r2_b3_payload_safe_recovery.sh` now executes the critical metadata case as user `nobody` when possible: final mode `0444`, a real `user.*` xattr, and an unsupported `system.nfs4_acl`. It asserts helper rc=4, final mode 0444, archived mtime, and preservation of `user.*`. It also asserts that an empty ACL field followed by a non-empty xattr field survives journal tuple parsing without column shift.

## Status

The explicit degraded recovery path is the candidate for Francesco's immediate restore. Full TAR_PART ACL/xattr fidelity remains outside this emergency candidate and still depends on the real destination capability probe plus the planned independent second metadata pass.
