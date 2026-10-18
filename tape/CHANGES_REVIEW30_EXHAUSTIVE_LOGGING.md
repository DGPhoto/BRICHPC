# CHANGES — Review 30: durable exhaustive logging with local/NFS failover

## Requirement

All archive processes, state transitions and errors must be reconstructible. Both hosts write primarily
to `/var/log/bric`; a host/user unable to write there automatically uses a configured persistent shared
fallback. A future tool will render these records in a user-friendly form, so the machine format is
versioned now as `BRICLOGv1`.

## Implementation

### One canonical logger on each role

The lockstep `lib_common.sh` copies implement:

- per-process structured `events.v1.log` files;
- separate raw stdout and stderr files without changing caller-visible streams;
- primary `/var/log/bric` plus automatic persistent fallback;
- runtime failover if the primary disappears;
- `0640` files; setgid `bric` directories for centralized reading, with non-listable sticky directories only as a compatibility fallback;
- `PROCESS_START/END`, PID/PPID, role, logical user, Slurm IDs and operation context;
- fail-closed `BRIC_REQUIRE_LOGGING=1`: rc 70 if no durable destination exists;
- database-audit fallback events instead of silently swallowing SQLite audit failures.

No shell tracing is used and no secret values are logged.

### Slurm/gate coverage

- All backup and restore sbatch stages load the configured OpenSSL module and log load/purge lifecycle.
- Orchestrator, chunk-array, finalize and restore job IDs/output paths are structured events.
- Slurm output is directed to `/var/log/bric/slurm` when writable, otherwise to the configured NFS
  fallback `slurm/` directory.
- `BRIC_ROLE`, logical `BRIC_USER`, logging policy and destinations propagate through both submission
  layers.
- Planning, production, finalization, close, restore, DR, key registration, wrapper, setup and bus-key
  tools have process lifecycle records.
- QNAP/Isilon healthcheck records mount failures, node drain success and drain errors.
- The web job records lifecycle/module/errors but intentionally does not duplicate token-bearing stdout.

### Tape coverage

- Daemon mode, singleton lock, crash work-fence wait and recovery counts.
- Reservation, claim, drain, PRIMARY/BACKUP parallel barrier, close, abort and restore-stage events.
- Per-drive load/readiness/EOD/write/filemark/rewind/FSF/read/offline/unload/inventory events.
- Original hardware-command stderr, return code, duration and byte count.
- Segment and artifact state transitions plus verification/mismatch context.
- Independent readiness/eject timing and the final both-drives-empty barrier.

The old `exec 9>&- 2>/dev/null` diagnostic-loss issue remains corrected with scoped redirections.
`_status()` now also preserves the actual failing `mtx status` return code; the prior post-`if` `$?`
was always zero in Bash.

### Configuration

Role examples now define:

```text
BRIC_LOG_DIR=/var/log/bric
BRIC_LOG_FALLBACK_DIR=<persistent shared path for that host>
BRIC_LOG_CAPTURE_STDIO=1
BRIC_REQUIRE_LOGGING=1
BRIC_LOG_MAX_MESSAGE=4000
```

`bric-setup.sh` parses the role before loading defaults, so tape setup cannot accidentally select the
Slurm fallback merely because both source trees are present. It provisions both roots idempotently.

### Tests

New `test/run_logging.sh` proves:

- stdout API and stderr preservation;
- exact process exit-code preservation;
- 23-field `BRICLOGv1` records and context fields;
- newline/pipe sanitization;
- `0640` event/raw files;
- startup fallback to NFS;
- live primary-to-fallback switch;
- fail-closed rc 70 when both roots are unavailable.

Review 29A's dual-drive assertion also receives the defensive positive-integer guard on planned
`runs.n_chunks`, preventing a false `0 == 0` pass.

## Validation performed in this build environment

Passed:

- syntax check of every shell/bin/sbatch entry point;
- `run_logging.sh`;
- `run_host_roles.sh`;
- `run_wrapper_preflight.sh`;
- `run_drive_state_timing.sh`;
- `run_real_backend_mock.sh`;
- `run_crypto_params.sh`.

The container has no native `sqlite3` CLI. A compatibility wrapper was sufficient for static/config
checks but is not accepted as evidence for concurrent WAL paths; therefore no full-suite PASS is claimed
here. Run the complete suite with native SQLite on both deployment hosts before VTL acceptance.

## Deliberate non-goals

- No user-friendly reader yet; the stable format is the prerequisite for it.
- No automatic deletion/retention policy; evidence is never silently removed.
- This review improves observability only. Drive failover/retry policy after a single-drive write
  failure remains a separate correctness change and must be fault-injected on VTL before tape use.
