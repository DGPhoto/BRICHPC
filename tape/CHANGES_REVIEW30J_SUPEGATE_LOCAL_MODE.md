# Review 30J — direct supekgate execution mode

- `bric backup` and `bric restore` default to `BRIC_RUN_MODE=local`.
- The user-facing wrapper initializes Environment Modules and loads the configured OpenSSL module automatically.
- No `source`, `module load`, `sbatch`, Slurm partition, compute-node `/opt`, or compute-node NFS mount is required.
- The full backup pipeline runs synchronously in the invoking process on supekgate.
- `cluster/scripts/bric-enable-local-mode.sh` switches an existing `/etc/bric/bric.conf` installation to local mode idempotently, preserving a timestamped backup.
- Slurm mode remains available by setting `BRIC_RUN_MODE=slurm` after the archive compute nodes receive the required NFS mounts.
