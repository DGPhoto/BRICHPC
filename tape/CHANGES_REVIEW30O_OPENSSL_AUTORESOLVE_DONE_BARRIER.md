# Review 30O — OpenSSL auto-resolution and strong DONE barrier

Date: 2026-07-29

## Problem observed on the real hosts

The Review 30N suite exposed two independent issues:

1. On `supekgate`, root could see the configured `openssl/3.5.7` module but could not load it.
   Local/background and one-command tests therefore failed before reaching the behavior they were
   intended to test. A fixed module name was the wrong invariant because module visibility and module
   ACLs are not necessarily identical for root and normal users.
2. On `brictape`, `run_posix.sh` occasionally observed a `.DONE` marker while the corresponding QNAP
   blob still existed for a fraction of a second. The daemon published DONE before reclaiming the bus
   blob, so the test was exposing a real ordering race.

## OpenSSL runtime resolver

A single resolver now lives in `cluster/scripts/lib_common.sh` and is used by local execution and all
four Slurm entry points.

Resolution policy:

1. Run `openssl version`.
2. If the active OpenSSL major version is at least `BRIC_OPENSSL_MIN_MAJOR` (default `3`), keep it and
   do not initialize or modify Environment Modules.
3. Otherwise initialize modules from `BRIC_MODULE_INIT`.
4. Purge modules only inside the BRIC child process/job.
5. Try `BRIC_SLURM_OPENSSL_MODULE` first as a preference, not as a hard dependency.
6. Read `module -t avail openssl` (falling back to `module avail openssl`), extract compatible
   versions, sort them newest-first with version sorting, and try each until one both loads and
   exposes OpenSSL >=3.
7. If a visible module is denied to the current UID, continue to the next candidate. Thus a root run
   can skip an inaccessible `openssl/3.5.7` and use `openssl/3.1.0`.
8. Fail explicitly only when no compatible loadable module exists.

The selected runtime is exported through:

- `BRIC_OPENSSL_VERSION`
- `BRIC_OPENSSL_MODULE_SELECTED`
- `BRIC_OPENSSL_MODULE_LOADED`

Slurm jobs purge on EXIT only when BRIC actually loaded a module.

## Strong DONE barrier

`tape/bin/bric-tape-daemon` now reclaims and verifies removal of the encrypted blob and sidecars
before publishing the signed `.DONE` marker.

The externally visible invariant is now:

> When `.DONE` is visible, both tape copies are VERIFIED and bus reclamation has already been
> attempted. If reclamation failed, the daemon emitted the existing loud warning.

Crash safety is preserved. If the daemon dies after freeing the blob but before publishing DONE, the
existing idempotent path reconstructs DONE from the two VERIFIED tape-catalog rows without rewriting
the payload.

## Test corrections

- `run_wrapper_preflight.sh` now simulates exactly the production ACL case: `openssl/3.5.7` is listed
  but denied, while `openssl/3.1.0` is loadable. It also verifies that an already suitable OpenSSL is
  retained without initializing modules.
- `run_local_background.sh` and `run_one_command_ux.sh` now provide a hermetic fake OpenSSL >=3 so
  those tests do not depend on the host module tree.
- `run_host_roles.sh` verifies use of the shared resolver rather than requiring literal `module load`
  lines in every sbatch file.
- `run_tar_stream.sh` no longer assumes filesystem enumeration order or that chunk 1 is a TAR_PART;
  it restores all TAR_PART chunks and validates a selected ciphertext independently.
- The existing `run_posix.sh` assertion remains unchanged and now tests the stronger DONE invariant.

## Compatibility

- No SQLite schema change.
- No catalog reset required.
- No key or escrow change.
- No ciphertext-format change.
- No tape-format change.
- The configuration variable `BRIC_SLURM_OPENSSL_MODULE` remains supported as a preferred candidate.
- New optional configuration: `BRIC_OPENSSL_MIN_MAJOR=3`.

## Deployment scope

Update `supekgate` for the resolver and test fixes. Update `brictape` as well for the DONE ordering
fix. The two updates do not require a coordinated catalog migration or daemon downtime beyond the
normal file replacement/restart.
