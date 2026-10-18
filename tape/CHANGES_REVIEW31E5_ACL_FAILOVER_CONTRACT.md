# Review 31E5 — central-log ACL failover contract test correction

31E5 supersedes the rejected 31E4 candidate.  Production runtime is unchanged from 31E4.

## Why 31E4 failed its privileged gate

31E4 intentionally made the runtime re-apply the central-user ACL contract whenever a user-owned
central log directory is prepared.  The old failover regression simulated an outage with
`chmod 0550 $CENTRAL`.  Because the archive user owns `$CENTRAL`, it is allowed to repair that mode
and ACL; the logger correctly restored the directory and kept it as the primary.  The test therefore
mistook successful self-healing for a failover defect.

## 31E5 test contract

`test/run_user_setup.sh` now verifies two distinct cases:

1. **Repairable leaf drift** — mode damage on the user-owned per-user log root is repaired by runtime
   ACL enforcement, logging remains central, and no failover warning is emitted.
2. **Real central outage** — the root-owned collection root (`BRIC_USER_LOG_ROOT`) is made
   non-traversable to the archive user.  The user cannot repair this condition, so logging must switch
   to the private home fallback and emit both the stderr warning and a structured `LOG_FAILOVER`
   breadcrumb.

No tape I/O, catalog schema, on-tape format, backup/restore logic, daemon logic, logging runtime, ACL
runtime, or updater behavior changes in 31E5 relative to 31E4.
