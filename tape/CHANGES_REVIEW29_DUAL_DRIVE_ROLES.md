# CHANGES — Review 29: host roles, job-local OpenSSL and coherent dual-drive operation

Review 28 hardened real-user key handling and `WRITTEN` crash accounting. Review 29 prepares the
first real-user acceptance by separating the two machine roles and making PRIMARY/BACKUP use the two
healthy tape drives concurrently without weakening the terminal-state guarantees.

## 1. Explicit machine roles

Two installable configuration examples are now shipped:

- `config/bric-slurm.conf.example` — `BRIC_ROLE=slurm`, cluster catalog/QNAP paths, Slurm module and
  job-log settings;
- `config/bric-tape.conf.example` — `BRIC_ROLE=tape`, tape catalog, changer, both drives, independent
  locks and hardware timing.

Cluster commands call `require_role slurm`; the tape daemon calls `require_role tape`. A wrong-role
invocation is refused before catalog or hardware access. `bric-setup.sh --role slurm` is the canonical
cluster-side spelling; `--role cluster` remains a legacy alias.

## 2. OpenSSL 3.5 belongs to every Slurm job

The login shell is no longer treated as the crypto runtime. Backup and restore use real sbatch files:

- `cluster/slurm/orchestrate.sbatch`
- `cluster/slurm/archive_array.sbatch`
- `cluster/slurm/finalize_close.sbatch`
- `cluster/slurm/restore.sbatch`

Each file literally performs an initial `module purge`, establishes an EXIT cleanup trap, loads
`${BRIC_SLURM_OPENSSL_MODULE:-openssl/3.5.7}`, verifies OpenSSL >=3, and purges modules again on every
exit path. `BRIC_USER`, `BRIC_CONFIG`, local scratch, signing paths and the module selection are
explicitly propagated through both submission layers. Restore now runs synchronously through Slurm
instead of executing crypto on the RHEL 8 login shell.

## 3. Real two-drive PRIMARY/BACKUP streaming

`BRIC_TAPE_DRIVES="0 1"` and `BRIC_PARALLEL_DRIVES=2` now drive actual parallel work:

1. the changer lock is held only for inventory/load/unload movements;
2. each drive has an independent full-operation lock;
3. the required PRIMARY/BACKUP pair is normalized onto two distinct drives;
4. the two `write_copy` workers run concurrently;
5. each worker independently completes EOD positioning, append, filemark, readiness, read-back and
   SHA-256 verification;
6. the chunk `DONE` marker is published only after both workers have joined successfully and both
   catalog rows are `VERIFIED`.

The serial path remains available with `BRIC_PARALLEL_DRIVES=1` and is used for deterministic
between-copy fault injection and partial-pair recovery.

## 4. Close is paired too

Dual-drive operation continues through the sealing phase. For every tape pair:

- each signed close artifact is appended and read-back verified on PRIMARY and BACKUP concurrently;
- a catalog barrier verifies the full manifest on every tape;
- the two per-tape TOCs are appended and verified concurrently;
- only after every worker has joined does the daemon return media to slots;
- `run.CLOSED` is impossible until both transfer elements are empty and both cartridges are again
  visible in storage slots.

A fast drive cannot advance the close while the other is writing, reading back, rewinding or
expelling media.

## 5. Asymmetric load/ready/eject timing

The hardware layer now treats each drive as a separate state machine. It polls changer inventory and
`mt status` rather than assuming that a successful command means the drive is immediately usable.
The common limits are:

- `BRIC_DRIVE_READY_TIMEOUT`
- `BRIC_DRIVE_UNLOAD_TIMEOUT`
- `BRIC_DRIVE_COMMAND_TIMEOUT`
- `BRIC_DRIVE_STATUS_TIMEOUT`
- `BRIC_TAPE_IO_TIMEOUT`
- `BRIC_DRIVE_POLL_SECONDS`

Optional per-drive overrides are supported, for example:

- `BRIC_DRIVE_READY_TIMEOUT_0`, `BRIC_DRIVE_READY_TIMEOUT_1`
- `BRIC_DRIVE_UNLOAD_TIMEOUT_0`, `BRIC_DRIVE_UNLOAD_TIMEOUT_1`

Pair preparation tolerates a changer that returns from `load` before inventory catches up. It also
accepts an asynchronously completed load/unload even when the original `mtx` command returned
non-zero: confirmed inventory is authoritative, avoiding duplicate robotic commands against media
already in transition. Readiness is waited concurrently under the two drive locks. Final eject is
issued concurrently, robotic unload is serialized, and completion is inventory-confirmed for both
cartridges.

## 6. Restore terminal barrier

Restore still reads the preferred PRIMARY copy and falls back to BACKUP on read/SHA failure; it does
not wastefully decrypt both copies after the backup has already sealed them. However,
`request.STAGED` is withheld until staging has completed and `tape_release_all` confirms every
configured drive empty. The cluster restore therefore cannot finish while a drive is still rewinding,
ejecting or holding a cartridge.

## 7. Additional defect found during this review

Several tape-I/O subshells used:

```bash
exec 9>&- 2>/dev/null
```

Because `exec` had no command, that redirected the subshell's stderr permanently to `/dev/null` while
closing fd 9. A real drive failure could therefore lose its diagnostic text. Every occurrence now
uses a scoped group:

```bash
{ exec 9>&-; } 2>/dev/null || true
```

The singleton fd is still removed from workers, but later errors remain visible.

Tape-pair selection also used to check remaining capacity only on the PRIMARY tape. A pair is now
eligible only when **both** the PRIMARY and BACKUP cartridge belong to the same project, have the
expected roles/status/health, and each has enough usable capacity for the complete chunk. This
prevents a parallel run from starting when only one side of the pair can safely accept the copy.

## 8. Acceptance tests and runbook

Added:

- `test/run_parallel_drives.sh` — real logical user, deterministic unequal simulated drive speeds,
  concurrent starts, slower-worker join and bit-identical restore;
- `test/run_drive_state_timing.sh` — real-backend mocks with different load/readiness and eject delays,
  per-drive timeout overrides, and final two-drive-empty barrier;
- `test/run_host_roles.sh` — role-specific configs, wrong-role refusal and literal module lifecycle in
  every sbatch;
- `docs/RUNBOOK_real_user_dual_drive_acceptance.md` — mandatory VTL-first sequence followed by one
  explicitly selected real scratch pair.

`run_vtl.sh` and `run_parallel_drives.sh` accept:

```bash
BRIC_ACCEPTANCE_USER=<real_user>
BRIC_ACCEPTANCE_KEY_FILE=/secure/path/<real_user>_user_key.txt
```

The supplied key is copied only into the test's private temporary cluster-key directory and removed
with the test workroot. Review 28's ciphertext-only QNAP and local secret-scratch guarantees remain
in force.

## Validation performed in the review container

Passed:

- `bash -n` on every Bash/sbatch file;
- `test/run_host_roles.sh`;
- `test/run_wrapper_preflight.sh`;
- `test/run_drive_state_timing.sh` with deliberately asymmetric readiness/eject timing;
- `test/run_real_backend_mock.sh` after the tape-I/O changes;
- `test/run_crypto_params.sh` under OpenSSL 3.5.5.

The container has no native `sqlite3` CLI. A Python compatibility wrapper is functionally adequate
for small checks but too slow for the concurrent WAL-heavy full suite, so no full-suite PASS is
claimed here. `test/run_all_tests.sh` must pass natively on both AlmaLinux/brictape and RHEL 8/
supekgate before the VTL real-user acceptance, and the VTL acceptance must pass before any physical
cartridge is written.
