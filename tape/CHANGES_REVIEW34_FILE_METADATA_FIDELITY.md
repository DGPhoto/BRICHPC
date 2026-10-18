# Review 34 — file metadata fidelity

Baseline: Review 33R3 final (`BRIC-FORMAT-V1`). Review 34 addresses metadata loss that is intrinsic to `LARGE_FILE_CHUNK`: oversized members are split as raw payload bytes after the TAR header has been consumed, so mode/ACL/xattr metadata cannot be recovered from the chunk payload.

## Changes

- Adds nullable `files.mode` and `files.metadata_b64` columns through re-entrant migration `files-v34-mode-metadata`.
- Existing pre-34 rows remain `mode=NULL`, `metadata_b64=''`. Their already-recorded `mtime` is now re-applied after large-file restore, so historical mtime is recoverable without inventing unavailable metadata.
- New `LARGE_FILE_CHUNK` files store source mode plus a versioned Base64 metadata envelope in the encrypted project catalog. The envelope contains only `user.*`, raw POSIX ACL xattrs, and `system.nfs4_acl`; `security.*`, `trusted.*` and unrelated `system.*` namespaces are excluded.
- `bric-file-metadata` is a static Go helper used for binary-safe capture/application. Metadata is captured before and after the oversized payload read; drift aborts production.
- Large-file mode/ACL/xattrs/mtime are applied only after payload checksum verification and before restrictive directory metadata finalization. Ownership is intentionally not restored (`--no-same-owner` semantics remain).
- TAR_PART creation/restoration now uses GNU tar ACL/xattr support (`--acls --xattrs`, `user.*`, `system.nfs4_acl`) in one-pass, parallel, sparse-batch, Slurm, normal restore and DR paths.
- Review 33's directory metadata transaction now snapshots/restores `system.nfs4_acl` in addition to `user.*`, while continuing to exclude SELinux/security/trusted/system POSIX ACL xattrs; POSIX ACLs remain handled by `getfacl/setfacl`.
- Slurm planner records large-file mode/envelope; chunk tasks re-check them before and after production along with size/mtime.
- DR upgrades old decrypted project catalogs in its temporary database, allowing pre-34 tapes to recover historical large-file mtime.
- Physical chunk/tape layout and crypto framing remain `BRIC-FORMAT-V1`.

## Compatibility

- Old archive: mtime for oversized files can be restored because it was already catalogued. Historical mode/ACL/xattr values cannot be reconstructed and are deliberately left unknown.
- New archive: mode, mtime and selected ACL/xattrs are preserved for both TAR_PART and LARGE_FILE_CHUNK objects.
- UID/GID ownership is not preserved by design; restored objects remain owned by the restoring identity.

> Review 34R1 clarification: "mode" fidelity means ordinary `0777` regular-file permission bits. Setuid/setgid/sticky bits on regular files are deliberately cleared on both TAR_PART and LARGE_FILE_CHUNK paths because UID/GID ownership is not restored. Directory sticky semantics are not globally stripped.
