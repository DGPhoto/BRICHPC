# Review 31E4 — central user-log ACL enforcement

31E4 is a security/operability follow-up to installed Review 31E3. Tape I/O, streaming verification,
positioning, media-health policy, crypto, catalog schema and BRIC-FORMAT-V1 are unchanged.

## Trigger

After activating a real user on 31E3, the root per-user log directory had the intended ACL, but a
real `bric status` produced event/process files such as:

    user::rw-
    group::r--
    other::---

with owning group `users`, and no named `bric:r--` entry. Parent-directory isolation still prevented
ordinary horizontal traversal, so this was not an observed data disclosure; however the leaf-file
contract was wrong and a non-root BRIC administrator was not guaranteed read access. The root-only
onboarding regression checked the provisioned root and cross-user traversal but did not assert the
ACL on the actual files emitted by the runtime logger.

## Fix

For normal-user central logs under `BRIC_USER_LOG_ROOT/<effective-os-user>`:

- every runtime-created directory is normalized to `group::---`, named admin-group `r-x`, `other::---`,
  with the same default ACL inherited by descendants;
- every event/raw/process file is normalized to `group::---`, named admin-group `r--`, `other::---`;
- ACL application is fail-closed for the central destination: if `setfacl` is unavailable or fails,
  the logger treats the central write as failed and uses the private home fallback rather than leaving
  an ambiguously protected central file;
- detached background job directories and files use the same ACL contract;
- managed user environments now explicitly export `BRIC_USER_LOG_ROOT`, avoiding ambiguity between
  a central per-user log path and an arbitrary user-supplied `BRIC_LOG_DIR`;
- idempotent onboarding repairs existing central directories and single-link regular log files owned
  by the target user. It never follows symlinks and skips multiply-linked files, avoiding a hardlink
  confused-deputy path during privileged ACL repair.

## Regression strengthening

`run_user_setup.sh` now verifies ACLs on a real event file and a real captured process log, not only
on the root directory. It also creates a simulated pre-31E4 `0640` file and requires idempotent
onboarding to repair it. `bric-activate-user` validates the ACL on a real event emitted by its CLI
smoke. The local detached-job regression checks the actual job-log ACL when POSIX ACL tooling exists.

## Hardware scope

No tape-side runtime file is changed in 31E4. The 31D2 dense hardware smoke
`smoke_real1__20260907T143553Z__0012` remains the acceptance evidence for tape streaming/readback.
