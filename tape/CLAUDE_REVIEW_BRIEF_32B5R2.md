# Independent review brief — BRIC Archive 2.0 Review 32B5R2

## Inputs

Candidate: Review 32B5R2.  
Direct baseline: supplied Review 32B4A tarball.  
Expected 32B4A SHA-256:
`095878febc2f71f7f695aaf8976220470a0a445b63532685e6cc5378a4606ca4`.

32B5R1 had an effective native 78/78 result; R2 addresses only the remaining findings
from that gate plus the missing B2 evidence.

## Required checks

1. Verify the supplied 32B4A tarball hash and independently compare the five protected
   producer files plus all `tape/**` bytes against 32B5R2.
2. Confirm `BRIC-FORMAT-V1` and `database_migration=config-v32b5-logical-namespace`
   are unchanged.
3. Run the complete native suite; default timeout is now 600 seconds.
4. Confirm comma logical roots are rejected and `=` remains accepted.
5. On the login-node backup path, confirm `--export` is names-only, contains no `ALL`,
   and the exact allow-listed values reach `sbatch` through its process environment.
6. On the restore path, use a comma-containing destination and a comma-containing
   relative file name and confirm both arrive byte-exact without entering the CSV
   `--export` grammar.
7. Inspect/test `bric-orchestrate.sh`: array and finalize submissions must use the same
   value-via-env + names-only pattern and no blanket `ALL`.
8. Confirm an unrelated exported login-shell value is not named in any BRIC `--export`
   allow-list.
9. Re-run `run_32b5_dr_verify_semantics.sh`; confirm the whole-project and single-file
   DR paths print a verification summary and a stream-only warning whenever the
   stream-only count is non-zero.
10. Confirm no accidental Review `32B5A` attribution remains in the R2-modified code or
    tests. 32B5A stays reserved for journal/restrictive-directory work.

## Scope boundary

Do not treat restrictive-directory repair, restore journal, ACL/xattr rollback,
cross-chunk directory repair, directory/symlink DR type verification, or
`--require-destination-verify` as implemented by this candidate.
