# BRIC operational logging — `BRICLOGv1`

Review 30 makes operational logging a correctness requirement rather than best-effort diagnostics.
Every production entry point records its lifecycle, status transitions and errors without enabling
shell tracing or writing key/passphrase contents.

## Destinations

31E keeps operational evidence centralized without granting users access to one another. Root/system components
(notably the tape daemon and administrative onboarding) use the system root:

```text
/var/log/bric/
```

Every real user activated with `bric-activate-user` receives a central primary:

```text
/var/log/bric/users/<OS-user>/
```

and a private emergency fallback:

```text
$HOME/.bric/log/
```

The central per-user directory is privileged provisioning: normal jobs never create it themselves. New activation
creates it; after upgrading an already activated identity to 31E2, rerun the idempotent `bric-activate-user USER`
once to provision/migrate this filesystem state. Pre-31E1 managed env files remain runtime-compatible: when no
explicit `BRIC_LOG_DIR` is present, the logger derives `/var/log/bric/users/$(id -un)` from the effective OS
identity and retains the existing home path as fallback. A missing/unwritable central directory therefore fails
over safely until the administrator provisions it.

System components retain their configured persistent fallbacks, for example:

```text
Slurm/system: BRIC_LOG_FALLBACK_DIR=/projects/bricsoftware/apps/bric2/log/supekgate
Tape host:    BRIC_LOG_FALLBACK_DIR=/mnt/data/bric/.system/log/brictape
```

The actual values are site configuration, not protocol constants. `/tmp` is never a production fallback. A
destination that becomes unwritable while a process is running is abandoned and subsequent records are written
to its configured fallback. The triggering record plus an explicit `LOG_FAILOVER` breadcrumb are written on the
fallback; records committed before the switch remain in the old root.

`BRIC_REQUIRE_LOGGING=1` is the production default. If neither primary nor fallback is writable, a process refuses
to start with exit status 70. If all destinations are lost during a run, the next structured event fails the
operation rather than allowing an unlogged archive transition.

## Directory layout

```text
/var/log/bric/
  events/YYYY-MM-DD/<host>/...                 # root/system components
  processes/YYYY-MM-DD/<host>/...
  users/
    alice/
      events/YYYY-MM-DD/<host>/...
      processes/YYYY-MM-DD/<host>/...
      jobs/...
    bob/
      ...
  notifications.log

$HOME/.bric/log/                               # per-user fallback only
  events/...
  processes/...
```

Every process gets independent files. Parallel tape workers share the parent daemon event stream but carry their
own Bash PID plus run/chunk/copy/drive context. stdout and stderr remain separate because stdout is an API for
commands such as `bric backup`.

## Permissions and administrator visibility

The recommended 31E2 central layout is:

```text
/var/log/bric/users             0751  root:bric
/var/log/bric/users/alice       owner=alice, owning-group ACL=---, named ACL bric:r-x
                                default ACL repeats bric:r-x and owning-group ---
structured/raw files            0640  (named bric ACL effectively read-only)
$HOME/.bric/log                 0700  user private fallback
```

The collection root is listable by the `bric` administrator group but not by ordinary users; other users have only
the execute permission required to traverse to their own already-known path. Per-user trees explicitly deny their
ordinary NSS owning group (important where that group is a broad group such as `users`) and grant the dedicated
admin group read/traverse through named and default POSIX ACLs. Thus an archive administrator/root can search all
user logs centrally while Alice cannot read Bob's logs.

`bric-setup.sh --role slurm` provisions the collection root when the configured admin group exists.
`bric-activate-user USER` provisions and verifies the per-user ACL tree. Do not solve user logging by adding all
archive users to the administrator group or by making `/var/log/bric/events` world/group writable.

## Stable event schema

Every structured record is one line with exactly 23 pipe-delimited fields:

```text
BRICLOGv1|time|host|role|user|component|pid|ppid|level|event|run|project|chunk|copy|drive|vt|attempt|rc|duration_ms|bytes|slurm_job|slurm_task|message
```

Newlines, tabs, carriage returns and literal pipes in values are normalized to spaces. The version
prefix is mandatory; a future parser must reject an unknown version rather than guessing field order.
Timestamps are UTC ISO-8601. Empty context fields are represented by empty strings, never shifted.

Example:

```text
BRICLOGv1|2026-07-26T09:12:44.312Z|brictape|tape|root|tape-daemon|18420|1|ERROR|TAPE_STREAM_WRITE_FAIL|proj__...|proj|7|BACKUP|1|000011L9|1|1|184523|980000000000|||command=dd ... stderr=Input/output error
```

## What is recorded

Process and scheduler lifecycle:

- `PROCESS_START`, `PROCESS_END` with return code;
- Slurm orchestrator, array, finalize and restore job IDs and output paths;
- `MODULE_LOAD_BEGIN/END`, `MODULE_PURGE_BEGIN/END` and selected OpenSSL version;
- node mount health and Slurm drain attempts.

Logical archive lifecycle:

- run states: `PLANNING`, `RESERVED`, `PRODUCING`, `DRAINING`, `CLOSING`, `CLOSED`, `FAILED`;
- chunk states: `PRODUCING`, `READY`, `CLAIMED`, `DONE`, `ERROR`;
- every signed marker publication/claim;
- reservation, close, abort, restore staging, audit and notification events.

Tape/hardware lifecycle:

- singleton lock, crash-generation work fence and recovery counts;
- pair preparation and each drive's independent readiness wait;
- changer status/load/unload, drive rewind/EOD/FSF, filemark implicito verificato e offline;
- stream write/read/sniff begin/end/failure, bytes and duration;
- verifica del filemark implicito (`TAPE_IMPLICIT_FILEMARK_VERIFIED`) e mismatch fail-closed della posizione (`TAPE_FILE_POSITION_MISMATCH`);
- segment `WRITING`, `WRITTEN`, `VERIFIED`, `ABANDONED` decisions;
- PRIMARY/BACKUP worker results and barrier completion;
- artifact/TOC append and verification;
- media-release barrier and inventory-confirmed empty drives.

For hardware commands, stderr is captured before it is re-emitted. The structured failure therefore
contains the original `mtx`, `mt`, `dd` or SCSI-facing diagnostic, return code and elapsed time; the raw
stderr log preserves the complete untruncated stream.

## Security and exclusions

The logger never enables `set -x`. Key values, derived passphrases, HMAC keys and web capability tokens
must not be logged. Paths, project names, run IDs, VolumeTags and command diagnostics are operational
metadata and are logged deliberately.

The web job is a deliberate exception to raw stdout duplication: its Slurm output contains the temporary
capability URL. The web process still writes structured lifecycle/error events, but `BRIC_LOG_CAPTURE_STDIO`
is disabled for that wrapper to avoid creating a second token-bearing copy.

## Operator checks

Confirm the active destination for a process by reading its `PROCESS_START` message. A fallback run also
emits `LOG_FALLBACK_ACTIVE`; a mid-run switch emits `LOG_FAILOVER`.

Basic integrity checks before the user-friendly reader exists:

```bash
find /var/log/bric/events "$BRIC_LOG_FALLBACK_DIR/events" -type f -name '*.events.v1.log' -print0 \
  | xargs -0 awk -F'|' 'NF != 23 { print FILENAME ":" FNR ": malformed"; bad=1 } END { exit bad }'

grep -R --include='*.events.v1.log' '|ERROR|' /var/log/bric/events "$BRIC_LOG_FALLBACK_DIR/events"
```

The logs are append-only operational evidence, not a substitute for the two SQLite catalogs or signed
bus markers. No automatic retention/deletion policy is installed: storage retention must be chosen
explicitly before production rather than silently discarding evidence.
