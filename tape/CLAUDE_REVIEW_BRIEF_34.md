# Review 34 — independent review brief

Review the candidate against the supplied Review 33R3 final baseline. Do not install it during review.

## Required gates

1. Verify `MANIFEST.sha256`, clean extraction, shell syntax and both static Go helpers.
2. Confirm `tape/**` is byte-identical to Review 33R3 and `on_tape_format=BRIC-FORMAT-V1` remains unchanged.
3. Verify migration `files-v34-mode-metadata` is additive/re-entrant and gives the same `files` column order on an upgraded 33R3 DB as on a fresh 34 DB.
4. Run the complete native suite serially with real `sqlite3`, `acl` and `attr` tooling. The suite now includes `run_34_file_metadata_fidelity.sh`.
5. Reproduce the original large-file finding with at least two oversized files: source 0600 and 0755 must restore to exactly 0600 and 0755, not umask-derived 0644.
6. Set a historical mtime on oversized files and prove it is restored exactly. Then simulate a legacy pre-34 row (`mode=NULL`, `metadata_b64=''`) and prove mtime is still restored while mode is not invented.
7. Large-file POSIX ACL and binary `user.*` xattr must round-trip. If the test filesystem exposes `system.nfs4_acl`, verify that it round-trips as raw bytes too.
8. TAR_PART mode/mtime/POSIX ACL/`user.*` must still round-trip through GNU tar -> Go `archive/tar` rewrite -> restore.
9. Verify metadata drift fencing: change mode/ACL/xattr between planning/capture and chunk production and require fail-closed behavior in both local/parallel and Slurm paths.
10. Verify normal full restore, single-file large restore, full DR and single-file DR all apply large-file metadata only after payload verification.
11. Verify old on-tape project catalogs without `mode`/`metadata_b64` are accepted by DR's temporary schema upgrade.
12. Confirm Review 33 crash/restrictive-directory tests still pass; specifically ensure adding `system.nfs4_acl` to the transaction snapshot did not reintroduce SELinux/system.posix_acl false failures.
13. Confirm ownership semantics are unchanged: no source UID/GID restoration; `--no-same-owner` remains intentional.

Candidate must remain `build_state=candidate` until this native gate is green.
