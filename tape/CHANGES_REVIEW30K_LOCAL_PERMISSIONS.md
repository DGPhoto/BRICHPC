# Review 30K — local-mode permissions and private runstate

- `bric-setup-user.sh` now creates `~/.bric/runstate` mode 0700 and writes
  `BRIC_RUNSTATE` into `~/.bric/env.sh`.
- Local backup planning no longer stores plaintext member lists below `/opt/bric2/cluster/db/runstate`.
- Onboarding grants the real OS/AD user an ACL on the cluster catalog directory and database, including
  default ACLs needed for SQLite WAL/SHM files.
- No local Unix group and no shell initialization are required.
- Existing onboarding is idempotent; rerunning it preserves the personal key and rewrites only paths/ACLs.
