# Independent review brief — Review 34R1

Candidate goal: close the Review 34 native-gate blockers B1/B2 and the carried R1 journal-base residual without changing the Review 34 metadata model or `BRIC-FORMAT-V1`.

## Baselines

Please compare against both:

- Review 34 candidate SHA-256: `f66a295e55145509d696eca1ba2f23018f1ca898d191b0071ac0d1311eeedeb7`
- Review 33R3 final SHA-256: `397aadeef6a8cbea3c2f20a743a5096fc87e21abfc1f8835277b6574f02cabdd`

Expected invariants: `tape/**` remains byte-identical to 33R3; `on_tape_format=BRIC-FORMAT-V1`; database migration remains `files-v34-mode-metadata`.

## Gate requests

1. Verify manifest, disk file set, `bash -n`, static Go helper builds and `go vet`.
2. Re-derive the exact diff vs Review 34; no undeclared runtime changes.
3. **B1:** execute `bric-plan.sh` successfully on (a) ordinary files only and (b) a source containing an oversized file. Confirm normal TAR_PART rows are emitted and oversized mode/envelope are catalogued. Confirm the production Slurm/orchestrator path is no longer parser-corrupted.
4. Run the complete native suite serially. The six Review 34 failures (`run_close_faultinj`, `run_job_lifecycle`, `run_notifications`, `run_partial_pair_resume`, `run_posix`, `run_resilience_continuity`) must all be green. Prefer two clean 82/82 passes.
5. **B2:** independently test oversized regular files with `4755`, `2755`, and `1755`. They must not abort and must be represented/restored with only their ordinary `0777` bits. Test a below-threshold TAR_PART file with a special bit and confirm the same policy. Confirm sticky mode on directories is not globally stripped.
6. Verify the Review 34 metadata E2E still gives exact `0600`, `0755`, mtime, POSIX ACL and `user.*` fidelity, plus legacy `mtime` recovery.
7. Verify the added Review 33×34 fixture: an oversized `0444` file below a final mode-`000` ancestor returns `0444` and the ancestor finalizes to `000`. Do not chmod the restored tree before asserting modes.
8. **R1:** with `BRIC_RESTORE_JOURNAL_ROOT` pointing to a nonexistent configured base, run one restore transaction as root and one as `nobody`. The base should be sticky `1777`; `<base>/0` and `<base>/65534` must remain separately owned mode-0700 roots. Existing unsafe/symlink/network-root tests must remain fail-closed.
9. Re-run the Review 33 transaction/crash/restrictive-directory tests and ensure ACL/xattr subtests execute with native tools.
10. Confirm ownership policy remains unchanged: no `chown`, no `--same-owner`; restored ownership is still the restoring identity.
11. Confirm selected xattr namespace fences remain intact (`user.*`, POSIX ACL, `system.nfs4_acl`; no `security.*`/`trusted.*`).
12. Confirm no per-piece TAR wrapping or tape-format change was introduced.

Keep `build_state=candidate` until this gate is green.
