# Independent review brief — BRIC Archive 2.0 Review 32B3

Review only the delta from 32B2. Two real-hardware correctness failures are addressed:

1. **CLOSED -> ABORTED regression**: after all chunks/artifacts/TOCs verified and the daemon committed
   CLOSED, a stale valid cluster `run.ABORTED` was processed one pass later, orphaning all segments.
   32B3 treats the daemon-local CLOSED audit commit as irreversible and ignores late ABORT markers.
   Check that forged bus `run.CLOSED` markers still cannot suppress an authentic abort on an open run.

2. **NFS allocator flock**: parallel allocation used `$BRIC_RUNSTATE/.../chunk-allocate.lock`; the user
   runstate is on NFSv3 and real execution returned ENOLCK. 32B3 separates the mutex into an explicit
   host-local `BRIC_LOCAL_LOCK_DIR`, validates ownership/filesystem type, while leaving member lists in
   shared BRIC_RUNSTATE.

Please focus on terminal-state race safety, marker-authenticity invariants, cleanup semantics after a
late abort, local-lock security/path handling, and whether any Slurm/multi-node assumption is broken.
No on-tape format or DB schema change is intended.
