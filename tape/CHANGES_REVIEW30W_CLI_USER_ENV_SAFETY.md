# Review 30W — CLI validation and user-environment safety

## Fixed: `bric restore help` created a failed background job

The operational wrapper treated the bare word `help` as a restore project operand, ran
the preflight, detached a `restore.unknown` job, and only then allowed the inner CLI to
reject the command. The wrapper now recognizes all three equivalent forms before any
runtime setup:

- `bric help restore`
- `bric restore --help`
- `bric restore help`

The same applies to backup and non-operational commands. Complete backup/restore
arguments are now validated before OpenSSL selection, preflight, or background
detachment. Missing operands and unknown options fail synchronously and create no job.

## Hardened: user activation does not disturb login settings

Onboarding still writes only under `~/.bric` and catalog ACLs; it never edits `.bashrc`,
`.bash_profile`, `.profile`, module files, `PATH`, or other login settings. In addition:

- generated `~/.bric/env.sh` begins with `# BRIC-MANAGED-FILE`;
- an existing unmarked file or symlink at that path is refused without overwrite;
- changed managed files are backed up as `env.sh.bak.TIMESTAMP`;
- unchanged managed content is left untouched;
- legacy BRIC-generated env files remain accepted and are upgraded with backup;
- `bric-activate-user` verifies the managed marker after onboarding.

No database migration or on-tape format change is involved.
