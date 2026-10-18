# Review 30N — complete CLI help and bric(1) manual

## User-visible changes

- `bric --help` now lists every normal user command: `backup`, `restore`, `status`, `list`, `jobs`, `log`, `cancel`, and `help`.
- The help now documents previously omitted options including `list --all`, `restore --run`, local background behavior, and `--wait`.
- Added command-specific help through all of these forms:
  - `bric help COMMAND`
  - `bric COMMAND --help`
  - `bric --help COMMAND`
- Unknown options for `status` and `list` are now rejected instead of being silently ignored.
- `log` and `cancel` reject extra positional arguments.
- The root-only legacy `register-user` dispatcher remains available, but it is not presented as a normal user command; normal onboarding remains `bric-setup-user.sh` run by an administrator.

## Manual page

- Added a standard section-1 roff manual at `docs/man/bric.1`.
- `bric-setup.sh --role slurm` installs it as `/usr/local/share/man/man1/bric.1` by default.
- The installation directory can be overridden with `BRIC_MAN_DIR`.
- The manual covers syntax, commands, options, run states, background job states, files, environment, exit status, examples, and operational notes.

## Tests

- Added `test/run_cli_help_man.sh` to validate general help, command help, option coverage, man-page sections, setup wiring, and shell syntax.
