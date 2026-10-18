# CHANGES — Review 29A (parallel-drive test assertion)

No production code changed.

`test/run_parallel_drives.sh` created a regular data chunk plus a trailing metadata chunk for the
`sub/` directory, so the completed run had two chunks and four VERIFIED segment rows. The old test
incorrectly asserted that the total VERIFIED count was exactly two and therefore failed after a
correctly CLOSED run.

The test now:

- reads `n_chunks` from the cluster catalog;
- requires exactly `2 * n_chunks` VERIFIED segment rows;
- requires exactly one VERIFIED PRIMARY and one VERIFIED BACKUP for every represented chunk;
- requires the number of represented chunk numbers to equal `n_chunks`.

This turns the assertion into an invariant check rather than assuming the test dataset always
produces one chunk.
