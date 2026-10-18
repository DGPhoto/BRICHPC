# Review 31C1 — test-contract correction

31C1 is a test-only point release over 31C. Production runtime is intentionally unchanged.

## Why

The native 61-test gate on `supekgate04fl` exposed three failures. Two were stale assertions after
31C deliberately changed the singleton diagnostic and broadened the setup daemon collision probe. 31C1 removes
the singleton wording dependency entirely and tests the locking/collision behavior instead.
The third exposed a latent bug in the historical `run_real_e2e.sh` `mt` mock: `rewind) echo 0>"$st"`
does not write the character `0`; Bash parses `0>` as an fd redirection. 31B1 happened to tolerate
the empty mock position. 31C correctly validates the absolute fallback landing and therefore rejected it.

## Changes

- `run_daemon_crash.sh`: assert behavior rather than diagnostic wording: a concurrent daemon must be refused while the original remains alive; after a crash, the recovery daemon must actually acquire the singleton and remain running.
- `run_setup_e2e.sh`: assert the collision probe semantically: extract the regex actually passed to `pgrep -f` and require it to match a daemon command line from an arbitrary historical extracted tree.
- `run_real_e2e.sh`: write numeric rewind state correctly, model validated `bsfm 2` semantics, and force
  the first `bsfm` command to fail so the full daemon E2E proves `rewind`-only fallback for catalog file #1.
- `run_real_backend_mock.sh`: add an explicit file-1 `bsfm` command-failure fallback regression (`rewind`, no `fsf`), while retaining the successful-but-wrong landing regression for a later file.
- Release-sensitive tests derive their expected review/release ID from `RELEASE`.

## Runtime invariant

Production runtime under `cluster/` and `tape/`, plus `bric-update` and `bric-setup.sh`, is byte-identical to the published 31C tarball. Other differences are release/document/test metadata only.
`BRIC-FORMAT-V1` is unchanged.
