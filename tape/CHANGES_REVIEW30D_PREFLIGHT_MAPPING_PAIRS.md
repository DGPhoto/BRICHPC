# CHANGES — Review 30D: preflight device mapping and offsite-aware pair checks

## Trigger

The first 30C hardware preflight on the MSL3040 printed a false device failure:

    FAIL: drive (drive): NOT ready (sg_turs ... error opening file: drive)

It also showed only one configured changer element (`BRIC_TAPE_DRIVES=0`) despite a two-drive
library, and reported two physically incomplete barcode pairs while the tape catalog cross-check was
unavailable.

## Fix 1 — no word splitting in Test Unit Ready

The preflight built labelled `label|device` records through an unquoted command substitution.  A label
such as `drive 0` was split into the two loop items `drive` and `0|/dev/nst0`, causing `sg_turs drive`.

The preflight now parses `BRIC_TAPE_DRIVES` once into a Bash array and calls `check_tur LABEL DEVICE`
directly.  It checks exactly the changer and every configured drive node; no synthetic path named
`drive` can be produced.

## Fix 2 — dual-drive configuration and mapping coherence

The preflight now:

- fails when `BRIC_PARALLEL_DRIVES>=2` but fewer than two changer elements are configured;
- rejects duplicate mappings where two changer elements point to the same `/dev/nstN` node;
- cross-checks changer inventory against Linux `mt status`:
  - a `Full` changer element must map to an `ONLINE` tape node;
  - an `Empty` changer element must not map to an `ONLINE` tape node.

This catches swapped `BRIC_DRIVE0`/`BRIC_DRIVE1` assignments before BRIC attempts a load or write.

## Fix 3 — physical pairing is catalog/offsite aware

The architecture explicitly permits the odd BACKUP cartridge to be offsite once a pair is FULL.
Therefore an even barcode physically present without its odd partner is not unconditionally a
library failure.

New behaviour:

- `BRIC_PREFLIGHT_STRICT_PHYSICAL_PAIRS=1`: every physical even tape must have its odd partner;
  intended for initial inventory reconciliation;
- with a readable tape catalog: a missing partner is a FAILURE only for an `EMPTY`, `PARTIAL` or
  `RESERVED` pair; FULL/non-active/unknown pairs are WARNed for operator verification;
- without a readable tape catalog: the missing partner is a WARNING, because preflight cannot
  distinguish an offsite FULL backup from an incomplete scratch pair.

The daemon reservation logic remains fail-closed: only catalog pairs containing two eligible rows
can be reserved.

## Tests

`run_library_preflight.sh` now verifies:

- both drive labels and device paths are passed correctly to `sg_turs`;
- no phantom target named `drive` is probed;
- strict incomplete-pair mode fails;
- non-strict/no-catalog mode warns without falsely blocking legitimate offsite media;
- a swapped changer-element/Linux-node mapping fails with an explicit diagnosis.

The pre-SQLite scenarios pass in the build container.  The complete test remains part of the native
39-test suite on brictape and supekgate.
