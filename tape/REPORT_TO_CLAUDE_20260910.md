# BRIC Archive 2.0 — report to Claude after Review 32A and the first real-user restore

Claude,

This report consolidates everything that happened after your Review-32A multi-pair review, including the native failures/fixes, final suite result, and a production restore incident that materially changes the chunk/restore priorities.

## Executive state

Review 32A ultimately reached:

    Review 32A7
    native suite: 68/68 PASS
    run_local_e2e: PASS
    run_dr_e2e: PASS
    unprivileged DR: PASS
    single-file DR TAR_PART: PASS
    single-file DR LARGE_FILE_CHUNK: PASS
    REAL-backend mock archive/close/DR: PASS

The on-tape format remained `BRIC-FORMAT-V1` throughout.

After that, a real user (`lgq442`, Francesco Favero) exercised restore against the currently installed production build, which is **Review 31E7**, not 31C. That real restore exposed a serious latency/progress/cancellation issue with the old ~1 TB chunks. Based on the measured behavior, the user has now explicitly selected **128 GB decimal chunks** as the new default and asked for progressive per-chunk restore.

A new candidate, Review 32B1, implements that policy plus a software multi-pair transition regression test. Details below.

---

## A. What happened from 32A3 through 32A7

### 32A3 — metadata worker dynamic-scope bug

Your native `status.metadata: No such file or directory` failure was reproduced and traced to Bash dynamic scope in `run_worker()`.

A compound declaration used:

    local id="$1" ... ws=".../$id" ... status=".../status.$id"

The RHS expressions were expanded before the new local `id` existed, so the caller's/global `id=data-03` leaked into the metadata worker. Splitting the declaration fixed it. This was not an EXIT-trap cleanup bug.

Result: targeted parallel gate passed.

### 32A4 — `huge.bam` was not actually using LARGE_FILE_CHUNK

Your native `raw/huge.bam mismatch` was not `chunk_index` corruption.

The test set:

    segment_target_bytes=5242880

but Review 32A had:

    stream_worker_chunk_bytes=245000000000

which silently overrode the test/site segment target. The 12 MiB file therefore entered TAR_PART rather than LARGE_FILE_CHUNK, and the manual LARGE reconstruction selected no rows.

Fix:

    effective_worker_target = min(configured_worker_target, segment_target_bytes)

After the fix, native logs showed three LARGE_FILE_CHUNK allocations at 5 MiB and exact reconstruction by `chunk_index` while other workers allocated global chunk numbers concurrently.

Targeted gates:

    run_parallel_target_policy PASS
    run_single_run_parallel PASS
    raw/huge.bam split restore PASS

### 32A5 — stale close-catalog test assertion

`run_local_e2e` then failed:

    FAIL: project catalog built expected=1 got=0

The test searched for:

    */close/catalog_project.enc

on QNAP after CLOSED.

That assertion was obsolete. Production close semantics intentionally remove the complete terminal run directory from QNAP after the signed CLOSED receipt. The durable close catalog is recorded in `tape_artifacts`, not `segments`.

The test was corrected to assert:

- `catalog_project.enc` VERIFIED on every project tape;
- final TOC VERIFIED on every project tape;
- terminal QNAP run directory removed.

No production close code changed.

### 32A6 — packaging regression: non-static Go helper

The first 32A5 native E2E on RHEL8 failed immediately because the packaged `bric-tar-stream` required:

    GLIBC_2.32
    GLIBC_2.34

Review 30Q had already established the requirement for a static RHEL8-compatible helper. The binary had accidentally been rebuilt dynamically during packaging.

32A6 rebuilt the same Go source with:

    CGO_ENABLED=0 GOOS=linux GOARCH=amd64

and fixed the helper portability test, which still contained a stale Review-31 version assertion.

Native results:

    run_local_e2e PASS
    DISASTER RECOVERY PASS: full project from tapes + user key only
    unprivileged DR PASS
    single-file DR PASS for TAR_PART and LARGE_FILE_CHUNK

### First full 32A6 suite: 67/68

The only red test was `run_real_e2e.sh`.

It successfully wrote/read-verified all seven chunks to PRIMARY and BACKUP, then the run aborted immediately after chunk 7. The test hid cluster-side stderr, so a diagnostic copy was run without that redirection.

The diagnostic REAL-backend E2E then passed archive -> close -> DR completely.

The original REAL-backend test was subsequently run three consecutive times and passed 3/3.

Root cause of the original flake: the test itself used:

    BRIC_DRAIN_TIMEOUT=120

The single-drive REAL mock serializes load/write/readback/unload for PRIMARY and BACKUP. Seven chunks naturally put the drain on the ~120-second boundary, so the test raced its own timeout.

### 32A7

Test-only fix:

    BRIC_DRAIN_TIMEOUT 120 -> 300

No production code changed from 32A6.

Final native result:

    == 68 OK, 0 FAIL in 1978s ==
    SUITE PASSED

This closed Review-32A correctness.

---

## B. Your multi-pair review: current disposition of all four findings

### 1. Per-chunk implicit pair transition

Agreed. The architecture remains correct: a complete chunk is placed on one pair, and pair selection occurs for each chunk. There is no explicit stateful "switch pair" operation to corrupt.

The remaining risk is failure to find a reserved pair with enough room, not splitting one chunk across pairs.

Review 32B1 adds a hermetic test that forces a real software transition across two simulated pairs and then closes/restores the project. A physical LTO smoke is still required.

### 2. Tail quantization loss

Your point becomes stronger after the real restore incident.

Previously the per-worker chunk quantum was 245 GB. With the user's new decision:

    chunk target = 128000000000 bytes

maximum tail quantization waste falls to ~128 GB per full pair. Across five pairs this is ~640 GB worst-case before headroom, versus >1 TB at 245 GB.

The primary reason for 128 GB is now restore latency/read amplification; lower tail waste is an additional benefit.

### 3. `health IN ('OK','SUSPECT')` and 000001L9/000002L9

Still unresolved and must be explicit before the 70 TB campaign.

The earlier ENOSPC incident was host/QNAP-side rather than evidence of bad tape media, so leaving those cartridges indefinitely as SUSPECT is semantically misleading. The operational choices remain:

1. requalify/reset them and return them to OK;
2. retire them;
3. do not leave them ambiguously selectable as SUSPECT for the campaign.

Review 32B1 deliberately does not silently rewrite this production inventory decision.

### 4. All project pairs must remain onsite for extension

Unchanged. `handle_reservation_extend` still requires all existing project pairs to be fully onsite. For the planned campaign this means previously used cartridges must not be removed from the 80-slot library while extension may still be required.

This must be documented in the campaign runbook.

---

## C. Real production restore incident on Review 31E7

### C1. First apparent failure: user path error, not software

Francesco first requested:

    PCA159_T01/20250527_.../pod5/<file>.pod5

but the backup source root itself was `PCA159_T01`, so catalog paths correctly start at:

    20250527_.../pod5/<file>.pod5

`bric contents PPCG_ONT` made that clear. This part is closed.

### C2. Correct one-file restore then "timed out"

Correct request:

    project PPCG_ONT
    run PPCG_ONT__20260908T115257Z__0015
    requested chunks: 1

Cluster-side timestamps:

    18:50:36 request published
    19:50:43 ERROR: timed out waiting for tape staging
    RESTORE_FAILED

The initial interpretation was that the tape daemon never started. That was wrong.

Tape-server evidence showed:

    18:50:44 hardware quickcheck passed
    18:51:15 tape operation starts on 000005L9
    21:10:29 tape read completes

Exact tape-read measurement:

    3,716,265+1 records
    974,196,637,728 bytes
    8,344.87 seconds
    117 MB/s

So the cluster's fixed 3,600-second timeout expired while a completely healthy ~974 GB tape read was still in progress.

### C3. The second full-QNAP pass doubled the latency

At 21:10:30 the complete staged ciphertext file existed on QNAP.

But Review 31E7 then executed a separate:

    sha256sum staged_<chunk>.enc.part

before READY publication.

The READY marker did not appear until:

    23:27:26 staged chunk READY

and final media release / request terminal receipt occurred at:

    23:32:33 request.STAGED

Thus a single chunk took roughly:

    ~2h19 tape -> QNAP
    ~2h17 QNAP -> SHA256
    + robotics/unload
    -------------------
    ~4h42 to terminal staging

The second read is unnecessary: ciphertext SHA can be computed while the tape stream is written to QNAP.

### C4. Timeout created orphan/duplicate work

The client declared the first restore FAILED at 19:50, but no cancellation was sent to the tape server. The daemon continued until 23:32.

Thinking the first restore had failed, Francesco started another whole-project restore at 19:54:

    requested 3 chunk(s)

After the first orphan request finally completed, the daemon started the second request on the same tape. Hours later the second request had a large:

    staged_...c0001.enc.part

still growing.

Therefore the fixed client timeout is not just misleading: it can create duplicate tape reads, orphan QNAP staging and hours of unnecessary robotics/I/O.

The daemon service itself was healthy throughout. It was Review 31E7, active since Sep 8, and was visibly executing `dd if=/dev/nst1 ...` for the restore.

---

## D. User decision after the incident: 128 GB chunks

The user explicitly rejected ~1 TB restore units and selected **128 GB** chunks, with progress handled chunk-by-chunk during restore.

At the measured 117 MB/s:

    128,000,000,000 / 117,000,000 ~= 1,094 s ~= 18.2 min

Allowing positioning/robotics, ~20 minutes is a realistic order of magnitude for one maximum-size chunk read.

This makes a random TAR_PART single-file restore bounded around one ~128 GB tape object instead of nearly 1 TB for newly written archives.

Old archives remain old archives: the new software cannot retroactively subdivide the existing ~974 GB PPCG_ONT chunks. For those old chunks, inline hashing and progress/cancellation still materially improve behavior.

---

## E. Review 32B1 implementation for your review

### E1. Defaults

Fresh cluster:

    segment_target_bytes=128000000000
    stream_worker_chunk_bytes=128000000000

Fresh tape:

    chunk_target_bytes=128000000000

`stream_worker_chunk_target()` hard-cap semantics from 32A4 are unchanged.

The Go helper default was updated and rebuilt statically for RHEL8.

### E2. Existing installations

`bric-update` remains static-file-only and does not mutate catalogs.

Explicit policy scripts are provided:

Cluster:

    cluster/scripts/bric-performance-apply.sh

Tape:

    tape/scripts/bric-chunk-policy-apply.sh

They default to 128 GB and refuse to change policy while active work is visible.

### E3. Inline restore hash

Old:

    tape_read_file -> QNAP
    sha256sum QNAP_file

New:

    set -o pipefail
    tape_stream_file | tee QNAP_part | sha256sum

READY is published only if the pipeline succeeds and the resulting hash equals the authoritative segment hash.

Please review carefully whether the existing `tape_stream_file` lock/positioning/error semantics are preserved correctly through this pipeline and whether any Bash `pipefail`/subshell corner case can turn a component failure into a false success.

### E4. Signed progress heartbeat

The daemon publishes signed `request.PROGRESS` updates with state, chunk index/count, current/total bytes, total request bytes, VolumeTag/file number and epoch.

Cluster-side waiting verifies progress signatures before trusting them and logs progress to the normal restore job log. Because `request.PROGRESS` is a deliberately mutable signed marker, a transient body/signature version mismatch during refresh is ignored and retried; liveness advances only for a valid signature with a strictly increasing `updated_epoch`, which also blocks same-request replay of an older valid heartbeat.

Timeouts become:

    queue timeout       86400 s default
    active inactivity   1800 s default

An explicitly configured legacy `BRIC_RESTORE_TIMEOUT` remains a compatibility override.

Please review whether the distinction is sufficient given that the current daemon processes restore requests serially and a later request may sit behind a very long earlier request without receiving its own progress heartbeat.

### E5. READY -> CONSUMED backpressure

New requests advertise:

    protocol=restore-progressive-v1

For this protocol, the daemon waits for signed `staged_<chunk>.CONSUMED` before staging the next chunk. The cluster publishes CONSUMED only after READY signature verification, ciphertext HMAC verification and successful decrypt/extract/append.

This bounds QNAP reverse-bus staging to roughly one chunk per request.

Legacy requests retain stage-all semantics.

Please review crash/restart behavior around these states, particularly:

- READY exists but ciphertext was already removed after CONSUMED;
- daemon restart while waiting for CONSUMED;
- cluster crash between successful decrypt and CONSUMED publication;
- whether any state should be made more explicitly terminal/idempotent.

### E6. Cancellation

On normal cluster-side failure/timeout, the restore EXIT trap publishes signed `request.CANCELLED`.

The daemon intentionally does not interrupt an in-flight tape file. It finishes the current file, then discards staged data, releases media and stops the request. With 128 GB future chunks this bounds ordinary cancellation waste to one chunk.

Please assess whether a safe mid-stream cancellation is worth implementing later, or whether chunk-boundary cancellation is the better tape-safety policy.

### E7. Mixed-version rollout

The protocol is capability-like rather than assumed:

- new cluster + old tape: old tape ignores protocol/CONSUMED and continues legacy behavior;
- old cluster + new tape: absent protocol keeps new tape in legacy mode;
- new + new: bounded progressive protocol.

Please check for any hidden mixed-version incompatibility, especially around cluster deletion of a READY blob while an old daemon is still processing the same request.

---

## F. New multi-pair software regression

`run_multi_pair_transition.sh` intentionally constrains pair 1 and sets a small initial reservation so the stream must emit:

    run.RESERVE_EXTEND_REQUEST
    run.RESERVE_EXTENDED

It then verifies:

- VERIFIED chunks span two pair_numbers;
- first and last chunk land on different pairs;
- `catalog_project.enc` is VERIFIED on all four cartridges;
- final TOC is VERIFIED on all four cartridges;
- whole restore across both pairs is exact.

This is only the software/simulation gate. Your proposed physical smoke remains mandatory because it exercises actual mtx/mt, library inventory, real media positioning and close replication with more than one physical pair.

---

## G. Required next gates / proposed order

Because the real restore incident revealed a correctness-of-operation problem (false failure + orphan work), the priority order has changed slightly from the earlier performance-first sequence.

1. Native focused gates for Review 32B1:
   - `run_restore_progressive.sh`
   - `run_restore_fallback.sh`
   - `run_local_e2e.sh`
   - `run_dr_e2e.sh`
   - `run_multi_pair_transition.sh`
   - `run_parallel_target_policy.sh`
   - `run_performance_policy.sh`
2. Full native suite (now expected to include the two new tests).
3. Decide 000001L9/000002L9: requalify to OK or RETIRED; do not leave ambiguous SUSPECT state.
4. Physical multi-pair transition smoke using the new candidate and at least two real pairs.
5. Site 1/2/4 worker source benchmark; choose the minimum worker count that stays safely above tape-cycle throughput.
6. Implement CLOSED child-run slices / logical-operation resume before the ~70 TB campaign.
7. Signer isolation/security phase if not already promoted ahead of the campaign.

The 70 TB production campaign should not start until items 1–6 are closed.

---

## H. Specific questions for your review

1. Does `tape_stream_file | tee part | sha256sum` preserve all error attribution and media-health semantics, or should the inline pipeline live in `lib_tape_io.sh` as a first-class primitive instead of the daemon?
2. Is 128 GB a good first production default given the measured 117 MB/s restore rate and your prior filemark/packing observations?
3. Is signed `request.PROGRESS` sufficient for inactivity semantics, or should the daemon publish an immediate QUEUED/ACCEPTED marker before hardware work?
4. Is one-chunk READY/CONSUMED backpressure the right staging bound, or would a two-chunk sliding window better overlap tape and cluster decrypt/extract without materially increasing QNAP risk?
5. Is chunk-boundary cancellation the safest policy, or can/should an in-flight `dd` be interrupted without creating problematic tape/drive state?
6. Are the mixed-version semantics actually safe in both deployment orders?
7. Does the new simulation multi-pair test cover the software risks you identified, and what exact assertions should be added before the physical smoke?
8. With 128 GB chunks, do any reservation/headroom/close queries still contain assumptions tuned to ~980/245 GB that should be changed before native certification?
9. For 000001L9/000002L9, given the ENOSPC diagnosis was host-side, do you agree the proper choices are explicit requalification or retirement rather than leaving them SUSPECT/selectable?
10. Do you see any reason to implement CLOSED slices before the physical multi-pair smoke, or is smoke-first still the safer ordering once 32B1 is green?
