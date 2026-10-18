# Review 30H — automatic per-user logging fallback

Normal users must be able to run `bric backup`, `bric restore`, `bric status`, and `bric list`
without shell initialization, module commands, local Unix-group membership, or writable shared
software directories.

`bric-setup-user.sh` now creates `~/.bric/log` with mode 0700 and writes two non-secret settings to
`~/.bric/env.sh`:

- `BRIC_LOG_FALLBACK_DIR=~/.bric/log`
- `BRIC_LOG_GROUP=<the user's primary OS group>`

The wrapper already loads `~/.bric/env.sh` automatically before initializing logging, so an
unwritable `/var/log/bric` transparently falls back to the private home directory. Rerunning
onboarding is idempotent and updates existing users without rotating their key or escrow.
