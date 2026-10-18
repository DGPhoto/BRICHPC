# Review 31E1 — centralized per-user logging and daemon FD hygiene

Review 31E1 supersedes both the un-deployed 31D3 candidate and the rejected/uninstalled 31E candidate. The production tape data path remains the 31D2 path that passed the native 64-test gate and the real dense smoke `smoke_real1__20260907T143553Z__0012` on `000001L9`/`000002L9`.

## Why 31E1 exists

The successful 31D2 smoke exposed two residual operational defects:

1. nested tape workers occasionally emitted `10: Bad file descriptor` because a child closed an inherited daemon lock FD, Bash later reused the same numeric descriptor for a redirection, and a second close helper acted on the stale number;
2. unprivileged cluster processes could not create `/var/log/bric/events/...` or `/var/log/bric/processes/...`, so they always fell back to `~/.bric/log`. A proposed 31D3 design made the private home log the primary, but that conflicts with the operator requirement for centralized audit visibility.

31E1 fixes both while keeping user logs mutually isolated.

## Central user logging model

System/root components continue to use `/var/log/bric`.

Activated users use:

- canonical user-log root: `BRIC_USER_LOG_ROOT=/var/log/bric/users` (independent of `BRIC_LOG_DIR` unless explicitly overridden);
- primary: `/var/log/bric/users/<effective-OS-user>`;
- fallback: `$HOME/.bric/log`;
- detached local job logs: `/var/log/bric/users/<user>/jobs`, with automatic fallback to `$HOME/.bric/log/jobs` if the central directory is unavailable.

The collection root is provisioned as `0751 root:<admin-group>`: administrators can enumerate it, ordinary users can traverse but cannot list it.

Each per-user directory is owned by the user. POSIX ACLs deliberately set the ordinary owning-group entry to `---` and grant the configured admin group (`BRIC_LOG_ADMIN_GROUP`, default `bric`) `r-x`. The same ACL is installed as a default ACL so dynamically-created event/date/host/process leaves and files inherit administrator read access without granting access to another ordinary user sharing a broad NSS group such as `users`.

The private home fallback remains mode `0700`.

## Existing users

New `bric-activate-user USER` invocations provision the central log tree and write both primary and fallback paths to the managed user environment.

Pre-31E1 managed environments remain runtime-compatible: if no explicit `BRIC_LOG_DIR` is present, the cluster logging libraries derive `/var/log/bric/users/$(id -un)` from the effective OS identity and preserve the existing `BRIC_LOG_FALLBACK_DIR` as fallback. The directory itself is privileged state, so after installing 31E1 administrators should rerun the idempotent activation command once for each existing user.

## FD fix

`tape/scripts/lib_common.sh` makes singleton and work-fence close helpers idempotent. Once inherited lock descriptors have been dropped in a child/subshell, their exported descriptor lists are cleared. A later helper call therefore cannot close a descriptor number that Bash has reused.

The standalone fallback helper in `lib_tape_io.sh` follows the same rule.

No tape daemon state machine, streaming verifier, positioning algorithm, media-health policy, database schema, encryption format, restore path, or on-tape format changes in 31E1.

## Validation

The release keeps the 64-test native suite and adds stronger assertions inside the existing user onboarding/activation tests for:

- centralized primary path;
- private home fallback;
- broad owning-group denial;
- named/default administrator ACL inheritance;
- cross-user read denial;
- root/admin central visibility;
- real primary-to-home failover;
- pre-31E1 environment compatibility;
- background job central/fallback directory behavior;
- idempotent singleton/work-FD closure after numeric descriptor reuse.

Because POSIX ACL provisioning is root-only, the release validation contract requires the normal 64/64 user gate plus explicit root runs of `run_user_setup.sh` and `run_user_activation.sh` before installation.
