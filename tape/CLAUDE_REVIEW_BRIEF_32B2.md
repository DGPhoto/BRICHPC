# Claude review brief — BRIC Review 32B2

Review 32B2 is a test-only follow-up to 32B1. No production runtime code changes.

## Trigger

Your 32B1 run found one non-environmental red test:

```text
FAIL: inline sha256 evidence absent
```

You identified the assertion mismatch correctly: `inline_sha256=yes` is emitted by `bric_event` into the structured event tree, while the test searched the human daemon stdout/stderr capture.

## Fix

`test/run_restore_progressive.sh` now:

- creates explicit temporary `BRIC_LOG_DIR` and `BRIC_LOG_FALLBACK_DIR` under its own `$ROOT`;
- asserts `inline_sha256=yes` by recursively searching those structured `events/` trees.

This intentionally avoids relying on `/var/log/bric`, suite wrapper environment, or human log wording.

## Review request

Please confirm only these points:

1. the new assertion targets the durable structured-event contract;
2. direct invocation and suite invocation are now equivalent for this check;
3. no production files (`cluster/`, `tape/`) differ from 32B1;
4. after a native 70/70 pass, 32B1/32B2 software correctness can be considered closed and we can move to the physical multi-pair smoke.
