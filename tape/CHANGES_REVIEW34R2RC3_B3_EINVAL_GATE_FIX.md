# Review 34R2rc3 — OneFS EINVAL degradation gate fix

Baseline: Review 34R2rc2.

The real destination capability probe on the Isilon NFSv4.0 mount measured `setxattr("system.nfs4_acl", same_blob)` failing with `EINVAL` (errno 22). rc2 degraded only `ENOTSUP`/`EOPNOTSUPP`/`EACCES`/`EPERM`, so a LARGE_FILE_CHUNK carrying `system.nfs4_acl` could still return helper rc=1 under explicit `--allow-metadata-degradation`, skip mtime, and mark the whole restore failed despite verified payload.

rc3 adds `EINVAL` to the metadata-degradable errno set for selected xattr/ACL operations. This is deliberately narrower than “degrade any xattr error”: `EIO`, `ESTALE`, `ENOSPC`, `EROFS`, `ENOENT` and other storage/path failures remain fatal. Namespace fencing, envelope decoding, mode application, payload extraction, decrypt/HMAC and destination verification remain fail-closed.

A Go unit test now asserts the exact errno policy, including `EINVAL => degraded` and storage/path errors => fatal. Strict mode is unchanged. Tape code, tape format and database migration are unchanged.
