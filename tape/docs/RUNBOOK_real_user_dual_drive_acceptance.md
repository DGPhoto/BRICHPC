# BRIC Archive 2.0 — real-user acceptance: VTL first, then one real tape pair

This is the promotion sequence for Review 30F.  Do not skip the virtual phase.  The logical owner is a
real registered BRIC user in both phases; the first phase writes only to the file-backed VTL, the
second phase writes to one explicitly selected scratch PRIMARY/BACKUP pair.

## 0. Preconditions

On `supekgate`, `/etc/bric/bric.conf` must be based on `config/bric-slurm.conf.example` and contain:

```bash
BRIC_ROLE=slurm
BRIC_RUN_MODE=slurm
BRIC_MODULE_INIT=/etc/profile.d/modules.sh
BRIC_OPENSSL_MIN_MAJOR=3
BRIC_SLURM_OPENSSL_MODULE=openssl/3.5.7   # preferred; automatic fallback enabled
```

On `brictape`, `/etc/bric/bric.conf` must be based on `config/bric-tape.conf.example` and contain:

```bash
BRIC_ROLE=tape
BRIC_TAPE_BACKEND=real
BRIC_TAPE_DRIVES=0 1
BRIC_PARALLEL_DRIVES=2
BRIC_UNLOAD_ON_COMPLETE=1
```

Use per-drive timing overrides when the mechanisms differ:

```bash
BRIC_DRIVE_READY_TIMEOUT_0=900
BRIC_DRIVE_READY_TIMEOUT_1=1800
BRIC_DRIVE_UNLOAD_TIMEOUT_0=900
BRIC_DRIVE_UNLOAD_TIMEOUT_1=1200
BRIC_TAPE_IO_TIMEOUT_0=21600
BRIC_TAPE_IO_TIMEOUT_1=25200
```

On `supekgate`, root must first onboard the real NSS/AD identity. The master remains root-only;
the user receives only their personal key and a path-only environment file:

```bash
BRIC_CONFIG=/etc/bric/bric.conf \
BRIC_MASTER_KEY_FILE=/root/.bric/master.key \
  /opt/bric2/cluster/scripts/bric-setup-user.sh --user vsz652 --strict-runtime-checks
```

Then log in normally as that user:

```bash
ACCEPT_USER=$(id -un)                         # expected: vsz652
ACCEPT_KEY="$BRIC_USER_KEY_FILE"
ACCEPT_SRC=/path/to/a/small/test/dataset
ACCEPT_DEST=/path/to/empty/restore/destination
```

Do not export a different `BRIC_USER`: Review 30F binds ownership to the real OS/NSS account and
ignores unprivileged impersonation attempts.

## 1. Full virtual acceptance on both hosts

Run the ordinary suite first:

```bash
cd /opt/bric2/test
bash run_all_tests.sh
```

Expected: all virtual tests pass, including:

- `run_parallel_drives.sh` — PRIMARY/BACKUP overlap asynchronously; the faster worker may finish first and the slower worker is awaited within its own timeout;
- `run_drive_state_timing.sh` — different ready/eject timings and per-drive timeout overrides;
- `run_vtl.sh` — full real-backend path through mocked `mtx`, `mt` and `dd`;
- crash, close, restore fallback, WAL and recovery tests.

Then run the VTL end-to-end explicitly with the real logical user and its real key:

```bash
BRIC_ACCEPTANCE_USER="$ACCEPT_USER" \
BRIC_ACCEPTANCE_KEY_FILE="$ACCEPT_KEY" \
KEEP=1 \
bash run_vtl.sh
```

`KEEP=1` prints and preserves the temporary workroot for inspection.  Verify there is no key or
plaintext catalog on the simulated QNAP bus:

```bash
VTL_WORKROOT=<workroot printed by run_vtl.sh>
find "$VTL_WORKROOT"/qnap -type f \
  \( -name '.pass' -o -name '.encpass' -o -name 'catalog_project.db' \
     -o -name 'catalog_project.sql' -o -name 'catalog_system.sql' \) -print
```

Also confirm that the new close artifact is ciphertext-only and no master file appears anywhere in
that workroot:

```bash
find "$VTL_WORKROOT/qnap" -type f -name 'master.key' -print
```

Expected: no output.  Remove the preserved workroot after inspection.

**Virtual gate:** do not touch physical media unless the complete suite and the real-user VTL test
both pass.

## 2. Select and verify one physical scratch pair

On `brictape`, stop any manual tape operation and run:

```bash
/opt/bric2/tape/bin/bric-library-preflight
mtx -f "$BRIC_CHANGER" status
```

Choose one catalogued pair whose two rows are `EMPTY`, `health='OK'`, `used_tb=0`, and have no project:

```bash
sqlite3 -header -column "$BRIC_TAPE_DB" "
SELECT p.pair_number,
       p.volumetag AS primary_vt,
       b.volumetag AS backup_vt,
       p.slot AS primary_slot,
       b.slot AS backup_slot,
       p.status AS primary_status,
       b.status AS backup_status,
       p.health AS primary_health,
       b.health AS backup_health,
       p.used_tb AS primary_used_tb,
       b.used_tb AS backup_used_tb,
       p.project_name AS primary_project,
       b.project_name AS backup_project
FROM tapes p
JOIN tapes b ON b.volumetag=p.paired_volumetag
WHERE p.role='PRIMARY'
ORDER BY p.pair_number;"
```

Physically verify the two barcodes against `mtx status`.  Do not reuse a cartridge written by
`run_real_tape_smoke.sh` unless it has been erased/reset and its catalog row has been reconciled; that
smoke test writes files outside the BRIC catalog.

## 3. Prepare a small, representative dataset

Use data that can be destroyed and that has another trusted copy.  Include directories, small files,
a larger file and a symlink:

```bash
mkdir -p "$ACCEPT_SRC/subdir" "$ACCEPT_SRC/empty-directory"
printf 'BRIC dual-drive acceptance\n' > "$ACCEPT_SRC/subdir/readme.txt"
dd if=/dev/urandom of="$ACCEPT_SRC/blob.bin" bs=1M count=1024 status=progress
ln -s subdir/readme.txt "$ACCEPT_SRC/readme-link"

(
  cd "$ACCEPT_SRC"
  find . -type f -print0 | sort -z | xargs -0 sha256sum
) > /tmp/bric-accept-source.sha256
(
  cd "$ACCEPT_SRC"
  find . -type l -printf '%P|%l\n' | sort
) > /tmp/bric-accept-source.symlinks
```

## 4. Start the tape daemon and watch both drives

On `brictape`, with the tape-role config loaded by the program:

```bash
/opt/bric2/tape/bin/bric-tape-daemon --loop 2>&1 | tee /var/tmp/bric-real-accept-daemon.log
```

Run it under the normal service manager instead when one already exists.  In another terminal watch:

```bash
watch -n 2 'mtx -f /dev/sg4 status; echo; mt -f /dev/nst0 status 2>&1 | head -4; echo; mt -f /dev/nst1 status 2>&1 | head -4'
```

The two cartridges may become ready or eject at different times.  This is expected.  A BRIC terminal
state must not appear until both worker operations have joined and both drives are empty.

## 5. Submit the real-user backup through Slurm

Immediately before submission, rerun `bric-library-preflight` on `brictape`.  Then on `supekgate`:

```bash
/opt/bric2/cluster/bin/bric-run --skip-preflight backup \
  --project bric_dual_drive_acceptance \
  --source "$ACCEPT_SRC" \
  --wait | tee /tmp/bric-accept-run.txt

RUN_ID="$(tail -1 /tmp/bric-accept-run.txt)"
printf 'RUN_ID=%s\n' "$RUN_ID"
```

The Slurm orchestrator, chunk array and finalize/close job each execute their own:

```bash
module purge
# Normally automatic; this manual probe tests the preferred candidate only.
module load "$BRIC_SLURM_OPENSSL_MODULE"
# work
module purge     # EXIT trap, success or failure
```

Check the Slurm logs and verify that every job reports OpenSSL 3.5.x.

## 6. Backup acceptance criteria

On `supekgate`:

```bash
sqlite3 -header -column "$BRIC_DB" "
SELECT run_id,project_name,owner,status,n_chunks,total_bytes,closed_at,error
FROM runs WHERE run_id='$RUN_ID';
SELECT state,COUNT(*) FROM chunks WHERE run_id='$RUN_ID' GROUP BY state;"
```

On `brictape`:

```bash
sqlite3 -header -column "$BRIC_TAPE_DB" "
SELECT copy_role,state,COUNT(*)
FROM segments WHERE run_id='$RUN_ID'
GROUP BY copy_role,state;
SELECT volumetag,kind,state,COUNT(*)
FROM tape_artifacts WHERE run_id='$RUN_ID'
GROUP BY volumetag,kind,state
ORDER BY volumetag,kind;"

mtx -f "$BRIC_CHANGER" status
```

Required result:

- run is `CLOSED` and owner equals the real logical user;
- every chunk is `DONE`;
- exactly one `VERIFIED` PRIMARY and one `VERIFIED` BACKUP segment per chunk;
- every close artifact and the latest TOC are `VERIFIED` on both cartridges;
- both transfer elements are `Empty` and both barcodes are back in storage slots;
- daemon log contains the dual-drive path and final media barrier;
- no `.pass`, `.encpass` or plaintext catalog exists under the QNAP bus.

## 7. Restore through Slurm

On `supekgate`:

```bash
rm -rf "$ACCEPT_DEST"
/opt/bric2/cluster/bin/bric-run --skip-preflight restore \
  --project bric_dual_drive_acceptance \
  --run "$RUN_ID" \
  --dest "$ACCEPT_DEST"
```

The restore reads PRIMARY first and falls back to BACKUP only if read or SHA verification fails.  It
does not redundantly decrypt both copies; the two-copy requirement was already sealed by the backup.
Nevertheless, `request.STAGED` is withheld until all tape work is complete and every configured drive
is empty with its cartridge inventoried back in a slot.

Verify the result:

```bash
(
  cd "$ACCEPT_DEST"
  find . -type f -print0 | sort -z | xargs -0 sha256sum
) > /tmp/bric-accept-restored.sha256
(
  cd "$ACCEPT_DEST"
  find . -type l -printf '%P|%l\n' | sort
) > /tmp/bric-accept-restored.symlinks

diff -u /tmp/bric-accept-source.sha256 /tmp/bric-accept-restored.sha256
diff -u /tmp/bric-accept-source.symlinks /tmp/bric-accept-restored.symlinks
test -d "$ACCEPT_DEST/empty-directory"
mtx -f "$BRIC_CHANGER" status
```

Expected: both `diff` commands are silent, the empty directory exists, and both drives are empty.

## 8. Failure rule

Any failed SHA, missing second copy, non-`VERIFIED` close artifact/TOC, loaded drive after terminal
state, wrong owner, wrong OpenSSL version, or secret/plaintext file on the QNAP bus is a failed
acceptance.  Keep logs, catalog copies and the two cartridges untouched until the cause is understood.
