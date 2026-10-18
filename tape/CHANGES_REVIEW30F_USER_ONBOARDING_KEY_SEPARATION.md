# CHANGES — Review 30F: root onboarding and strict master/user-key separation

## Trigger

A real archive user is an OS/AD/NSS identity whose Slurm jobs run under that user's UID. Review 30E
still made `bric-close.sh` look for both the personal key and the institution master key in the same
runtime key directory. That was acceptable in hermetic tests but wrong in production: an ordinary
user must never receive or read the master key merely to close a backup.

The deployment also lacked one canonical root command that performed the complete onboarding of a
new real user: NSS resolution, key generation, home installation, ownership/permissions, authenticated
escrow, idempotency and runtime access checks.

## Security model after Review 30F

- The **personal user key** lives only in the user's `~/.bric/<user>_user_key.txt` (`0600`) and in an
  authenticated, master-wrapped escrow ciphertext in the cluster catalog.
- The **institution master key** remains administrative/offline (`BRIC_MASTER_KEY_FILE`, normally
  `/root/.bric/master.key`) and never enters a user-owned Slurm job, the QNAP bus or the tape server.
- `bric-close.sh` encrypts `catalog_project.enc` with the personal key and copies the already wrapped
  catalog escrow to tape as `user_key_escrow.v1`. It performs no master-key operation.
- Admin break-glass DR reads `user_key_escrow.v1`, verifies its tape SHA, project/owner binding and
  escrow HMAC, unwraps the user key with the master, then opens the project catalog. Legacy tapes with
  `catalog_system.enc` remain supported.
- Runtime ownership is bound to the real OS/NSS account. An unprivileged user cannot operate as
  another archive owner by exporting a different `BRIC_USER`.

## New root onboarding command

`cluster/scripts/bric-setup-user.sh` is the canonical production entry point:

```bash
BRIC_CONFIG=/etc/bric/bric.conf \
BRIC_MASTER_KEY_FILE=/root/.bric/master.key \
  cluster/scripts/bric-setup-user.sh --user vsz652 --strict-runtime-checks
```

It:

1. requires root and resolves the account through `getent passwd` (AD/SSSD/NSS aware);
2. serializes catalog/home provisioning with a catalog-scoped `flock`;
3. performs home writes as the target user, so UID-based root-squashed homes work;
4. creates `~/.bric` (`0700`), the personal key (`0600`) and `env.sh` (`0600`);
5. generates exactly one 32-byte random Base64 key when neither home key nor escrow exists;
6. restores a missing home key from authenticated escrow without rotating it;
7. escrows an existing home key when the catalog row is missing;
8. verifies equality when both exist and fails closed on any mismatch;
9. leaves no second administrator plaintext handout by default (`--handout DIR` is explicit);
10. enables `require_user_escrow=1` and checks QNAP/signing-key access as the target UID.

Runtime access failures are warnings by default so a transient NFS outage does not prevent identity
recovery. `--strict-runtime-checks` turns them into a deployment gate.

## Registration changes

`bric-register-user.sh` adds `--escrow-only --key-file FILE`. This mode wraps and self-checks the
supplied key but does not copy it into the administrator key directory. Historical admin/staging
registration remains available. The ordinary `bric register-user` command is now explicitly root-only;
real users should be provisioned with `bric-setup-user.sh`.

## User runtime

`cluster/bin/bric` and `bric-run` automatically source `~/.bric/env.sh`. The generated file contains
paths only:

```bash
export BRIC_CONFIG=/etc/bric/bric.conf
export BRIC_USER=vsz652
export BRIC_USER_KEY_FILE=/home/.../.bric/vsz652_user_key.txt
```

The personal key path is propagated to archive/finalize/restore Slurm jobs. No `BRIC_MASTER_*` or
administrator key path is exported to user jobs.

## Tests

New `test/run_user_setup.sh` covers:

- real NSS user and user-owned home installation;
- `0700/0600` permissions;
- absence of the master and default handout from the user's/admin plaintext locations;
- authenticated v2 escrow equality;
- idempotent rerun without rotation;
- repair of a missing home key from escrow;
- fail-closed home/escrow mismatch;
- warning versus strict runtime-access behavior;
- rejection of unprivileged `BRIC_USER` impersonation.

`run_escrow.sh` now proves that a run closes after the master has been removed from the user runtime,
that the new escrow artifact is on tape, that user-key DR remains bit-identical, and that admin DR
works from tapes plus the master alone. Static security tests assert that close/submission paths no
longer reference the master.

The standard virtual suite now contains **40 tests**. Full native validation must be repeated on both
`supekgate04fl` and `brictape`.
