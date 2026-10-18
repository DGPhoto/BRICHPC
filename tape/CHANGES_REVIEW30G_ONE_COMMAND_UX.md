# Review 30G — one-command user UX

Normal users no longer initialize BRIC manually.

- `bric-setup.sh --role slurm` installs `/usr/local/bin/bric` as a symlink to the operational wrapper.
- The wrapper automatically reads `~/.bric/env.sh`; the Slurm scripts continue to load the pinned OpenSSL module internally.
- Friendly positional commands are supported:
  - `bric backup PROJECT SOURCE`
  - `bric restore PROJECT DEST`
- Existing explicit forms remain compatible.
- `status` and `list` are available through the same command.
- `bric-setup-user.sh` no longer tells users to source a file or load a module.
- No login shell file is modified.
