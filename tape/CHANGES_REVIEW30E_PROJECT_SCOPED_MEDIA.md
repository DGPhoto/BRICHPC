# CHANGES — Review 30E (project-scoped physical media and capacity reservation)

## Requirement

A backup must not require the entire physical library to consist of complete onsite pairs. It needs
only the complete pairs required by the project currently being reserved. For example, with LTO-9
18 TB media and 0.30 TB headroom, a new 20 TB project requires exactly two PRIMARY/BACKUP pairs.
Unrelated, offsite or incomplete pairs do not block that backup.

## Changes

- Generic library preflight no longer fails or warns merely because an unrelated even-parity tape has
  no adjacent partner onsite. It reports complete-pair count and unpaired barcodes informationally.
- Reservation snapshots the real changer inventory and checks physical presence only for:
  1. pairs already assigned to the current project; and
  2. fresh pairs selected to satisfy the current request.
- Fresh pair selection uses actual catalog capacity/headroom pair by pair, rather than a hard-coded
  pair count. Selection stops as soon as requested capacity is covered.
- Only complete, usable, unassigned and physically onsite pairs can be newly reserved.
- A capacity shortfall rolls back only pairs selected by the current request.
- Missing media assigned to the current project is a hard denial, because close/TOC updates require
  those project tapes. Missing unrelated media is ignored.
- Added structured events: `RESERVATION_PAIR_SELECTED`, `RESERVATION_MEDIA_SCOPE_OK`,
  `RESERVATION_PROJECT_MEDIA_MISSING`, `RESERVATION_INVENTORY_FAILED`, and
  `RESERVATION_CAPACITY_SHORTFALL`.

## Validation

`run_library_preflight.sh` now proves that:

- an unrelated incomplete pair does not fail generic preflight;
- the condition is reported as informational;
- a 20 TB project selects exactly two complete onsite pairs;
- unrelated incomplete/offsite media remains untouched.

The Review 30C real-tape smoke result is retained as hardware evidence: baseline 6, appended files
7/8/9, EOD 9, and byte-identical read-back of all payloads.

## Real hardware evidence inherited unchanged from Review 30C

On HPE MSL3040 / Ultrium 9-SCSI S2SD, scratch cartridge `000044L9` passed:

- baseline EOD 6;
- append positions 7, 8, 9;
- final EOD 9;
- exact read-back of 8 MiB, 3,149,825-byte and 1,000-byte payloads.

Review 30E does not change tape I/O or filemark handling.
