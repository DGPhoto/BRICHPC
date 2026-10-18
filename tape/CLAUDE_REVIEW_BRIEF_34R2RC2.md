# Independent review brief — Review 34R2rc2

Please gate rc2 specifically against the two rc1 findings.

1. Re-run `test/run_33_restore_txn.sh`; D1 must be gone. Inspect the case with empty `acl_b64` and non-empty `xattr_b64` and confirm no TAB/IFS field collapse remains.
2. Re-run the degraded restore E2E as a non-privileged user with a LARGE_FILE_CHUNK final mode `0444` and at least one `user.*` xattr. Expected: payload destination verification green; `user.*` present; final mode 0444; mtime restored; unsupported/denied NFSv4 ACL metadata yields DEGRADED/rc4 rather than restore failure.
3. Run the complete native suite.
4. Confirm `tape/**` byte-identical to rc1/34R1, database migration `files-v34-mode-metadata`, and on-tape format `BRIC-FORMAT-V1`.
5. Keep `build_state=candidate`; B3c still needs the real destination capability probe.
