# Review 31E7 — run.CLOSED terminal catalog barrier

Review 31E7 fixes an intermittent close-hardening race exposed by the full 31E6 native gate (63/64):
`run.CLOSED` was published before the daemon's final SQLite writes (`reservation=RELEASED` and the
`CLOSED` audit row). A consumer that reacted immediately to the signed receipt could therefore race
the daemon and receive `database is locked`, even though all tape/artifact verification had succeeded.

## Change

The final close order is now:

1. all close artifacts VERIFIED;
2. paired TOCs VERIFIED;
3. all media returned to slots;
4. one `BEGIN IMMEDIATE ... COMMIT` transaction sets the reservation `RELEASED` and records the
   idempotent `CLOSED` audit row;
5. only after that commit succeeds, publish/sign `run.CLOSED`.

If the final catalog transaction fails, the daemon does **not** publish `run.CLOSED`; close remains
retryable. If the daemon crashes after the commit but before receipt publication, the next pass can
repeat the idempotent transaction and publish the receipt without duplicating the `CLOSED` audit row.

`test/run_close_hardening.sh` now creates a real synthetic reservation and, immediately after seeing
`run.CLOSED`, asserts in one SQLite snapshot that artifacts/TOC are VERIFIED, reservation is RELEASED,
and the CLOSED audit row is already committed. It deliberately uses no busy timeout so a receipt
published before final catalog quiescence remains a test failure.

No database schema, on-tape format, streaming verification, positioning, encryption, ACL, or user-log
policy changes are made.
