# CHANGES — Review 28: real-user acceptance hardening

Review 27 fixed deterministic daemon crash recovery. A further code-path review before the first
real-user hardware test found two independent gaps: secret-bearing scratch on the QNAP reverse bus,
and loss of the logical user/OpenSSL module environment across restricted Slurm exports.

## Security defect

`bric-close.sh` used `RUN_DIR/close` for:

- `.encpass`, containing the deterministic user-derived encryption key;
- `catalog_project.db` and its plaintext SQL dump;
- the plaintext full-system catalog dump.

`bric-restore.sh` used the QNAP restore request directory for `.pass`, again containing the
user-derived encryption key. Deletion after use was insufficient: the tape host could read these
files while present, and deletion on shared storage is not secure erasure. This contradicted the
architecture's keyless tape-server / ciphertext-only bus invariant.

## Slurm identity and OpenSSL-module defect

The command is normally launched by the operational account while `BRIC_USER` identifies the real
archive owner. The explicit `sbatch --export=...` allow-lists omitted `BRIC_USER`, so the orchestrator
would fall back to the operational Unix account and register the project under the wrong owner. The
allow-lists also omitted the runtime environment selected by the OpenSSL module, so the wrapper could
validate OpenSSL 3.5 on the login shell while the Slurm jobs used the RHEL system OpenSSL.

The two submission layers now propagate `BRIC_USER`, `BRIC_CONFIG`, `PATH`, `LD_LIBRARY_PATH`,
`OPENSSL_CONF`, and `OPENSSL_MODULES` explicitly. The whole login environment is still not exported.

## Fix

- Secret-bearing and plaintext scratch is created with `mktemp -d` under cluster-local
  `${BRIC_LOCAL_TMPDIR:-/tmp}`.
- The local directory is removed on every exit path.
- Only encrypted catalogs, signatures, markers, staged ciphertext and the deliberately plaintext
  recovery kit are placed on the QNAP bus.
- `BRIC_LOCAL_TMPDIR` is exported through the Slurm orchestrator and dependent jobs when configured.
- The sample configuration documents that this path must be local storage, never QNAP/NFS.
- Security regression checks reject reintroduction of `.pass`, `.encpass`, or plaintext close
  catalogs on bus paths.
- Wrapper regression checks require the real-user identity and OpenSSL module runtime to survive both
  Slurm submission layers.

## Validation performed in the review container

- `bash -n` on all modified shell scripts: PASS.
- Static security regression checks for scratch-path placement: PASS.
- Full integration tests could not run in this container because its package image lacks the
  `sqlite3` CLI. Run `test/run_all_tests.sh` on the AlmaLinux and RHEL 8 validation hosts before
  promotion, as with Review 27.

## Remaining deployment gate, not changed here

- Do not use SQLite WAL with clients on different hosts against a database on a network filesystem.
  Keep all access on one host/local filesystem, or change the catalog architecture/journal mode.

## Real-tape capacity-accounting defect

The physical append path records a segment as `WRITTEN` before read-back verification. Review 27
recovery only handled `WRITING`. A daemon crash after the append but during read-back therefore left
a real tape file in `WRITTEN`: the next attempt could append the same logical copy again, while the
capacity of the first physical file was never charged to `used_tb`.

There were also crash windows because the segment-state change and tape-capacity update were separate
SQLite statements. A process could leave a `VERIFIED` or `ABANDONED` segment whose physical bytes had
not yet been accounted.

Review 28 now:

- recovers both interrupted `WRITING` and `WRITTEN` rows;
- atomically marks the segment abandoned and charges its physical bytes with one
  `BEGIN IMMEDIATE` transaction;
- atomically commits `VERIFIED` together with the tape-capacity update;
- atomically commits read-back failure, capacity accounting and tape-health/error state;
- adds `BRIC_FAULT_AFTER_WRITTEN_DELAY` as a deterministic test hook;
- adds `test/run_written_recovery.sh`, which kills the daemon in the `WRITTEN` window, verifies that
  the orphan append is charged exactly once, and confirms that the run is recovered to `CLOSED`.

## Updated validation performed in the review container

- `bash -n` on all modified shell scripts: PASS.
- `test/run_wrapper_preflight.sh`: PASS.
- Static security regression checks for scratch-path placement: PASS.
- Deterministic `WRITTEN` recovery test: PASS using a Python SQLite CLI compatibility shim.
- A full native 32/32 suite was not run in the review container because it lacks the native
  `sqlite3` executable. It must pass on both validation hosts before any real-tape test.

## Operational wait/runbook corrections

- `bric backup --wait` now watches the catalog for `CLOSED`, `FAILED`, or `CANCELLED`. Review 27
  could wait for up to 24 hours for a `run.CLOSED` marker even after the run had already failed.
  `BRIC_WAIT_TIMEOUT` controls the terminal-state wait.
- The installation runbook now shows the mandatory real-tape `--yes-overwrite <barcode>` guard.
- The acceptance runbook no longer implies that gate-side `bric-run` can inspect tape devices that
  physically exist only on `brictape`; it requires the hardware preflight on the tape host and uses
  `--skip-preflight` for the gate invocation.
