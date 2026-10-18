# Morning runbook — Review 34R2rc2 B3 payload-safe recovery

Purpose: recover Francesco's payload safely from run `PPCG_ONT__20261014T110758Z__0019` while keeping ACL/xattr fidelity explicitly marked `DEGRADED`. This is a recovery candidate, not the final full-fidelity Review 34R2.

## 0. Guard rail

Do not install/update while an archive/tape operation is active. `bric-update` should refuse active work as an additional guard.

### HOST: `supekgate04fl`
### USER: `root`

```bash
bric jobs
sudo bric-update --current
```

Proceed only when there is no active BRIC archive/tape work and change control permits the update.

## 1. Extract and verify the candidate

Copy `bric_archive_2_0_review34r2rc2_b3_payload_safe_recovery_20261015.tar.gz` to the Slurm/login host.

### HOST: `supekgate04fl`
### USER: `root`

```bash
mkdir -p /root/bric34r2rc2
cd /root/bric34r2rc2

tar -xzf /PATH/bric_archive_2_0_review34r2rc2_b3_payload_safe_recovery_20261015.tar.gz
cd bric_archive_2_0_review34r2rc2_b3_payload_safe_recovery_20261015

sha256sum -c MANIFEST.sha256
cat RELEASE
```

Expected release identity:

```text
review=34R2rc2
release_id=2.0-review34R2rc2-b3-payload-safe-recovery
database_migration=files-v34-mode-metadata
on_tape_format=BRIC-FORMAT-V1
build_state=candidate
```

## 2. Update only the Slurm side

`tape/**` is byte-identical to Review 34R1, so this recovery candidate does not require a tape-host software update.

### HOST: `supekgate04fl`
### USER: `root`

```bash
cd /root/bric34r2rc2/bric_archive_2_0_review34r2rc2_b3_payload_safe_recovery_20261015
sudo ./bric-update --role slurm --target /opt/bric2

bric version
/opt/bric2/cluster/libexec/bric-file-metadata --version
```

Expected helper version:

```text
BRIC file-metadata 34R2rc2
```

## 3. Run the capability probe before the recovery

This probe does not modify the damaged restore tree. `PROBE_PARENT` must be on the same destination filesystem where the recovery would be written. `FAILED_ACL_DIR` is optional but should point at one of the directories named in the failed restore log if that tree still exists.

### HOST: `supekgate04fl`
### USER: `lgq442`

```bash
PROBE_PARENT='/PATH/ON/TARGET/FILESYSTEM'
FAILED_ACL_DIR='/PATH/TO/FAILED/RESTORE/20250527_1058_1B_PBA32338_5f7ea677/basecalling/pass'

mkdir -p "$PROBE_PARENT"

/opt/bric2/cluster/scripts/bric-restore-capability-probe.sh \
    --dest "$PROBE_PARENT" \
    --source-dir "$FAILED_ACL_DIR" \
    | tee "$HOME/bric-34r2rc2-capability-probe.txt"
```

The key observations are:

- `CREATE -> CLOSE -> REOPEN O_WRONLY`;
- POSIX ACL set/read result;
- raw `system.nfs4_acl` GET + same-blob SET result;
- optional real ACL blob copy from `FAILED_ACL_DIR`.

The probe is diagnostic; the explicit degraded recovery below does not depend on NFSv4 ACL write support.

## 4. Preserve the failed restore as evidence

Do not reuse or delete the failed destination before the successful recovery has been verified. Move/rename it only if required operationally.

## 5. Create a NEW, EMPTY recovery destination

`--allow-metadata-degradation` refuses a non-empty destination by design.

### HOST: `supekgate04fl`
### USER: `lgq442`

```bash
NEW_EMPTY_DEST='/PATH/TO/NEW/EMPTY/RECOVERY'
mkdir -p "$NEW_EMPTY_DEST"

find "$NEW_EMPTY_DEST" -mindepth 1 -maxdepth 1 -print -quit
```

The final command must print nothing.

## 6. Recover Francesco's run with payload safety enabled

This path extracts TAR_PART payload with GNU tar `--no-xattrs --no-acls`, keeps tar errors fatal, verifies the destination, and persists a `DEGRADED` metadata-fidelity verdict rather than pretending ACL/xattr fidelity was exact.

### HOST: `supekgate04fl`
### USER: `lgq442`

```bash
NEW_EMPTY_DEST='/PATH/TO/NEW/EMPTY/RECOVERY'

bric restore \
    --project PPCG_ONT \
    --run PPCG_ONT__20261014T110758Z__0019 \
    --dest "$NEW_EMPTY_DEST" \
    --allow-metadata-degradation \
    --require-destination-verify
```

Expected high-level outcome on success:

```text
RESTORE_DONE
result=DEGRADED
metadata_fidelity=DEGRADED
```

Unlike rc1, rc2 has been regression-tested as an unprivileged user with a final `0444` LARGE_FILE_CHUNK carrying `user.*`: unsupported/denied ACL metadata produces the degraded verdict rather than converting a verified payload recovery into `RESTORE_FAILED`.

`DEGRADED` refers to ACL/xattr fidelity. It is not permission to ignore payload verification. A tar/decryption/HMAC/destination-verification failure remains fatal.

## 7. Sanity-check the recovered data

Use representative files that were zero-byte in the failed restore and compare counts/sizes against the BRIC catalog/output.

### HOST: `supekgate04fl`
### USER: `lgq442`

```bash
NEW_EMPTY_DEST='/PATH/TO/NEW/EMPTY/RECOVERY'

find "$NEW_EMPTY_DEST" -type f -size 0 | head -50
find "$NEW_EMPTY_DEST" -type f -printf '%s\t%p\n' | sort -n | head -50
bric log
```

Zero-byte files can legitimately exist in a project; the authoritative success condition is the BRIC destination-verification result, not this quick inspection alone.

## 8. Do not promote this candidate

Keep `build_state=candidate`. The field capability probe determines B3c and the final full-fidelity 34R2 still needs a separate TAR_PART metadata pass. Do not describe a `DEGRADED` restore as exact ACL/xattr recovery.
