# Claude review brief — BRIC Review 32A2

Please diff this candidate against the previous 32A review tarball and Review 31E7.

## Immediate change after your native-suite report

Your `status.metadata: No such file or directory` finding was correct. Root cause was the shared `EXIT` cleanup trap executing in background worker subshells. The producer now stores the coordinator `BASHPID`; only that process may delete the shared temp directory. A failed coordinator also deletes orphan `ALLOCATED` catalog placeholders before the outer run aborts.

Please rerun the full native suite and specifically confirm that all tests which previously failed with the metadata-status ENOENT no longer show that signature.

## Correction to the QNAP bandwidth inference

The 0011/0015 dual-drive numbers do not imply ~209 MB/s of physical QNAP traffic. Both `dd` readers consume the same ciphertext file, and Linux page cache supplies the second reader from pages fetched for the first.

On real run 0015 we measured:

- both dd processes at ~822 GB logical rchar/wchar;
- physical `read_bytes` split ~330 GB + ~492 GB = ~822 GB total;
- nfsiostat ~113 MiB/s total physical READ from the 1 GbE QNAP link.

Thus ~105 MB/s per tape copy and a ~113 MiB/s physical network ceiling are compatible. Please use one write duration, not the sum of both parallel copy rates, when modelling the write phase.

## Resume architecture correction

I agree with preserving the 31C terminal fence, but there is an additional constraint in the current tape daemon: `handle_abort()` marks *all* segments for an aborted run ABANDONED, even VERIFIED ones. Therefore a continuation cannot safely subtract files from DONE chunks of an ABORTED run; those tape segments are intentionally no longer referenced.

The preferred design is now:

- one user-visible logical operation;
- one persisted deterministic NUL-safe master manifest;
- a sequence of durable slice child runs;
- each slice child reaches CLOSED and is therefore a checkpoint;
- a failed slice remains ABORTED forever and is retried with a new run_id;
- previous CLOSED slices remain valid;
- internal parallel workers inside each child provide source throughput;
- initially keep one active child per project, so the existing one-active-run fence and tape daemon do not need concurrency changes.

Please review this architecture particularly against close/catalog semantics and tape-pair reservation/extension.

## Important review questions

1. Is `BASHPID` coordinator-guarded cleanup sufficient on the supported Bash/RHEL versions and in all worker exit paths?
2. Is deleting only `state='ALLOCATED'` placeholders on coordinator failure correct, given outer `run.ABORTED` owns the remaining terminal cleanup?
3. Are there any other shared temp paths written by background worker subshells that can be deleted or truncated prematurely?
4. For operation slicing, can child runs be closed independently without changing BRIC-FORMAT-V1 or tape DR assumptions?
5. Does `bric-close`/catalog export currently assume that the latest run is a complete snapshot rather than a slice? Identify every query that needs operation-aware union semantics.
6. What slice target (2–4 TB candidate) best balances retry domain against close/catalog overhead?
7. Re-run 1/2/4-worker native benchmark only after the correctness suite is clean.

See `CHANGES_REVIEW32A2_CLEANUP_RESUME_DECISION.md` for the full reasoning.
