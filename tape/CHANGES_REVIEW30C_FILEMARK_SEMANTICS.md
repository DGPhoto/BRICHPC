# CHANGES — Review 30C: Linux tape filemark semantics and contiguous physical numbering

## Trigger

The first real-hardware smoke test on cartridge `000044L9` wrote and read all three payloads
bit-identically, including the odd-sized payload, but returned physical file numbers `1,3,5` and
`EOD=6` instead of `1,2,3` and `EOD=3`.

A direct read-only positioning check (`rewind`, `fsf 1`, `status`) showed that one filemark advances
the drive to file number 1. The data path was sound; the mismatch came from how BRIC terminated each
write.

## Root cause

The real backend did both operations below for every append:

1. `dd ... of=/dev/nstN` — when `dd` closes the non-rewinding Linux SCSI tape device after a write,
   the `st` driver writes one flushing filemark;
2. `mt -f /dev/nstN weof` — writes another filemark.

The second operation therefore created an empty tape file between every two BRIC objects. This made
physical numbering advance `1,3,5,...`. Payloads remained readable because BRIC catalogued the actual
odd file numbers, but the real backend no longer matched the sequential model used by simulation,
VTL, rebuild and the acceptance smoke test.

## Production fix

`tape_append_file()` no longer executes an explicit `mt weof` after `dd`.

After `dd` exits, BRIC now:

1. waits for the individual drive to become ready;
2. reads the current physical file number;
3. requires it to equal `EOD_before + 1`;
4. logs `TAPE_IMPLICIT_FILEMARK_VERIFIED` on success;
5. logs `TAPE_FILE_POSITION_MISMATCH` and fails closed on any empty, invalid or unexpected value.

`tape_last_file_number()` also fails closed if the real drive does not return a valid non-negative
file number. It no longer silently substitutes zero.

## Linux `st` driver mode guards

BRIC reads `/sys/class/scsi_tape/<device>/options` for real character devices and refuses two modes
that invalidate the physical-numbering invariant:

- `MT_ST_TWO_FM` (`0x10`): close writes two filemarks;
- `MT_ST_FAST_MTEOM` (`0x20`): the kernel documents the file number after direct EOD positioning as
  invalid.

The check runs in the hardware quickcheck, at real append/EOD operations, and is reported explicitly
by `bric-library-preflight`. If sysfs is unavailable, the preflight warns and the destructive scratch
smoke remains the authoritative acceptance test.

## Mock/VTL correction

The previous real-backend mocks counted stored payload files and treated `weof` as a no-op, so they
could not reproduce the real Linux behavior.

The updated mocks now maintain a separate physical EOD position:

- closing a mocked `dd` write creates one filemark and advances EOD by one;
- a mocked explicit `weof` creates an additional empty tape position;
- reads use the physical position rather than the count of payload files.

This makes the mock fail under the Review 30B write sequence and pass under Review 30C.

## New regression test

`test/run_filemark_semantics.sh` verifies:

- two writes are catalogued as physical files `1,2`;
- EOD is `2`;
- no explicit `mt weof` is invoked;
- both files round-trip bit-identically;
- a simulated `+2` position advance fails closed;
- `MT_ST_TWO_FM` and `MT_ST_FAST_MTEOM` are rejected.

The standard software suite now contains **39** tests. The real tape smoke remains excluded and must
be run explicitly.

## Smoke-test improvements

`run_real_tape_smoke.sh` now:

- checks all three sequential file numbers, not only the first and final EOD;
- uses the accurate confirmation option `--yes-write VOLUMETAG`;
- keeps `--yes-overwrite` as a deprecated compatibility alias;
- states clearly that the test appends at EOD and does not erase the cartridge;
- exits explicitly with status 0 after a successful simulation run.

On the already-used scratch `000044L9`, whose old baseline is `6`, the expected Review 30C result is:

- new payloads at files `7,8,9`;
- final EOD `9`;
- all three SHA-256 read-backs identical.

## Documentation

README, architecture, logging documentation, installation runbook, scratch-tape runbook and recovery
handbook now describe the Linux implicit close filemark and explicitly prohibit a second `mt weof`.
