# Claude review brief — BRIC Review 32B1

Please read `REPORT_TO_CLAUDE_20260910.md` first. It contains the complete sequence from the Review-32A native fixes through the real Review-31E7 user restore incident and your prior multi-pair findings.

## Candidate scope

Review 32B1 is based on native-green Review 32A7 (68/68 PASS) and intentionally changes two operational policies without changing `BRIC-FORMAT-V1`:

1. default chunk hard bound: `128000000000` bytes;
2. progressive reverse-bus restore with inline tape-read SHA256, signed progress, READY/CONSUMED backpressure and cluster cancellation.

It also adds a hermetic multi-pair transition/extension test. CLOSED logical-operation slices are still not implemented.

## Please inspect these files first

- `tape/bin/bric-tape-daemon` — `handle_restore()` and `_restore_*` helpers;
- `cluster/scripts/bric-restore.sh` — progressive wait/consume/cancel path;
- `cluster/scripts/lib_common.sh` — restore-bus debug retention only;
- `cluster/sql/cluster_init.sql`, `tape/sql/tape_init.sql` — 128 GB defaults;
- `cluster/scripts/bric-performance-apply.sh` — existing cluster catalog policy update;
- `tape/scripts/bric-chunk-policy-apply.sh` — existing tape catalog policy update;
- `test/run_restore_progressive.sh`;
- `test/run_multi_pair_transition.sh`.

## Requested native gate order

1. `test/run_parallel_target_policy.sh`
2. `test/run_performance_policy.sh`
3. `test/run_restore_progressive.sh`
4. `test/run_restore_fallback.sh`
5. `test/run_local_e2e.sh`
6. `test/run_dr_e2e.sh`
7. `test/run_multi_pair_transition.sh`
8. full `test/run_all_tests.sh`

Please preserve workroots/logs on any failure.

## Key review risk

The most important new invariant is:

    no chunk N+1 is staged for a progressive request until chunk N has a valid signed CONSUMED receipt

and READY is only published after the single tape->tee(QNAP)->sha256 pipeline has completed and matched the authoritative ciphertext SHA.

Please challenge crash/restart and mixed-version behavior aggressively.
