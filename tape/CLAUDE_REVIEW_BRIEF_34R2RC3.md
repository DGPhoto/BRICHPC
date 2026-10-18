# Independent review brief — Review 34R2rc3

Please gate rc3 against rc2 and the real OneFS field finding. Focus on one behavioral change: under explicit metadata degradation, selected xattr/ACL operations may degrade on EINVAL in addition to ENOTSUP/EOPNOTSUPP/EACCES/EPERM. Verify strict mode still fails; unapproved namespaces still fail; EIO/ESTALE/ENOSPC/EROFS/ENOENT remain fatal; mtime is still attempted last after degraded ACL/xattr failures; the unprivileged 0444 regression remains green; run_33_restore_txn remains green; and tape/** remains byte-identical to 34R1.
