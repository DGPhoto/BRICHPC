# Review 31C — immediate tape readback positioning and cross-generation daemon fencing

Review 31C keeps `BRIC-FORMAT-V1` unchanged. It changes only tape-runtime positioning, daemon/update fencing, and process provenance. Restore byte semantics, encryption, project catalogs, chunk format, sparse/PAX behavior, and arbitrary tape reads are unchanged.

## Why

Review 31B1 still verified a just-written tape file through the generic absolute read path:

    rewind -> fsf(file_number - 1) -> read

On the production HPE MSL3040/LTO-9 hardware this made immediate post-write verification traverse a growing physical tape distance even though the drive had just appended the file at EOD.

Real-media measurements on both drives, using the same 2,668,058,144-byte ciphertext file and verifying the exact byte count at the filemark, showed:

    old positioning from EOD     ~= 54.6-55.3 s
    bsfm 2 from EOD              ~= 12.5-12.9 s
    positioning improvement      ~= 4.3x

    old positioning + read       ~= 66.5-67.2 s
    new positioning + read       ~= 24.4-24.8 s
    immediate readback path      ~= 2.7x faster

`nst1` repeated `bsfm 2` in 12.46/12.48 s (~0.16% repeatability); cross-drive agreement with `nst0` at 12.86 s is within ~3%. `mt tell`/`MTIOCPOS` returned I/O error on this hardware, so LOCATE/tell/seek is not used.

The same investigation found a separate upgrade-safety near miss: a Review 30E tape daemon launched from an extracted tree had survived after later systemd-managed releases used a different singleton lock namespace. No BRIC activity from that legacy process was observed (no local event/process log, no QNAP fallback log, no residual CLAIMED marker, and no tape device open before termination), but the singleton invariant had not crossed the lock-namespace migration.

## 1. Immediate post-append readback fast path

New `tape_read_file_immediate()` is used only when the caller has just appended the exact file it is about to verify. It is used for normal chunk copies and immediate close-artifact/TOC verification.

For catalog file number `fn` it performs:

1. `mt eod` and requires `_mt_filenum == fn`.
2. `mt bsfm 2`.
3. Requires `_mt_filenum == fn-1` before any payload read.
4. Reads the file and performs the existing byte/hash verification.

If EOD, `bsfm 2`, or either file-number post-condition fails, Review 31C emits an explicit fallback event and repositions with the old absolute path:

    rewind -> fsf(fn - 1)

The absolute fallback landing is itself checked before reading. A regression deliberately makes mocked `bsfm 2` return success while landing on the wrong file; 31C detects the mismatch, falls back, and reads the correct file.

Generic `tape_read_file()`, restore, reverify, sniff, disaster-recovery scans, and arbitrary file reads remain absolute and do not use relative positioning.

## 2. Cross-generation singleton and work-fence migration

New configurations default to:

    BRIC_TAPE_LOCK=/var/lock/bric_tape.lock
    BRIC_TAPE_WORK_LOCK=/var/lock/bric_tape.lock.work

The systemd unit no longer injects `BRIC_TAPE_LOCK`, so the normal precedence is restored:

    environment > /etc/bric/bric.conf > defaults

The current configuration examples and installation runbook use the `/var/lock` canonical names. In-place
updates deliberately do not rewrite an existing `/etc/bric/bric.conf`; the migration fence set below makes
historical configured names safe during that transition.

The installed config is intentionally not rewritten by an in-place update. Therefore a 31C daemon whose existing config still selects a historical namespace also acquires the new canonical namespace. For BRIC's deployed namespaces the generation fence set is:

    /var/lock/bric_tape.lock
    /tmp/bric_tape.lock
    /run/bric/bric-tape-daemon.lock
    /run/bric/tape.lock

and the corresponding `.work` files.

All singleton namespaces are acquired nonblocking. If any is held, startup refuses before recovery/hardware work. All work-fence namespaces are acquired blocking before `recover()`/reclaim, so a surviving pre-31C worker that inherited only an old work fence can finish before a new generation touches catalog/tape state.

Legacy lock files are opened without truncation. Paths must be absolute; symlinks, non-regular files, unexpected ownership, and pathname/inode substitution during open are rejected fail-closed.

## 3. Update refuses foreign/extracted-tree daemons

After stopping `bric-tape-daemon.service`, `bric-update` now searches for any remaining `bric-tape-daemon --loop` process regardless of its repository path.

If one remains, update aborts before creating the update backup or changing managed files. It prints PID/PPID/start time/command/executable and marks the stopped service unsafe to restart, so the EXIT trap does not accidentally start a second generation beside the foreign daemon.

`bric-setup.sh` uses the same path-independent daemon detection. `bric-tape-import-inventory` acquires/releases the complete singleton/work-fence set and closes every acquired fd before restarting systemd.

## 4. Tape-daemon process provenance

Tape-side `PROCESS_START` now includes:

    script=/.../tape/bin/bric-tape-daemon
    repo=/...
    review=31C
    release_id=2.0-review31C

The values are derived from the daemon script's resolved path and that tree's `RELEASE`, not from the current working directory. A daemon launched from an old extracted release is therefore visible immediately in the structured event stream.

## Tests added/extended

- `run_real_backend_mock.sh`
  - `bsfm 2` immediate fast path;
  - byte-identical readback;
  - successful-but-wrong `bsfm` landing detection;
  - automatic absolute fallback;
  - arbitrary reads still use `rewind+fsf`.
- `run_tape_singleton_migration.sh`
  - legacy singleton refuses a new generation;
  - legacy work fence delays recovery;
  - canonical and every known historical singleton/work namespace are held together;
  - an upgraded host retaining a historical configured path still fences the 31C `/var/lock` canonical namespace;
  - `PROCESS_START` provenance;
  - relative singleton path rejected.
- `run_update_legacy_daemon.sh`
  - extracted-tree daemon causes update refusal;
  - target remains untouched;
  - systemd is deliberately not restarted.

Full release selection: 61 simulation tests (real tape smoke remains explicit and excluded).
