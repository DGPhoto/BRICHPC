# Review 31D3 — idempotent daemon FD close + private user log primary

Review 31D3 is a narrow hardening release on top of the native-gated and real-hardware-smoked 31D2.
It does **not** change the streaming verifier, tape positioning, media-health policy, database schema,
crypto, bus protocol, restore semantics, or `BRIC-FORMAT-V1`.

## Why this release exists

The 31D2 real dense smoke `smoke_real1__20260907T143553Z__0012` completed `CLOSED` on the existing
`000001L9` / `000002L9` pair, verified both 54,904,509,472-byte copies, returned media to slots 7/44,
and kept `/tmp` at 39 MiB. Two non-tape correctness/hygiene issues remained visible:

1. The daemon emitted `10: Bad file descriptor` after successful parallel-copy workers. 31D runs each
   `one_pass` in a child, which drops inherited singleton FDs. A later Bash redirection can reuse the
   same numeric FD; a nested `write_copy` then called the close helper again using the stale list and
   could close Bash's newly reused descriptor.
2. Onboarded non-root users had a private `~/.bric/log`, but pre-31D3 env files exposed it only as
   `BRIC_LOG_FALLBACK_DIR`. The system `/var/log/bric` root could be writable while its
   `events/`/`processes/` children remained `root:bric 2770`, so every user command attempted the
   central tree, failed at the leaf hierarchy, and emitted a permanent false failover warning before
   logging correctly to the private home tree.

## FD lifecycle correction

`bric_close_daemon_singleton_fds` and `bric_close_daemon_work_fds` are now idempotent per process or
subshell. The first call closes the inherited numeric list and then stores an explicit empty list.
Subsequent calls are no-ops even if Bash has reused the same descriptor number for an unrelated
redirection. The standalone `lib_tape_io.sh` compatibility helper has the same property.

The parent daemon still holds the canonical and legacy singleton/work fences exactly as before; only
children that deliberately drop inherited descriptors change their local bookkeeping.

## User logging correction

`bric-setup-user` now writes:

```bash
export BRIC_LOG_DIR=$HOME/.bric/log
```

for normal users. Their private 0700 home log tree is therefore the primary destination, while
root/system components continue to use `/var/log/bric` and their configured durable fallback. No
permissions are widened on `/var/log/bric/events` or `/var/log/bric/processes`.

Backward compatibility is explicit: when a non-root process loads a pre-31D3 managed env containing
only `BRIC_LOG_FALLBACK_DIR=~/.bric/log`, the cluster logging libraries promote that path to primary
**before** loading the system config. Existing users therefore stop producing false failover warnings
immediately after the code update; re-running onboarding is not required for correctness. A later
`bric-setup-user` refresh rewrites the managed env into the new explicit-primary form.

## Memory observation from the real smoke

The post-smoke cgroup showed roughly 52 GiB in `memory.current`, but `memory.stat` attributed essentially
all of it to `file` / `inactive_file` cache while anonymous memory was only about 4 MiB and daemon RSS
was single-digit MiB. This is reclaimable Linux page cache from the large staging-file read, not a
stream-verifier memory leak. No cache-dropping or verifier buffering change is made in 31D3.

## Regression coverage

- `run_tape_singleton_migration.sh` now proves that a descriptor number can be closed, reused, and then
  survive a second close-helper call for both singleton and work-fence lists.
- `run_user_setup.sh` now requires private user logging to be the primary destination, emits a real
  structured event there with no failover warning, and verifies pre-31D3 fallback-only env promotion
  through both `lib_common.sh` and standalone `lib_logging.sh`.
- Existing logging failover tests remain unchanged and must still pass.

## Acceptance

A clean native gate on `supekgate04fl` must report **64 OK, 0 FAIL**. Because 31D3 does not change the
tape streaming/positioning path or on-tape representation, the successful 31D2 real dense smoke remains
the hardware acceptance evidence for the streaming verifier; another 55 GB-per-copy smoke is not
required solely for these FD/logging fixes.
