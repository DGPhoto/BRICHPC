# Claude review brief — Review 32B4

Base: 32B3. Focus the review on three production-handoff contracts:

1. CLOSED is irreversible across stale abort markers, daemon restart and simultaneous different run_ids.
2. `BRIC_LOCAL_LOCK_DIR` is provisioned independently of all logging paths, is host-local, and retains
   the runtime fail-closed filesystem check.
3. Source-scope semantics are distinct and auditable:
   - default unreadable path => log every path, then fail before reservation;
   - `--force` => omit only precisely identified unreadable paths, log/catalog every omission as
     `force-unreadable`, archive the remaining scope;
   - `--exclude` => operator-declared preflight scope, catalog reason `user-declared`, not a warning.

Please look specifically for any path by which `--force` could silently hide an unclassified traversal
or I/O error, or by which a declared `--exclude` could be conflated with a forced omission.
