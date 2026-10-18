# Claude review brief — BRIC Review 32A7

This is a test-only correction on top of 32A6.

The first full native 32A6 suite was 67/68: only `run_real_e2e.sh` failed. Its daemon had successfully
written/verified all 7 chunks on both copies before ABORT. Removing stderr suppression for diagnosis produced
a full archive+close+DR PASS, and the unmodified original test then passed 3/3 consecutive runs.

The fixture uses a single mocked drive for PRIMARY and BACKUP and performs write + immediate readback +
eject/load for each chunk. It had `BRIC_DRAIN_TIMEOUT=120`, while observed normal drain time is already
around that boundary. The initial failure is therefore a deterministic test-design race exposed by suite load,
not a production data-path defect.

32A7 changes only `test/run_real_e2e.sh`:

    BRIC_DRAIN_TIMEOUT=120 -> 300

No production code, tape format, DB schema, crypto, close semantics or restore semantics change.
Please verify the diff and rerun `run_real_e2e.sh` followed by the complete native suite.
