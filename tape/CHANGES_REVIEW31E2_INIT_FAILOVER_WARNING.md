# Review 31E2 — explicit initialization failover warning

Review 31E2 supersedes the failed-gate, uninstalled 31E1 candidate. It carries forward the 31E1 centralized per-user logging and daemon FD-hygiene changes unchanged, with one logging correctness fix found by the privileged onboarding gate on `supekgate04fl`.

## Failure found in 31E1

`sudo bash test/run_user_setup.sh` proved that a real central-primary failure correctly selected the private home fallback and still wrote the structured user event, but the test failed because no explicit `failover` warning was emitted.

The runtime was still printing the legacy initialization message:

```text
WARN: /var/log BRIC log unavailable; using NFS fallback ...
```

That wording was no longer correct for user logging because the 31E-series primary is `/var/log/bric/users/$USER` and the fallback is normally `$HOME/.bric/log`, not NFS. It also did not identify the primary path and did not contain the canonical `failover` term used by the mid-run failover path.

## 31E2 fix

All three logging-library copies now emit the same generic initialization warning when the primary is unavailable and the fallback is writable:

```text
WARN: BRIC structured log failover primary=<primary> fallback=<fallback> trigger=initialization
```

Changed copies:

- `cluster/scripts/lib_common.sh`
- `cluster/scripts/lib_logging.sh`
- `tape/scripts/lib_common.sh`

No ACL, onboarding, tape state-machine, streaming verify, positioning, media-health, database schema, encryption, restore, or on-tape-format behavior changes in 31E2.

## Validation requirement

The authoritative root gate is:

```bash
sudo bash test/run_user_setup.sh
sudo bash test/run_user_activation.sh
```

The forced central-primary failure must select the private fallback **and** emit the explicit failover warning.
