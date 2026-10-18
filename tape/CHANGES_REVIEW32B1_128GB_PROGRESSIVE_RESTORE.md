# BRIC Archive 2.0 — Review 32B1: 128 GB chunks and progressive restore

Date: 2026-09-10
Base: Review 32A7 (68/68 native suite PASS)
On-tape format: BRIC-FORMAT-V1 unchanged
State: candidate / native review required

## Why this candidate exists

A real user restore on the installed Review 31E7 system exposed a serious operational problem that the simulation suite did not model at production chunk sizes.

For `PPCG_ONT__20260908T115257Z__0015`, a one-file restore needed chunk 1. The tape server read:

- 974,196,637,728 bytes (~974 GB decimal / 907 GiB)
- from `000005L9#1`
- in 8,344.87 seconds
- at ~117 MB/s.

The cluster restore timeout was 3,600 seconds, so the user-visible restore failed after one hour even though the tape server was healthy and still reading. After the tape read completed, Review 31E7 then re-read the full ~974 GB staged file from QNAP to compute `sha256sum`; only after that second pass did it publish the per-chunk READY marker. `request.STAGED` was finally published about 4h42 after the request.

Because client timeout did not cancel the tape request, the tape daemon continued after the job had reported `RESTORE_FAILED`. The user then started another restore, producing duplicate/orphan tape work and another very large `.part` on the QNAP.

This candidate addresses the root causes rather than only increasing the one-hour timeout.

## 1. Default chunk target: 128 GB decimal

Fresh defaults are now:

    segment_target_bytes=128000000000
    stream_worker_chunk_bytes=128000000000
    tape chunk_target_bytes=128000000000

The hard-cap rule from Review 32A4 is unchanged: a site/test lowering `segment_target_bytes` still clamps the worker target.

128 GB is deliberately decimal, consistent with LTO capacity accounting.

At the observed ~117 MB/s tape-read rate, one full 128 GB chunk is roughly an 18–20 minute tape stream rather than ~2h19 for the ~974 GB chunk observed in production.

This also improves pair packing tail loss. A chunk never spans tape pairs, so the maximum quantization loss per full pair is now ~128 GB instead of the previous 245 GB worker quantum. Across five pairs the worst-case quantization tail falls from >1 TB to ~640 GB, before normal headroom accounting.

## 2. Progressive reverse-bus protocol

New cluster requests advertise:

    protocol=restore-progressive-v1

The tape daemon remains compatible with legacy requests that do not contain this field.

For progressive callers the protocol is now:

    request
      -> request.PROGRESS (signed heartbeat)
      -> staged_<chunk>.READY
      -> staged_<chunk>.CONSUMED
      -> next chunk
      ...
      -> request.PROGRESS state=RELEASING
      -> request.PROGRESS state=DONE
      -> request.STAGED

The daemon waits for the signed `CONSUMED` acknowledgement before staging the next chunk. This bounds reverse-bus ciphertext staging to approximately one chunk per restore request instead of materializing the complete restore on QNAP.

The cluster publishes `CONSUMED` only after it has:

1. verified the tape server's signed READY receipt;
2. verified the ciphertext HMAC using the cluster/user key material;
3. decrypted and extracted/appended the chunk successfully.

The ciphertext blob is then removed immediately.

## 3. Inline ciphertext SHA-256

Review 31E7 restore used:

    tape_read_file -> staged.enc.part
    sha256sum staged.enc.part

which caused a second full QNAP read after every tape read.

Review 32B1 uses a single stream:

    tape_stream_file | tee staged.enc.part | sha256sum

with `pipefail`. The tape stream, QNAP write, and ciphertext SHA-256 therefore happen in one pass. The blob is published as READY only when the pipeline succeeds and the resulting SHA matches the `segments.payload_sha256` catalog value.

PRIMARY -> BACKUP fallback and SUSPECT/read_errors policy remain unchanged.

## 4. Signed progress and timeout semantics

`request.PROGRESS` contains at least:

    state
    run
    chunk
    chunk_index
    chunks_total
    bytes_current
    bytes_current_total
    bytes_done
    bytes_total
    volumetag
    file
    updated_epoch

The tape daemon refreshes it while positioning/reading and while waiting for the consumer acknowledgement.

The cluster logs each newly verified progress marker, so `bric log <job>` shows real chunk/byte progress instead of a static `requested N chunk(s); waiting...` line.

Timeout semantics are no longer one total one-hour deadline:

- `BRIC_RESTORE_QUEUE_TIMEOUT` default 86400 s: allowance before the daemon starts this request;
- `BRIC_RESTORE_INACTIVITY_TIMEOUT` default 1800 s: once progress exists, failure means no new signed progress for 30 minutes;
- repeated progress is accepted for liveness only after signature verification **and** a monotonically increasing `updated_epoch`; a transient torn body/signature pair during marker refresh is ignored/retried rather than treated as authoritative;
- legacy `BRIC_RESTORE_TIMEOUT`, when explicitly configured by an old site/test, remains a compatibility override for both waits.

## 5. Cancellation / orphan-work containment

On a normal cluster-side restore failure or timeout, the EXIT trap publishes a signed `request.CANCELLED` unless the request is already terminal.

The tape daemon never kills a physical tape stream mid-file merely because the client cancelled. It finishes the current tape-file read, then:

- discards staged ciphertext;
- does not proceed to another chunk;
- releases media;
- publishes a terminal cancellation receipt.

With new 128 GB archives this bounds normal timeout/cancellation waste to at most the current ~128 GB chunk rather than allowing an entire multi-terabyte request to continue after the client is gone.

Hard process/node death without an opportunity to publish CANCELLED remains a separate crash-recovery case; the progressive one-chunk backpressure still limits accumulation once the daemon reaches READY and waits for CONSUMED.

## 6. Mixed-version behavior

The protocol field makes rollout deliberately tolerant:

- new cluster + old tape daemon: old daemon ignores `protocol=...`; the new cluster can consume READY chunks progressively, although the old daemon may still stage ahead until the tape side is upgraded;
- old cluster + new tape daemon: no progressive protocol field, so the new daemon preserves legacy stage-all behavior and does not wait for CONSUMED;
- new + new: full one-chunk READY/CONSUMED backpressure and signed progress.

No BRIC-FORMAT-V1 data or tape layout change is required.

## 7. Applying 128 GB policy to existing catalogs

`bric-update` remains static-file-only by design and does not mutate live catalogs.

For an existing cluster catalog, after all archive/restore work is terminal:

    cluster/scripts/bric-performance-apply.sh

now defaults to setting both:

    segment_target_bytes=128000000000
    stream_worker_chunk_bytes=128000000000

For an existing tape catalog:

    tape/scripts/bric-chunk-policy-apply.sh

sets:

    chunk_target_bytes=128000000000

Both policy scripts refuse changes while they can see active work.

## 8. New regression coverage

`test/run_restore_progressive.sh` verifies:

- whole-run restore remains exact;
- request advertises progressive-v1;
- every needed chunk receives CONSUMED;
- no staged ciphertext remains after consumption;
- terminal progress reaches DONE;
- daemon logs inline SHA verification;
- the legacy second-pass `sha256sum staged_*.enc.part` path is absent.

`test/run_multi_pair_transition.sh` forces, in the simulation backend:

- a deliberately tiny first pair;
- `run.RESERVE_EXTEND_REQUEST` / `run.RESERVE_EXTENDED`;
- VERIFIED data chunks on two distinct tape pairs;
- an actual first-pair -> second-pair placement transition;
- `catalog_project.enc` VERIFIED on all four cartridges;
- final TOC VERIFIED on all four cartridges;
- exact whole-project restore across both pairs.

This test does not replace the required physical multi-pair transition smoke.

## 9. Still not implemented here

- CLOSED child-run slices / logical-operation resume;
- automatic decision on the real `000001L9` / `000002L9` health state;
- physical multi-pair transition certification;
- final 1/2/4-worker site benchmark;
- signer isolation work.

Those remain explicit gates/phases after this candidate is natively green.
