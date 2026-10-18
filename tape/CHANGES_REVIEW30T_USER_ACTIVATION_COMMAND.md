# Review 30T — one-command real-user activation

Adds one root-only administrative command on the Slurm host:

```bash
bric-activate-user ztm319
```

The command deliberately delegates key generation/recovery and escrow mutation to the canonical
`cluster/scripts/bric-setup-user.sh`; it does not implement a second onboarding path. It adds:

- a clean environment so inherited production `BRIC_*` variables cannot override the selected config;
- strict runtime checks by default;
- NSS/AD identity and home validation;
- post-provision validation of ownership and 0700/0600 modes;
- 32-byte personal-key validation without printing the secret;
- authenticated v2 escrow unwrap-and-compare verification;
- catalog directory, default WAL/SHM and database ACL checks;
- an actual `bric status` invocation as the target user;
- an idempotent regression test under a deliberately contaminated environment.

`bric-setup.sh --role slurm` installs the command as `/usr/local/sbin/bric-activate-user` by default.
The link can be changed with `BRIC_ACTIVATE_USER_LINK`.
