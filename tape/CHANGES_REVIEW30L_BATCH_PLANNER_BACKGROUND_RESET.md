# Review 30L — batched planner, detached local jobs, catalog reset

## Planner scalability

`bric-plan.sh` no longer starts multiple `sqlite3` and `stat` processes for every file.

- GNU `find` supplies path, size and mtime in one traversal.
- Regular files are not globally sorted; lexical order is not a correctness invariant.
- Chunk/file SQL is written to private run scratch and committed in one `BEGIN IMMEDIATE` transaction.
- TAR chunk sizes are updated once per chunk rather than once per member.
- Planning progress is written atomically to `~/.bric/runstate/<run>/progress` every 5,000 files by default.
- `bric status` displays the live planning stage/file/byte/chunk counters.
- Interrupted planning marks the run `FAILED` instead of leaving it permanently `PLANNING`.

This removes the observed ~39,000-file/four-hour failure mode caused by one SQLite process per statement.

## Local background execution

In `BRIC_RUN_MODE=local`, backup and restore now detach by default:

```bash
bric backup PROJECT SOURCE
bric restore PROJECT DEST
```

The command immediately prints a job id, PID and log path. The detached supervisor uses a new session/process group, survives SSH logout and records metadata under `~/.bric/pids`.

New commands:

```bash
bric jobs
bric log JOB_ID_OR_PID
bric cancel JOB_ID_OR_PID
```

Use `--wait` to retain foreground execution. Root onboarding creates and configures the private PID and background-log directories automatically.

## Safe catalog reset

New root-only command:

```bash
cluster/scripts/bric-reset-catalog.sh --yes
```

It creates a consistent timestamped SQLite backup, then removes operational state (projects, runs, chunks, files, reservations, project/tape mappings and audit rows) while preserving `config` and `users`/key escrow. It refuses to run while BRIC processes are active unless `--force` is explicitly supplied.

## Tests

Added:

- `run_planner_batching.sh`
- `run_local_background.sh`
- `run_catalog_reset.sh`

The suite now contains 44 non-hardware tests.
