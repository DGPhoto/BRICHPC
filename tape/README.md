# BRIC Archive System 2.0 — scheletro (verificato in simulazione)


## Review 32B4A — escrow wrong-key test contract

32B4A is test-only. It replaces a probabilistic raw AES-CBC wrong-key assertion in `run_escrow.sh`
with the authenticated `master_unwrap` path used by production break-glass recovery. No runtime code
or on-tape format changed from 32B4.

## Review 32B4 — production campaign safety

32B4 is the handoff candidate for phased real-user archiving. It preserves the 32B3 irreversible
CLOSED barrier, moves allocator correctness locks to a dedicated host-local per-user directory that
is independent of logging placement, and makes source readability semantics explicit. By default,
all unreadable/untraversable included paths are logged and the backup fails before tape reservation.
With explicit `--force`, precisely identified unreadable paths are skipped, logged without truncation,
and recorded in `run_exclusions` with reason `force-unreadable`; the remaining readable scope is
archived. `--exclude RELPATH` remains a distinct operator-declared scope choice and is recorded as
`user-declared`. Unknown traversal/I/O failures remain fatal even with `--force`. No tape format or DB
migration is introduced.

## Review 31E7

31E7 makes the signed `run.CLOSED` receipt a true terminal catalog barrier: final reservation release
and the CLOSED audit row are committed atomically before the receipt is published. This removes the
SQLite lock race exposed by the 31E6 full gate while preserving BRIC-FORMAT-V1. 31E6 initialization
failover breadcrumbs and the 31E4 central-log ACL runtime remain unchanged.


Archiviazione a freddo su LTO-9 per dati genomici (BRIC, KU). I due server non condividono
cataloghi né il filesystem sorgente: condividono soltanto il bus di staging NFS sul QNAP. Il cluster
SLURM produce blob cifrati opachi e il tape server li drena su nastro. Il tape server **non vede mai una chiave né del plaintext**.

> **Nuovo a questo progetto, o devi farne la review?** Parti da [`ARCHITECTURE.md`](ARCHITECTURE.md):
> una pagina con la tesi, gli invarianti portanti, una riga per componente e la regola di estensione.
> Questo README è il dettaglio; quello è il modello mentale compresso.
>
> Logging operativo e formato machine-readable: [`docs/LOGGING.md`](docs/LOGGING.md).
> Il preflight hardware verifica anche la corrispondenza tra elementi changer e `/dev/nstN`.
> La completezza globale delle coppie non è richiesta: la reservation controlla soltanto le coppie
> già assegnate al progetto e il numero minimo di coppie complete onsite necessario ai byte richiesti.



## Review 31E4 — runtime-enforced central user-log ACLs

Review 31E4 supersedes installed 31E3 after a real `bric status` showed that leaf event/process files
kept the user's broad NSS primary group (`users`) with `group::r--` and did not carry the intended
named `bric:r--` ACL. Parent-directory isolation still blocked ordinary cross-user traversal, but the
leaf contract was not self-contained and non-root BRIC administrators were not guaranteed read access.

31E4 makes the central per-user tree fail-closed at runtime: every central directory and every emitted
event/process/job file is explicitly normalized to deny the owning group, grant the named BRIC admin
group only the required read/traverse rights, and deny `other`. If that ACL cannot be enforced, the
normal user logger uses the private `~/.bric/log` fallback instead of leaving an ambiguously protected
central file. Idempotent user activation also repairs safe single-link legacy log files from 31E3.
Tape I/O and BRIC-FORMAT-V1 are unchanged.

## Review 31E3 — central per-user operational logging + explicit initialization failover

Review 31E3 supersedes the failed-gate/uninstalled 31E1 candidate, the un-deployed 31D3 candidate, and the rejected/uninstalled 31E candidate. 31D2 remains the hardware-proven base: it passed
**64/64** natively and completed real dense smoke `smoke_real1__20260907T143553Z__0012` on the existing
`000001L9` / `000002L9` pair, verifying the 54,904,509,472-byte first chunk on both tapes, closing cleanly,
returning media to slots 7/44, and leaving `/tmp` at 39 MiB. The ~52 GiB cgroup memory observed after the
run was confirmed to be reclaimable `inactive_file` page cache, not anonymous verifier memory.

31E3 retains the 31E1/31D3 descriptor-hygiene fix: singleton/work-fence close helpers are idempotent, so nested
workers cannot close a numeric descriptor that Bash has reused after inherited daemon lock FDs were dropped.
This removes the observed `10: Bad file descriptor` diagnostics without changing tape locking, streaming verify,
positioning, media-health attribution, database state, crypto, restore semantics or `BRIC-FORMAT-V1`.

The logging policy is deliberately different from the rejected 31D3 design. Operators need one central audit
location, so every activated real user receives a root-provisioned primary at
`/var/log/bric/users/<OS-user>`. The collection root is `0751 root:bric`: BRIC admins may enumerate it while
ordinary users may only traverse to a directory they already know. Each per-user tree is owned by that user,
its broad NSS owning-group ACL is explicitly `---`, and a named/default `bric:r-x` ACL gives administrators
read/traverse access to all current and future event/process/job leaves. Files remain `0640`; the private
`~/.bric/log` tree remains `0700` and is used only if the central primary is actually unavailable.

Existing pre-31E1 managed environments are compatible: when no explicit `BRIC_LOG_DIR` exists, the runtime
derives `/var/log/bric/users/$(id -un)` from the effective OS identity and preserves the old home log as fallback.
The central directory itself is privileged state and must be provisioned by rerunning the idempotent
`bric-activate-user USER` after installing 31E3 (new activations do this automatically).

## Rejected candidate 31D3 — daemon FD hygiene and private user-log primary

Review 31D3 supersedes 31D2 after the latter passed **64/64** natively and then completed the real
dense smoke `smoke_real1__20260907T143553Z__0012` on the existing `000001L9` / `000002L9` pair.
The smoke wrote and verified the 54,904,509,472-byte first chunk on both tapes, closed cleanly, returned
media to slots 7/44, and left `/tmp` at 39 MiB.

31D3 fixes two residual hygiene defects discovered from that successful run. First, inherited daemon
singleton/work-fence close helpers are idempotent, so a nested worker cannot close a descriptor number
that Bash has reused after the inherited lock FD was already dropped; this removes the observed
`10: Bad file descriptor` diagnostics without changing parent locking. Second, normal onboarded users
use their private `~/.bric/log` as **primary** rather than probing operator-only `/var/log/bric` leaf
directories and permanently falling back. Pre-31D3 fallback-only managed env files are promoted to the
private primary before system config loading, so existing users gain the corrected behavior immediately.

No tape verifier, positioning, media-health, database, crypto, bus, restore, or on-tape-format semantics
change in 31D3. The ~52 GiB cgroup memory observed after the smoke was confirmed to be reclaimable
`inactive_file` page cache (anonymous memory only a few MiB), not a verifier memory leak.

## Review 31D2 — native-gate harness correction and colored status

Review 31D2 supersedes the un-deployed 31D1 candidate after its native 64-test gate completed
**60 OK / 4 FAIL**. The 31D1 production daemon and streaming-verifier policy are retained unchanged.
The four failures were traced to validation/harness assumptions exposed by the new stdout streaming
read form, plus the 31D supervised-pass process topology:

- `run_real_e2e.sh`: its legacy `dd` mock handled `dd if=DEV of=FILE` but not `dd if=DEV` to stdout.
- `run_vtl.sh`: `bric-vtl` generated the same stale `dd` read mock; the VTL was not exercising a long
  real-file stream as initially suspected. The generated VTL mock now emits the selected tape file to
  stdout when `of=` is absent.
- `run_verify_failure_attribution.sh`: DB assertions were correct but structured events were incorrectly
  searched in captured human stderr. Each case now owns hermetic primary/fallback structured-log roots.
- `run_written_recovery.sh`: Review 31D deliberately supervises `one_pass` in a child to preserve Bash
  errexit semantics. The crash regression now synchronizes on catalog state `WRITTEN` and kills the
  complete daemon-generation process tree, matching systemd control-group termination, rather than
  assuming the MainPID is the whole generation.

The full-suite runner now renders successful status as **OK in green** and failed status as **FAIL in
red** on an interactive terminal. Redirected output remains plain text; `NO_COLOR` is honored.

No database, on-tape format, backup/restore protocol, crypto, streaming verifier, media-health policy,
or production tape-daemon logic changes are introduced by 31D2.

## Review 31D1 — short-stream media attribution correction

Review 31D1 supersedes the un-deployed 31D candidate. The streaming verifier and logging/runtime
hardening from 31D are retained, but the media-health mapping is corrected after native
`run_audit_health.sh` exposed a real regression. Verification return code 21 can only be emitted after
the stream pipeline itself returned success and the byte counter observed a clean length different
from the catalogued size. With segment-sized local scratch removed, this is no longer the 31C1 ENOSPC
class: it is evidence of a short/long tape/drive stream and is treated as a media/read-path failure.

Policy is therefore: rc 20 = transport/local failure with no media penalty; rc 21 = clean size mismatch
with media penalty; rc 22 = exact-size SHA mismatch with media penalty. Immediate segment verification
accounts the physical append and marks non-BAD media `SUSPECT` for rc 21/22. Periodic `--verify` counts
rc 21/22 in `read_errors` and marks the tape `BAD`; only transport/local failures preserve health.
The end-to-end attribution regression now covers all three failure classes. No format, schema, crypto,
bus or restore change is introduced.

## Review 31D — superseded pre-release candidate

The original 31D candidate is retained here for review history only and MUST NOT be deployed. Review 31D keeps `BRIC-FORMAT-V1`, the tape catalog schema, crypto, bus protocol and restore format
unchanged. It fixes a real-hardware failure found by dense run
`smoke_real1__20260907T082604Z__0011`: post-write verification materialized one complete readback per
drive with `mktemp`, so two concurrent 54,904,509,472-byte copies exhausted the tape host's local
70 GB root filesystem. The fallback event log captured both failures exactly: PRIMARY stopped after
31,258,050,560 bytes and BACKUP after 33,101,971,456 bytes with `No space left on device`.

Post-write, close-artifact, TOC and periodic tape verification now stream tape bytes directly through
an exact byte counter and SHA-256. Segment-sized scratch is no longer required; only tiny control files
(FIFO/count/hash) are created. Verification classifies outcomes explicitly: transport/local failure
(rc 20), complete stream with wrong byte count (rc 21), exact-size stream with wrong SHA-256 (rc 22),
or success. **Historical 31D candidate policy (rejected):** it treated rc 21 like a local failure.
Review 31D1 supersedes that mapping: rc 21 and rc 22 are media/read-path failures; only rc 20 is
host/local and preserves media health.

The daemon no longer depends on Bash `errexit` for this control flow. Review 31C1's loop invoked
`one_pass || log ...`; Bash suppresses `errexit` throughout functions called from an `||` context, so
a failing inner tape-read subshell returned non-zero but `write_copy` continued into SHA verification
of a truncated tempfile. Review 31D checks verification return codes explicitly and executes each loop
pass outside an `if/||/&&/!` dynamic context while still allowing the parent daemon to report a failed
pass and continue.

Structured event logs now resolve `events/YYYY-MM-DD` on every event rather than freezing the daemon's
start date. A structured primary-log write that fails over to NFS emits a durable `LOG_FAILOVER`
breadcrumb on the fallback and a stderr/journald warning. Raw process stdout/stderr logs remain
process-lifetime files by design.

No database migration is required. Existing physical orphan bytes from failed runs remain correctly
accounted as `ABANDONED`; media telemetry polluted by the 31C1 local-ENOSPC incident must be corrected
administratively only after reviewing any older independent error history for that cartridge.

## Review 31C1 — test-contract correction (runtime identical to 31C)

Review 31C1 changes **tests and release metadata only**. Production runtime files are byte-identical to
Review 31C. The point release updates pre-existing regressions to assert the 31C singleton/collision behavior rather than
diagnostic wording or an installed-tree path, repairs a latent `run_real_e2e.sh` tape-position mock bug (`echo 0>file` did not
write zero), models `bsfm 2`, and forces the first immediate readback to exercise the absolute fallback
at tape file #1. No on-tape, database, backup, restore, daemon, updater, or setup runtime semantics change.

## Review 31C — immediate readback positioning and generation-safe tape daemon

Review 31C keeps `BRIC-FORMAT-V1` unchanged. Immediate verification of a file just appended to tape now
uses a guarded `eod -> bsfm 2` path, checks the physical file number against the append result, and falls
back automatically to absolute `rewind+fsf` positioning on any mismatch. Restore, reverify, sniff and
arbitrary reads remain absolute. Real LTO-9 measurements on both production drives reduced immediate
positioning from about 55 s to 12.5-12.9 s for the measured 2.668 GB file.

The same release closes the historical tape-daemon singleton migration hole: the daemon fences the new
canonical `/var/lock/bric_tape.lock` plus every known deployed `/tmp`/`/run` namespace and corresponding
work fence before recovery. `bric-update` refuses any foreign/extracted-tree daemon left after systemd
stop, and tape `PROCESS_START` records script/repository/review provenance.

### Review 31B1 allocation note

When authoritative source extent topology is unavailable, byte content is preserved but GNU tar may represent long zero ranges as sparse. The encrypted run catalog records `allocation_topology=not-guaranteed` and `restore_allocation_effect=zero-ranges-may-restore-as-holes`; therefore a physically preallocated zero range can restore as a hole even though file bytes are identical.

## Review 31B — PAX-map sparse semantics and explicit source consistency

Review 31B keeps `BRIC-FORMAT-V1` but removes `st_blocks` from sparse classification and batch sizing.
The authoritative outer GNU tar stream already carries `GNU.sparse.map` in PAX 0.1 members; BRIC now
uses that map's actual data/hole ranges to decide whether sparse preservation is material and to estimate
batch payload. This is required on sources such as Dell PowerScale/OneFS over NFSv3, where server-side
storage accounting may make `st_blocks` smaller than logical size while client `SEEK_HOLE` cannot expose
the remote extent topology. The catalog therefore states `allocation_topology=not-guaranteed`: archived
bytes remain authoritative, but BRIC does not claim to reproduce the source filesystem's allocation map.

Sparse batches still use GNU tar and remain ordinary V1 multi-member `TAR_PART`s. During the batch re-read,
Review 31B parses the exact GNU tar output through a tee while those same raw bytes are encrypted and
compares each member's SHA-256 with the authoritative outer-stream hash. This removes the former third
source read without weakening drift detection. The 4 GiB default remains unchanged.

GNU tar source changes are now policy-controlled without generic warning suppression. `strict` remains the
default and aborts on `file changed as we read it`. Explicit `--source-change-policy record` accepts only
`tar rc=1` for which every non-empty diagnostic is exactly FILE_CHANGED_DURING_READ; those diagnostics are
stored in `run_source_changes`, while `run_source_semantics` records the policy, consistency state, tar rc,
sparse-map method, and allocation-topology guarantee. Mixed rc=1 warnings and all rc>=2 failures remain
fatal. `bric source-changes PROJECT` exposes the records from a CLOSED encrypted project catalog.

## Review 31A — conservative sparse-batch default for live HPC trees

Review 31A keeps all Review-31 behavior and `BRIC-FORMAT-V1`, but lowers the production default and
fallback for `sparse_batch_target_bytes` from 64 GiB to **4 GiB**. A materially sparse member is read
by the authoritative outer tar stream, read again by GNU tar when its sparse batch is emitted, and
read a third time for drift verification. Batching therefore widens the interval between first
observation and final verification. On mutable shared HPC trees, 4 GiB captures most of the tape-file
amortization benefit while materially reducing drift exposure and restart cost. The value remains
configurable with `BRIC_SPARSE_BATCH_TARGET_BYTES` / `sparse_batch_target_bytes`. No schema, restore,
crypto, daemon, or on-tape format change is introduced.

## Review 31 — source integrity, explicit archive scope, and throughput

Before any tape reservation, `bric backup` now traverses the exact included source scope as the calling
UID and refuses unreadable files or non-listable/non-traversable directories. Intentional omissions are
explicit `--exclude RELPATH` subtrees, are applied identically to preflight and GNU tar, and are stored
in the encrypted project catalog (`run_exclusions`); `bric exclusions PROJECT` displays them later.
The same preflight records logical/allocated source bytes so `bric status` can report scan-relative
progress. Review 31 also carries forward 30AH sparse batching and makes the tape daemon immediately
rescan after observable progress instead of inserting a full poll sleep between ready chunks.
`BRIC-FORMAT-V1`, read-back verification, crypto and existing restore/DR semantics are unchanged.


## Review 30AH — batched sparse TAR_PARTs for LTO throughput

Materially sparse files no longer force one encrypted chunk and one physical tape file per member.
`bric-tar-stream` now queues sparse-member metadata from the authoritative outer tar walk and emits
many queued sparse files through one GNU tar process into a single valid sparse `TAR_PART`. The tar
stream is encrypted directly; no plaintext staging file is created. Existing V1 restore and DR code
remain unchanged because a `TAR_PART` has always been an independent tar archive that may contain
multiple members. The default sparse-batch target is 64 GiB of estimated on-tape payload (allocated
blocks plus conservative metadata allowance), configurable with `BRIC_SPARSE_BATCH_TARGET_BYTES` or
`sparse_batch_target_bytes` on fresh catalogs. Normal non-sparse chunks now use the 128 GB decimal segment target; the sparse batching
target remains a separate payload policy. Regression coverage verifies full restore, single-file member extraction, sparse allocation
preservation, and a scale case where 100 materially sparse files collapse to 7 TAR_PART chunks at a
1 MiB test batch target. No database migration, bus protocol change, restore-format change or
`BRIC-FORMAT-V1` change.


## Review 30AG — deterministic close-hardening async barriers

`test/run_close_hardening.sh` no longer relies on fixed sleeps while an asynchronous tape daemon
consumes close markers. Each negative scenario now waits for the daemon to log the exact refusal
condition before mutating the fixture for the next scenario; the positive close waits for the
`run.CLOSED` receipt. This removes a race where the missing-artifact fixture could be restored before
the daemon observed it, yielding a false `no missing-artifact log` failure even though sealing was
correctly blocked. No production code, database schema, bus protocol or on-tape format change.

## Review 30AF — hermetic setup E2E systemd/admin-path isolation

`test/run_setup_e2e.sh` now exercises the real `bric-setup.sh --role all` systemd installation path
without touching the host that runs the suite. All administrative destinations (systemd unit, command
links and man directory) are redirected into the test temporary root; deterministic `systemctl`, `ps`
and `pgrep` shims exercise `daemon-reload`, `enable --now`, `is-active` and the manual-daemon collision
check without starting, enabling or killing any real host service/process. The test fingerprints the real
administrative paths before setup and asserts they are unchanged afterwards. No production datapath,
database schema, bus protocol or on-tape format change.

## Review 30AE — resilient QNAP budget probing and visible test progress

The global QNAP byte-budget probe is now tri-state instead of single-shot fatal. A successful probe
continues normally, an over-budget probe waits, and a genuine probe failure (for example NFS
ESTALE/EIO/ETIMEDOUT) pauses staging, preserves the underlying `find` diagnostic on stderr, and retries
on the normal poll interval. The producer aborts only after a configurable number of consecutive
probe failures (default 12; override with `BRIC_QNAP_PROBE_MAX_FAILURES` or config key
`qnap_probe_max_failures`). A successful probe resets the counter. This remains fail-closed: no new
ciphertext is staged while bus occupancy is unknown. The same bounded-retry policy is used by both
`bric-stream-gate.sh` and the legacy `bric-chunk.sh` path.

`test/run_all_tests.sh` now prints explicit progress (`[n/N] RUN`, `[n/N] PASS/FAIL`) and refuses to
run the full cross-role suite from a role-filtered/incomplete installed tree such as `/opt/bric2`. Run
the full suite from a complete extracted release tarball so all cluster and tape code paths are
available. No bus protocol, database schema, or on-tape format change.

## Review 30AD — race-safe global QNAP budget accounting

A real 30AC smoke run reproduced the historical producer failure signature (`bric-stream-gate` rc=1,
`bric-tar-stream` rc=1, upstream tar rc=141/SIGPIPE) even though the per-run staged-file race fixed in
30AA was no longer present. The remaining race was in the global QNAP byte-budget scan:
`qnap_inflight_bytes()` still used recursive GNU `find` while the tape daemon concurrently removed
verified `chunk_*.enc` files. Review 30AD uses `find -ignore_readdir_race`, which ignores only the
expected ENOENT between readdir/stat while retaining fail-closed behavior for genuine traversal/I/O
errors. The legacy `bric-chunk` sliding-window path now also counts per-run staged blobs with a Bash
`nullglob` array instead of `find | wc`. Regression coverage exercises both races and verifies that real
find failures are still fatal. No bus protocol, database schema, or on-tape format change.

## Review 30AC — CLOSED receipt compatibility and terminal-marker authenticity

Review 30AB was rejected before deployment because its terminal drain fence suppressed the pre-existing
idempotent re-DONE behavior for a re-published READY on a CLOSED run. Review 30AC restores that bus
contract without reopening tape I/O: CLOSED may pass only through the branch that reconstructs DONE
from two already-VERIFIED segment rows; the full terminal fence remains in force before any new tape
allocation or write. ABORTED/ABORT_DONE/DENIED continue to block all chunk handling.

Terminal marker existence remains a safety fence, never destructive authority. A dedicated signing-enabled
regression test proves that an unsigned `run.ABORTED` stops tape I/O but cannot delete staging or publish
`run.ABORT_DONE`. No bus protocol, database schema, or on-tape format change.

## Review 30AB — daemon terminal fencing and failure propagation

Tape pair preparation and media release now propagate worker failures explicitly instead of relying on
Bash `set -e` behavior inside guarded function calls. Terminal run markers fence all new tape I/O both
before and after READY claims. Marker existence is deliberately a **fence only**: ciphertext cleanup is
performed only after a signed/path-bound `run.ABORTED` is verified. CLAIMED timestamps are refreshed at
claim time and terminal/ERROR claims are never reclaimed into the old retry loop.


## Review 30AA — stream-gate race and sparse batching

The streaming gate now tolerates `chunk_*.enc` files being deleted concurrently after tape receipts;
a healthy run can no longer fail through a `find`/`pipefail` race and upstream tar rc=141. Mildly sparse
files are aggregated into normal TAR_PART chunks instead of each becoming a tiny tape file. Only files
with at least 64 MiB of holes or no more than 75% allocated bytes remain independent sparse TAR_PARTs.

## Review 30Z — inventory import restart fencing

The physical-inventory importer releases its singleton and work-fence locks before restarting
the tape daemon. This prevents a successful catalog import from being followed by a false daemon
restart failure. The tape systemd unit also preserves `/run/bric` across service stops.

## User experience

After root has run `bric-setup.sh --role slurm` and `bric-setup-user.sh --user NAME`, the user logs in and runs only:

```bash
bric backup PROJECT /path/to/data [--as LOGICAL_ROOT]
bric restore PROJECT /path/to/restore
bric status
bric list --long
bric jobs
bric log JOB_ID
bric cancel JOB_ID
```

The wrapper automatically reads the user's BRIC key metadata. BRIC keeps an already suitable OpenSSL or dynamically selects a loadable OpenSSL >=3 from Environment Modules; users do not source files or load modules. The explicit `--project`, `--source` and `--dest` forms remain available. Run `bric --help`, `bric help COMMAND`, or `man bric` for the complete user reference.

## Perché questa architettura
- Il tape server non può montare Isilon via NFS; tar+crypto sono troppo pesanti per lui.
- Il QNAP è leggibile da tutti via NFS → ci scriviamo **solo** tarball cifrati opachi. L'albero
  POSIX completo vive *dentro* il tar: file regolari, **directory (anche vuote), permessi, mtime e
  symlink** (archiviati come link, mai dereferenziati). FIFO/socket/device non sono dato d'archivio
  e vengono saltati con un warning. Il bus non deve materializzare l’albero POSIX né dereferenziare
  symlink: trasporta soltanto blob cifrati e marker.
- I checksum per-file e la mappa file→chunk restano **solo** nel catalogo del cluster, mai sul QNAP.

> **Permessi dell’export QNAP NFS (controllo di sicurezza, non opzionale).** Il bus può essere
> *leggibile* dagli host autorizzati (i contenuti sono cifrati e opachi), ma deve essere **scrivibile
> soltanto dagli account/gruppi di servizio BRIC** sui due host. Sul QNAP usare la host allow-list NFS,
> mapping/squash coerente e permessi POSIX/setgid sul gruppo `archive` o `bric` (`2770` sulle directory,
> `0660` sui marker/blob). È questa la difesa filesystem contro la *forgery* dei marker: un account non
> autorizzato non deve poter creare un `READY`+`.meta`+`.enc` fasullo e far sprecare nastri. In aggiunta
> il daemon valida i nomi di directory del bus (`valid_name`) come difesa
> in profondità, e il restore/DR verificano l'HMAC del ciphertext (Encrypt-then-MAC) **prima** di
> decifrare. La firma ECDSA P-256 dei marker è **bidirezionale** (vedi sotto): ogni lato firma ciò che
> pubblica e verifica il peer, mantenendo il tape server keyless rispetto ai dati.

## Flusso (bus a marker, rename atomico)
```
ISILON (NFS, solo cluster)
   │  nodo "archive" SLURM: tar(file interi) | sha256 | openssl enc  (un solo stream, no plaintext)
   ▼
QNAP  /bric/archive/<project>/<run_id>/   ← bus opaco
   chunk_NNNN.enc(.sha256|.hmac|.meta)
   marker run:   RESERVE_REQUEST → RESERVED|DENIED      (semantica B: prima i nastri, poi i byte)
   marker chunk: READY → CLAIMED → DONE|ERROR           (claim = rename atomico, un solo vincitore)
   marker close: PROJECT_CLOSING → CLOSE_PLACEMENT → CLOSE_CATALOGS → CLOSED
   ▼  il tape server fa polling, NON riceve notifiche
TAPE SERVER (mtx/mt) → 2 copie per chunk (PRIMARY+BACKUP) → rilettura+verifica sha → DONE
```
Restore = bus inverso in `/bric/restore/<project>/<req_id>/`: il cluster chiede i chunk (è l'unico a
sapere la mappa file→chunk). Review 32B1 usa un handshake progressivo `READY → CONSUMED`: il tape
server ristagia e verifica **un chunk alla volta**, pubblica un `request.PROGRESS` firmato mentre legge,
il cluster autentica/decifra/ricolloca quel chunk e lo libera prima che il daemon proceda al successivo.
Lo SHA-256 ciphertext viene calcolato nello stesso stream tape→QNAP (`tee | sha256sum`), senza rileggere
l'intero blob dal QNAP una seconda volta.

**Assunzione infrastrutturale (importante).** La correttezza del bus dipende da tre proprietà POSIX del
filesystem condiviso tra i due server: **`rename()` atomico** (il claim di un chunk è un rename: un solo
vincitore), **visibilità coerente cross-host** (un file/marker creato da un host è immediatamente e
interamente visibile all'altro) e **assenza di cache incoerenti** (niente letture stantie). Valgono per il
nostro export QNAP NFS configurato in modo coerente, **ma non sono garantite su una condivisione
di rete qualsiasi** (alcuni setup NFS con caching/attribute cache aggressivi o implementazioni che non
mantengono la semantica POSIX attesa per il rename nello stesso export violerebbero queste ipotesi). Su un filesystem che non le rispetta il sistema non va usato senza prima
verificarle. La firma ECDSA P-256 dei marker protegge da forgiatura/replay, non da incoerenze del filesystem.

**Assunzione sulla sorgente (importante, con guardia attiva).** Archiviare preferibilmente da uno
snapshot o da dati congelati. In `BRIC_RUN_MODE=local` (Review 30M) GNU tar è la fonte autorevole:
il catalogo descrive ciò che tar ha realmente letto e non esiste più una lunga finestra fra planning e
produzione. Se un file cambia mentre tar lo sta leggendo, GNU tar termina con errore e BRIC abortisce il
run senza chiuderlo come valido. La modalità Slurm conserva temporaneamente il percorso legacy
`bric-plan`/`bric-chunk`, che continua a registrare e riverificare size+mtime prima e dopo la produzione.
Gli **hard link non sono deduplicati** in entrambe le modalità: vengono archiviati come file regolari
indipendenti (spazio nastro moltiplicato; al restore diventano copie separate).

**Costo del DR su hardware reale.** `bric-dr-from-tapes` e il rebuild cercano il TOC scandendo il nastro
**a ritroso dall'EOD fino al file 1** (nessuna finestra fissa: è ciò che garantisce la tesi anche con un
run successivo interrotto a metà). Ogni candidato è riconosciuto leggendo **un solo blocco**
(`tape_sniff_first_block`), non il file intero; il costo per candidato è quindi un posizionamento
(`fsf`) + una lettura da 256 KiB, non ore di lettura di un blob dati. Con il default 128 GB ci sono più filemark per nastro, ma lo sniff
resta di un solo blocco per candidato; il costo è ancora dominato dal posizionamento, non dalla lettura
dell'intero chunk. Il DR resta
comunque un'operazione lenta per costruzione: pianificare ore, non minuti, per un progetto multi-nastro.

## Decisioni chiave (tutte implementate)
- **Chunk = unità di lavoro = tar+cifratura**, default **128 GB decimali** (`128000000000` byte).
  Un chunk non attraversa mai due nastri; 128 GB riduce il worst-case di un restore casuale e lo spreco
  di coda a fine cartuccia rispetto al precedente target ~980 GB/~245 GB-worker. Con 0.30 TB di headroom
  una LTO-9 da 18 TB contiene circa 138 chunk da 128 GB. File > target → `LARGE_FILE_CHUNK` (range di
  byte). Compressione **off** (dati già compressi). La taglia resta configurabile e va benchmarkata contro
  throughput/posizionamento, ma 128 GB è il nuovo default restore-latency-bounded.
- **Esclusività nastro = per-progetto** (`tape_exclusivity=project|owner|shared`): un nastro tiene un
  solo progetto; pieno → nuovo nastro stesso progetto. L'append riusa i nastri del progetto con spazio.
- **Semantica B**: il planning **riserva** i nastri (atomico sotto flock, TTL ~8 giorni) *prima* di
  produrre. Nastri insufficienti → STOP, niente prodotto. La prenotazione è calcolata sul
  **ciphertext**, non sul plaintext: aggiunge l'overhead del framing tar (header 512B + padding per
  membro) e openssl (salt/pad per chunk) più un margine `reservation_overhead_pct` (default 2%), così
  un progetto con tantissimi file piccoli non viene sotto-prenotato.
- **Niente SQLite su filesystem di rete**: due cataloghi separati e autoritativi
  (`cluster_catalog.db` = dati; `tape_catalog.db` = fisico) + bus a file con rename atomico.
- **Crash a metà scrittura = strategia A**: il segmento è `WRITING` *prima* della scrittura su nastro;
  al riavvio i `WRITING` sospetti sono abbandonati (`ABANDONED`) e i chunk riscritti (no interpretazione
  della coda). Onestà: la copia abbandonata resta *fisicamente* sul nastro append-only — ciò che è
  garantito è che **il catalogo non referenzia mai duplicati** (TOC e restore usano solo righe
  `VERIFIED`, mai i parziali abbandonati). **Stessa disciplina alla chiusura**: ogni catalogo/script è
  un artefatto idempotente (`tape_artifacts`); se è già `VERIFIED` con lo *stesso* sha si salta, se con
  sha **diverso** il close fallisce (mai skip silenzioso); il `TAPE_TOC.txt` è appeso per ultimo e
  `run.CLOSED` è pubblicato solo quando **ogni** artefatto del manifest firmato è `VERIFIED` su **ogni**
  nastro — un artefatto mancante o non combaciante **blocca** la sigillatura.
- **DONE = scritto E riletto-verificato** (re-sha del ciphertext su PRIMARY e BACKUP), e il blob QNAP è già stato liberato o il daemon ha emesso un warning esplicito di mancata rimozione.
- **TOC fisico su nastro**: a fine chiusura ogni nastro termina con un `TAPE_TOC.txt` in chiaro che
  mappa ogni file-number al suo contenuto (chunk run/no/role o catalogo). È l'indice che il disaster
  recovery legge per primo, senza alcun database.
- **Livelli di recovery su nastro** (scritti alla chiusura del progetto):
  1. `catalog_project.enc` — catalogo del progetto, cifrato con la **chiave utente**;
  2. `user_key_escrow.v1` — la stessa chiave utente già avvolta e autenticata con la **master key**;
     è solo ciphertext project-bound, non una chiave utilizzabile dal tape server;
  3. `restore_from_tape.sh` + `README_RECOVERY.txt` + `schema.sql` — **in chiaro**, non segreti.
  La master non entra mai nei job dell'utente e non viene mai scritta sul nastro. Le vecchie cassette
  con `catalog_system.enc` restano leggibili dal DR per compatibilità. Derivazione dati:
  `ENC=sha256(user_key+":encryption")`, `HMAC=sha256(user_key+":authentication")`.
- **Disaster recovery a livello-progetto**: `cluster/scripts/bric-dr-from-tapes.sh --project NAME --dest
  DIR (--user-key-file FILE | --master-key-file FILE) [--file REL] [--tapelib DIR]` ricostruisce un
  intero progetto (o, con `--file`, un singolo path) dai **soli nastri + chiave utente**, senza
  cluster/catalogo/daemon/QNAP: legge i TOC per trovare `catalog_project.enc`, lo decifra, e legge ogni
  chunk dal nastro con fallback automatico **PRIMARY→BACKUP** sul fallimento dell'HMAC, verificando
  SHA-256 ciphertext + HMAC prima di decifrare e SHA-256 plaintext dopo. `--master-key-file` è il
  break-glass admin (recupera la chiave utente dall'escrow). Il kit chunk-level `restore_from_tape.sh`
  resta scritto su ogni nastro (auto-contenuto).
- **(b)** il cluster tiene anche `project_tapes` (progetto→VolumeTag, popolata alla chiusura) così
  `bric list --long` mostra i nastri; il tape server resta autoritativo (i file number stanno solo lì).
- **Convenzione barcode (parità)**: il ruolo è dato dalla parità del numero di barcode — di default
  **pari = onsite/PRIMARY, dispari = offsite/BACKUP** (con etichette da 0: `000000`=PRIMARY,
  `000001`=BACKUP, …); il BACKUP di una coppia è sempre `PRIMARY+1`. Configurabile in `bric-setup.sh`
  (`BRIC_PRIMARY_PARITY=even|odd`) e in `bric-tape-rebuild-catalog.sh` (`--primary-parity`). Il ruolo
  effettivo resta comunque registrato in `tapes.role` ed è autoritativo a runtime; la parità serve
  all'assegnazione iniziale, alla derivazione dell'appaiamento e al fallback in ricostruzione.

## Osservabilità
- **Audit trail append-only** su entrambi i cataloghi (`audit_log`): il cluster registra le azioni
  utente (run richiesto, riserva/denied, run chiuso, restore), il tape server quelle fisiche
  (riserva, `SEGMENT_VERIFIED`, `TAPE_FULL`, chiusura, re-verify). Per quando fra anni qualcuno dirà
  «quel progetto non l'ho mai cancellato».
- **Salute nastri** (colonne in `tapes`): `write_count`, `mount_count`, `write_errors`, `read_errors`,
  `last_verify`, `health` (OK|SUSPECT|BAD). Una verifica fallita in scrittura marca il nastro SUSPECT.
- **Re-verifica periodica**: `bric-tape-daemon --verify VOLUMETAG` rilegge ogni segmento+artefatto
  VERIFIED del nastro, ri-calcola lo sha del ciphertext e aggiorna `last_verify`/`health`/`read_errors`
  (da cron, es. un nastro a notte). È così che si intercetta il degrado lento dell'LTO prima che
  serva il dato.

## Albero
```
cluster/  sql/cluster_init.sql  bin/bric  scripts/{lib_common,bric-plan,bric-chunk,bric-finalize,
          bric-close,bric-restore,bric-dr-from-tapes}.sh  slurm/archive_array.sbatch
tape/     sql/tape_init.sql  bin/bric-tape-daemon  scripts/{lib_common,lib_tape_io}.sh
test/     run_local_e2e.sh  run_dr_e2e.sh  run_close_faultinj.sh  run_real_backend_mock.sh
          run_real_e2e.sh  run_audit_health.sh
```

## Stato / hardware reale
Lo scheletro è **completo e verificato end-to-end** in simulazione *e* attraverso il vero percorso
comandi del nastro. `tape/scripts/lib_tape_io.sh` ha due backend dietro 4 funzioni
(`tape_append_file`, `tape_read_file`, `tape_last_file_number`, `tape_list_volumetags`):
- `BRIC_TAPE_BACKEND=sim` — una dir per VolumeTag (nessun hardware), per i test.
- `BRIC_TAPE_BACKEND=real` — **LTO-9 via `mtx` (changer) + `mt` (posizionamento) + `dd` (I/O)** su
  `/dev/nst*`, blocchi a lunghezza variabile (lunghezza esatta preservata), tutte le operazioni
  changer serializzate sotto un lock dedicato e I/O serializzato **per drive**. Con due drive, PRIMARY
  e BACKUP fanno `mt/dd` contemporaneamente su lock indipendenti; ogni worker completa append,
  filemark, read-back e SHA prima della barriera. Numerazione file 1-based: in append si legge il
  contatore del drive a `eod` e si ritorna `count+1`; in lettura `rewind` + `fsf N-1`.

Configurazione hardware (env): `BRIC_CHANGER=/dev/sch0`, `BRIC_DRIVE0=/dev/nst0`,
`BRIC_DRIVE1=/dev/nst1`, `BRIC_TAPE_DRIVES="0 1"`, `BRIC_PARALLEL_DRIVES=2`,
`BRIC_TAPE_BLOCK=262144`. Load, spin-up, rewind, eject e unload hanno timeout indipendenti per drive;
sono disponibili anche override come `BRIC_DRIVE_READY_TIMEOUT_1` e
`BRIC_DRIVE_UNLOAD_TIMEOUT_1`. L'inventario reale si
popola da `mtx status` (riusa `bric-import-inventory` dal 1.x; ruolo/coppia per **parità** del barcode,
default pari=onsite, vedi sopra).

**Due-drive e coerenza**: il daemon mantiene la coppia caricata nei due drive durante i chunk e la
chiusura. Per ogni chunk, artifact e TOC aspetta entrambi i worker; `DONE`/`CLOSED` non possono essere
pubblicati finché PRIMARY e BACKUP non sono `VERIFIED`. Prima dello stato terminale, entrambi i drive
devono risultare vuoti e le cartucce nuovamente inventariate negli slot. Un drive veloce non fa
avanzare la fase mentre l'altro sta ancora scrivendo, rileggendo, riavvolgendo o espellendo.

**Nota timeout**: i `BRIC_*_TIMEOUT` bassi che vedi nei test (es. `BRIC_DRAIN_TIMEOUT=120`) sono valori
da *test*. In produzione vanno tarati sulle tempistiche reali di LTO-9: scrivere **e rileggere** un chunk da 128 GB resta un
I/O di molti minuti, quindi `BRIC_DRAIN_TIMEOUT`/`BRIC_CLOSE_TIMEOUT` devono avere margine per code e
robotica. Per il restore non si usa più un timeout totale di un'ora: `BRIC_RESTORE_QUEUE_TIMEOUT` copre
la coda e `BRIC_RESTORE_INACTIVITY_TIMEOUT` misura assenza di heartbeat firmati durante un restore attivo. Sono parametri operativi, non valori cablati nel codice.

Resta da validare sul sito la modalità `slurm` completa con il modulo OpenSSL del cluster e la coppia
fisica di nastri; la suite VTL copre lo stesso flusso software senza consumare cartucce. Un'ottimizzazione
ancora possibile è fondere lo SHA per-file nello stream del tar per dimezzare alcune letture. La firma
del bus è già implementata e attivabile come obbligatoria (`require_bus_signing`, vedi sotto).

**Prima del primo dato reale — prova di read-back su cartuccia scratch.** Il backend reale (`mtx`/`mt`/`dd`,
filemark, posizionamento, append, fedeltà della lunghezza) va validato a mano su una cartuccia sacrificabile
prima di affidare qualunque dato: vedi il runbook passo-passo con i gate go/no-go in
`docs/RUNBOOK_scratch_tape.md`. In più, `test/run_real_tape_smoke.sh` esegue le **stesse** funzioni di I/O del
daemon (`tape_append_file`/`tape_read_file`/`tape_last_file_number`) contro una scratch e confronta gli SHA
(scrive 3 payload, uno di lunghezza dispari); su backend reale richiede `--yes-write <VolumeTag>` come
guard-rail anti-incidente.


## Release identity and in-place updates (Review 30U)

A complete installation identifies itself through `/opt/bric2/RELEASE`:

```bash
bric version                         # Slurm/user side
sudo bric-update --current          # either host
```

Future releases are installed from a freshly extracted package without rerunning bootstrap:

```bash
sudo ./bric-update --role slurm --target /opt/bric2
sudo ./bric-update --role tape  --target /opt/bric2
```

The updater verifies the package manifest, refuses active archive/tape work, replaces only changed
static files, backs up replaced files under `/var/backups/bric2`, updates host integrations, and
preserves catalogs, configuration, keys, logs, user homes and the QNAP bus.

## Installazione / bootstrap (`bric-setup.sh` + `bric-setup-user.sh`)
`bric-setup.sh` inizializza host, cataloghi, inventario, master e chiavi bus. Gli utenti OS/AD si
provisionano separatamente, come root, con `cluster/scripts/bric-setup-user.sh --user NAME`, che crea
la chiave nella home utente e l'escrow istituzionale senza esporre la master.
Si lancia una volta per lato sull'host giusto:
```bash
./bric-setup.sh --role slurm        # cluster_catalog.db, master key, config
./bric-setup.sh --role tape         # sul tape server: tape_catalog.db, inventario nastri, config
./bric-setup.sh --role all          # staging mono-host (per la prova e2e)
./bric-setup.sh --role all --dry-run # anteprima senza scrivere nulla
```
È **sicuro da rieseguire**: schema `IF NOT EXISTS`, nastri `INSERT OR IGNORE` (non tocca cartucce in
uso), master non ruotata, e ogni catalogo esistente viene copiato in un `.bak.<timestamp>` prima di
essere toccato (nessun `DROP`). Anche l'onboarding utente è idempotente e rifiuta mismatch. I barcode vanno forniti via `BRIC_BARCODES_FILE` (etichette fisiche
reali, una per riga, coppie consecutive); il pattern di fallback è solo per lo staging. Con le chiavi
del bus presenti, attiva `require_bus_signing=1` su entrambi i lati in un colpo.

## Interfaccia web (utenti non tecnici)
Per chi non usa la CLI c'è una piccola interfaccia web, lanciata come **job SLURM** e raggiunta via
**tunnel SSH**, sullo stesso schema del template RStudio del sito:
```bash
sbatch /projects/bricsoftware/apps/bric2/cluster/web/bric-web.sbatch
# poi segui le istruzioni di tunnel stampate nel log del job:
#   ssh -L 8787:<nodo>:<porta> <utente>@supekgate.unicph.domain
#   http://localhost:8787/<token>/
```
Modello di sicurezza, volutamente semplice: **una sessione per utente**, perché il job gira con l'uid
di chi lo lancia — quindi ogni comando `bric` eredita identità, permessi e **chiave personale**
dell'utente, senza alcun login applicativo. Il **tunnel SSH è il confine di rete**; in più ogni URL
porta un **token di sessione casuale** (capability URL), così se qualcuno sulla LAN del cluster
raggiunge la porta del nodo riceve comunque `403` senza il token (difesa in profondità sopra
`--auth-none`). L'interfaccia consente di avviare un backup, vedere l'avanzamento dei propri run e
ripristinare; le operazioni distruttive non sono esposte.

Implementazione (`cluster/web/bric-web.py`): un singolo file Python 3 **solo stdlib** (nessun pip),
confinato al layer UI — non tocca il percorso di recovery. Tutte le mutazioni passano per la CLI `bric`
invocata con **argv** (mai `shell=True` → niente shell-injection); il catalogo è letto in **sola
lettura**. Config di sito opzionale in `cluster/web/bric-web.env` (vedi `bric-web.env.example`).

## Cluster / SLURM: partizione e ciclo di vita dei job
La partizione `archive` = i **nodi CPU** (no GPU) che montano **sia** Isilon (NFS, lettura) **sia** il
QNAP (NFS, scrittura). Sono **condivisi** con il calcolo di ricerca: la partizione è un "buon vicino"
(priorità bassa in coda, mai preemption sui job in esecuzione, footprint minimo per task). Esempi
concreti pronti da adattare: `cluster/slurm/archive_partition.conf.example` (partition + QOS + health)
e `cluster/slurm/healthcheck_qnap.sh` (mette il nodo in DRAIN se la mount cade).

Sizing del task chunk (`archive_array.sbatch`): è **I/O-bound** (lettura Isilon + stream tar|openssl su
NFS), non CPU-bound (AES-NI), quindi `--cpus-per-task=2 --mem=2G`; `--constraint=qnap` lo vincola ai
nodi con le mount; `--time` va tarato sulle tempistiche reali del workload; il default dati è ora 128 GB per chunk.

Ciclo di vita robusto:
- **Planner fuori dal login node.** `bric backup` (modalità slurm) non pianifica più in foreground:
  sottomette un breve **job orchestratore** (`bric-orchestrate.sh`) che fa plan → attesa `RESERVED` →
  submit dell'array + finalize, poi esce. Se la sessione SSH cade, la pipeline sopravvive. L'export
  verso i job è una **whitelist** di variabili `BRIC_*`, non `--export=ALL`.
- **`afterany`, non `afterok`.** Il job finalize/close dipende `afterany` dall'array, così gira
  **anche se** qualche task fallisce: `finalize` è l'unico handler e riconcilia lo stato.
- **Rilevazione veloce dei task morti.** Quando `finalize` parte (array terminale), ogni chunk ancora
  `PLANNED`/`PRODUCING` = task produttore morto (nodo/OOM/preemption) senza marker: `finalize` lo
  rileva subito senza aspettare il timeout di drain.
- **Pulizia su fallimento (protocollo `run.ABORTED`).** Su fallimento `finalize` marca il run `FAILED`
  e pubblica un `run.ABORTED` firmato; il tape server **rilascia la reservation**, marca `ABANDONED` i
  segmenti parziali (i blocchi fisici restano orfani, append-only) e libera i blob sul QNAP, poi acka
  `run.ABORT_DONE`. Niente più run appesi in `PRODUCING` né reservation che si liberano solo al TTL.
- **Requeue sicuro.** `#SBATCH --requeue` è abilitato perché tutto è **idempotente**: un task
  ri-eseguito il cui chunk è già completato esce 0 senza ri-staging, e il tape server, vedendo un
  chunk già `VERIFIED`, **non riscrive** un segmento duplicato — ri-emette solo il `DONE`.

`max_inflight_chunks` (blob contemporanei sul QNAP) e il `GrpTRES=cpu` della QOS sono due tetti di
concorrenza da tenere **coerenti**: vince il più piccolo.

## Hardening sicurezza (Batch 1)
- **Validazione nomi** (`valid_name`, charset `^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$`): `project`/`owner`
  validati in `bric-plan`; il daemon valida i nomi di directory del bus (anti path-injection).
- **Encrypt-then-MAC verificato**: restore e DR controllano l'HMAC-SHA256 del *ciphertext* (chiave
  derivata `:authentication`) **prima** di passare il blob a `openssl -d` → niente decrypt cieco di
  blob manomessi/forgiati. Il DR in più **ripiega su BACKUP** se il PRIMARY fallisce l'HMAC.
- **Estrazione tar difensiva**: nessun `-P` (GNU tar rimuove leading `/` e rifiuta membri con `..`)
  più `--no-same-owner` per evitare chown indesiderati in restore.
- **Preflight dipendenze** in `bric` (`sqlite3 openssl tar find stat flock awk sha256sum`).
- **Permessi QNAP**: lo share dev'essere scrivibile solo dal gruppo `archive` (vedi sopra) — è la
  barriera reale contro la forgery dei marker, dato che il tape server è keyless.

## Autenticazione del bus (firma ECDSA P-256 dei marker, **simmetrica**)
Difesa crittografica contro la *forgery* dei marker, complementare ai permessi Samba. La firma è
**bidirezionale**: ogni lato **firma** con la propria chiave privata i marker che pubblica e
**verifica** con la chiave **pubblica** del peer quelli che consuma.

- cluster → tape: `run.RESERVE_REQUEST`, `chunk_*.meta`, `chunk_*.READY`, `run.PROJECT_CLOSING`,
  `run.CLOSE_CATALOGS`, `request` (restore) — un attaccante con scrittura sul QNAP non può far
  scrivere/riservare nastri con marker falsi;
- tape → cluster: `run.RESERVED`/`DENIED`, `chunk_*.DONE`/`ERROR`, `run.CLOSE_PLACEMENT`,
  `run.CLOSED`, `staged_*`, `request.STAGED` — chiude il buco più grave: un **`DONE` forgiato**
  farebbe liberare un blob non ancora su nastro = **perdita dati**. Ora il cluster verifica la firma
  prima di liberare il blob.

La chiave di firma del tape server **non** è un segreto che decifra dati, quindi il server resta
*keyless rispetto ai dati* (può autenticare le sue ricevute ma non può leggere nulla).

**Anti-replay/relocation (path binding + domain separation):** non basta che la firma sia valida — il
consumatore verifica che il contenuto firmato corrisponda al path: `run_id == basename(dir)`,
`chunk_no == numero nel nome`, `project == dir genitore`. In più, la firma **non** copre il body nudo
ma un envelope canonico `BRIC-MARKER-V1\n<project>/<run>/<name>\n<body>` (*domain separation*): così una
`.sig` valida non è trasferibile su un altro nome di marker, un'altra run o un altro progetto **nemmeno
a contenuto identico** — la verifica ricostruisce il prefisso dalla posizione reale del file e la firma
salta crittograficamente. Provato in `test/run_bus_signing.sh` (test 6).

**Rischio residuo accettato — replay *in loco* (review #A):** path-binding e domain separation impediscono
di *spostare* un marker firmato; non impediscono di **rimettere lo stesso identico file** (marker+`.sig`)
al suo posto originale. Mitigazioni già presenti: i marker sono write-once con rename atomico; tutte le
operazioni sono idempotenti (un `READY` ri-pubblicato per un chunk già `VERIFIED` è un no-op, non un
duplicato — `test/run_job_lifecycle.sh`); l'accesso in **scrittura** al bus QNAP è ristretto (il QNAP è
world-*readable*, non world-writable) e la firma gatekeepa l'autenticità. Un anti-replay completo
(nonce/generation monotòni per run nel catalogo, controllati a ogni marker) è deliberatamente **non**
implementato: aggiunge stato incrociato per una minaccia (attaccante con scrittura sul QNAP che non è il
cluster) fuori dal modello, in contrasto con la filosofia "semplice e recuperabile".

**Close blindato:** `run.CLOSE_CATALOGS` porta un **manifest firmato** degli artefatti
(`artifact|nome|kind|sha256`). Il tape server rifiuta di sigillare se anche un solo artefatto manca o
non combacia con lo sha del manifest; il `TAPE_TOC.txt` è scritto **per ultimo** e `run.CLOSED` solo
quando ogni artefatto è `VERIFIED` su ogni nastro. Un artefatto già `VERIFIED` con sha **diverso** è
errore fatale (mai skip silenzioso).

```bash
# generare le DUE coppie (una tantum). Ogni host tiene la propria privata + la pubblica del peer.
cluster/scripts/bric-bus-keygen.sh
# CLUSTER:     export BRIC_BUS_SIGN_KEY=keys/cluster_bus_ecdsa_p256.pem
#              export BRIC_BUS_VERIFY_KEY=keys/tape_bus_ecdsa_p256.pub
# TAPE SERVER: export BRIC_BUS_SIGN_KEY=<copia di tape_bus_ecdsa_p256.pem>
#              export BRIC_BUS_VERIFY_KEY=<copia di cluster_bus_ecdsa_p256.pub>
```

Abilitazione per presenza delle chiavi (env): senza, i marker sono non firmati e il sistema funziona
come prima (retro-compatibile). La firma base64 è in un sidecar `<marker>.sig` pubblicato **prima**
del marker, così il consumatore non vede mai un marker firmabile senza la sua firma.

**Hardening produzione (`require_bus_signing=1`):** la retro-compatibilità "firma se le chiavi ci sono"
va bene per il rodaggio, ma in produzione un deploy che dimentica le env var **degraderebbe in silenzio**
a bus non firmato. Con `require_bus_signing=1` nei due cataloghi, il daemon **rifiuta di partire** e gli
script del cluster **rifiutano di pubblicare** se mancano `BRIC_BUS_SIGN_KEY`/`BRIC_BUS_VERIFY_KEY` —
niente degrado silenzioso.

## Modello delle chiavi, onboarding e key-escrow
Due livelli di segreti, rigorosamente separati:
- **Chiave utente**: una per identità OS/AD, installata da root in `~/.bric/<user>_user_key.txt`
  (`0600`, proprietà dell'utente). Cifra chunk e `catalog_project.enc`; i job Slurm leggono solo questa.
- **Master key istituzionale**: amministrativa/offline, indicata da `BRIC_MASTER_KEY_FILE`; avvolge gli
  escrow e non è mai leggibile dall'utente, dal job Slurm o dal tape server.

L'onboarding canonico è root-only e idempotente:

```bash
BRIC_CONFIG=/etc/bric/bric.conf \
BRIC_MASTER_KEY_FILE=/root/.bric/master.key \
cluster/scripts/bric-setup-user.sh --user vsz652
```

Il comando risolve l'utente via NSS/SSSD, crea `~/.bric`, genera o recupera **la stessa** chiave,
la installa con ownership corretta, crea `~/.bric/env.sh` e salva nel catalogo soltanto l'escrow
`v2:<hmac>:<ciphertext_b64>`. È fail-closed: se chiave home ed escrow non coincidono, non ruota né
sovrascrive nulla. Per default non lascia un secondo handout plaintext nell'area amministrativa;
`--handout DIR` è esplicito.

Alla chiusura, il job utente non usa la master: copia sul nastro l'escrow già cifrato come
`user_key_escrow.v1`, legato a progetto e owner. L'amministratore con sola master può quindi fare:

```bash
bric-dr-from-tapes.sh --project NAME \
  --master-key-file /secure/master.key --dest /restore/NAME
```

Il DR verifica SHA dell'artefatto, binding progetto/owner e HMAC dell'escrow **prima** di decifrare,
recupera la user key e apre il catalogo progetto. Per cassette legacy, usa ancora `catalog_system.enc`.
In produzione `require_user_escrow=1` è obbligatorio: nessun planning parte senza onboarding.

Un utente normale non può impersonarne un altro esportando `BRIC_USER`: l'identità è l'account
OS/NSS effettivo; override differenti sono consentiti soltanto a root o a contesti esplicitamente
fidati (`BRIC_ALLOW_USER_OVERRIDE=1`, usato dai test/service workflow controllati).

## Fedeltà POSIX, NUL-safety e finestra scorrevole (Batch 2)
- **Albero POSIX completo**: il planner archivia file regolari (con checksum), più directory (incluse
  le vuote) e symlink come membri tar a dato-zero in un chunk di metadati finale. In restore i
  permessi/mtime delle directory sono applicati per ultimi (`--delay-directory-restore` + chunk di
  metadati come ultimo), così anche una dir di sola-lettura (`0500`) viene ricostruita correttamente.
  FIFO/socket/device sono saltati con warning (non sono dato, e bloccherebbero `tar`).
- **NUL-safety**: le member-list dei chunk sono scritte NUL-separate in scratch cluster-privato
  (`BRIC_RUNSTATE`, mai sul QNAP) e consumate con `tar --null -T`; nomi di file con newline o
  caratteri ostili non rompono più la pipeline. La proprietà vale **anche nel disaster recovery e nel
  restore**: i loop che rileggono i path dal catalogo recuperato usano `.mode ascii` di SQLite (campi
  0x1f, record 0x1e), e il parser del `TAPE_TOC` riconosce le righe-dato per pattern (non per numero di
  riga), quindi un filename con newline sopravvive intatto fino al `diff` finale (verificato dal test).
- **Finestra scorrevole**: in modalità SLURM l'array è sottomesso come `--array=1-N%max_inflight`, e
  il tape daemon libera ogni blob QNAP **subito dopo il DONE** (entrambe le copie VERIFIED su nastro),
  non al `finalize`. Il picco di staging sul QNAP è così limitato a ~`max_inflight_chunks` blob.
- **Parallelismo dentro un singolo run (Review 32A)**: il workload reale può essere decine di TB in
  un unico project/run, quindi il producer locale non dipende più da run indipendenti per sfruttare la
  banda Isilon→QNAP. `stream_parallel_workers` (default **4**) crea quattro GNU-tar stream concorrenti
  nello stesso `run_id`; un manifest NUL-safe assegna ogni file regolare a un solo worker con bilanciamento
  greedy per byte logici. Gli hash plaintext restano one-pass nel `bric-tar-stream`: non viene aggiunta
  una seconda lettura completa per `sha256sum`. Tutti i worker condividono il catalogo/run ma ottengono
  `chunk_no` globali univoci tramite `bric-stream-allocate.sh` (`flock` per-run + `BEGIN IMMEDIATE`).
  Directory/symlink sono emessi dopo i worker dati e ricevono numeri finali, mantenendo la proprietà
  restore “directory metadata last”. `stream_worker_chunk_bytes` default **128 GB**, uguale al hard cap `segment_target_bytes`: ogni worker
  può produrre chunk fino a 128 GB e l'allocator globale continua a interlacciare i `chunk_no` senza
  modificare l'ordine per-file (`chunk_index`) dei file grandi.
- **Concorrenza tra run separata dal parallelismo interno**: `max_concurrent_producers` torna a default
  **1**. È un limite run-level, non worker-level: evita che quattro utenti × quattro worker diventino
  accidentalmente sedici stream contemporanei. L'ammissione resta atomica via `producer_slot_acquire`;
  appena il run entra in DRAINING libera lo slot per il successivo. Il valore può essere aumentato dopo
  benchmark di sito, ma non è necessario per un singolo backup da 70 TB.
- **Tetto di sicurezza sullo spazio QNAP**: `qnap_budget_bytes` (~92 TB) è ora **applicato** come secondo
  cancello difensivo in `producer_slot_acquire`: somma i byte dei blob in volo (chunk `PRODUCED/READY/CLAIMED`,
  cioè non ancora drenati su nastro, su tutti i run — dal catalogo, senza scansione NFS) e, se raggiungono il
  budget, un nuovo produttore **attende** che il nastro liberi spazio. Con un produttore alla volta il bus è
  già limitato a ~`max_inflight_chunks` blob, quindi questo è una rete di sicurezza per il caso patologico
  (nastro bloccato, blob accumulati): `0` lo disabilita.

## Come girare i test locali
Nessun hardware né SLURM richiesti: dir locale come share QNAP, libreria nastri simulata.
```bash
bash test/run_local_e2e.sh        # archivio -> nastro -> chiusura -> restore (file/spezzato/intero)
bash test/run_dr_e2e.sh           # DISASTER RECOVERY: distrugge i 2 cataloghi+QNAP+chiavi (tranne
                                  #   la chiave utente) e ricostruisce tutto dai SOLI nastri
bash test/run_close_faultinj.sh   # crash simulato a metà chiusura: resume idempotente, niente
                                  #   duplicati, nastri ancora recuperabili
bash test/run_real_backend_mock.sh# backend REALE (mtx/mt/dd) provato con mock del changer/drive:
                                  #   parsing inventario, load/unload, posizionamento, numerazione
bash test/run_real_e2e.sh         # archivio+chiusura+DR completi attraverso il percorso mtx/mt/dd
bash test/run_audit_health.sh     # audit trail, salute nastri, re-verify (rileva bit-rot), packing
bash test/run_security.sh         # SICUREZZA: nome progetto ostile rifiutato; blob nastro manomesso
                                  #   bloccato dall'HMAC PRIMA di decifrare; DR si auto-ripara da BACKUP
bash test/run_posix.sh            # FEDELTA POSIX: dir vuote, permessi dir, symlink, nomi con spazi/
                                  #   newline; FIFO saltato con warning; free-on-DONE (finestra scorrevole)
bash test/run_escrow.sh           # KEY-ESCROW: close senza master; escrow ciphertext on-tape;
                                  #   break-glass admin con la SOLA master key
bash test/run_user_setup.sh        # ONBOARDING root: home/ownership, idempotenza, repair da escrow,
                                  #   mismatch e impersonazione BRIC_USER rifiutati
bash test/run_require_signing.sh  # HARDENING: require_bus_signing=1 -> daemon e cluster rifiutano di operare
                                  #   non firmati (niente degrado silenzioso); con le chiavi partono in MANDATORY
bash test/run_job_lifecycle.sh    # CLUSTER: requeue idempotente (nessun segmento duplicato) + fallimento
                                  #   produttore -> run FAILED + run.ABORTED -> reservation rilasciata + ABORT_DONE
bash test/run_bus_signing.sh      # BUS AUTH (simmetrico): firma ECDSA P-256 bidirezionale; chunk/reservation
                                  #   forgiati o firmati con chiave sbagliata rifiutati; ricevute tape firmate;
                                  #   replay/relocation bloccato dal path-binding
bash test/run_close_hardening.sh  # CLOSE: CLOSE_CATALOGS non firmato rifiutato; manifest firmato; sigillo
                                  #   negato se un artefatto manca o non combacia (sha); TOC per ultimo
bash test/run_wal_crash.sh        # WAL: kill -9 di un writer a transazione aperta -> integrity_check ok,
                                  #   committed sopravvive, pending rolled-back, nessun lock bloccato
bash test/run_tape_rebuild.sh     # DR CATALOGO: cancella tape_catalog.db e lo ricostruisce dai soli nastri
                                  #   (TOC) byte-identico all'originale; --verify ri-controlla gli sha
bash test/run_crypto_params.sh    # CRYPTO: -iter 10000 fissato ovunque; blob vecchi (default) ancora
                                  #   apribili; ricetta manuale (HMAC-before-decrypt) gira con soli openssl/tar
KEEP=1 bash test/run_local_e2e.sh # conserva la workdir per ispezione
```
Recupero manuale "solo nastri" (quello che farebbe un umano fra 10 anni):
```bash
cluster/scripts/bric-dr-from-tapes.sh --tapelib /path/ai/nastri \
    --project mouse_rnaseq --user-key-file ~/.bric/mykey.txt --dest /restore
```
Ricostruzione del **catalogo del tape server** dai soli nastri (se muore il suo SQLite ma le cartucce
sopravvivono): legge il `TAPE_TOC.txt` più recente di ogni cartuccia e riscrive `tapes`/`segments`/
`tape_artifacts`. `segments.owner` resta vuoto (vive cifrato in `catalog_project.enc`); l'appaiamento
PRIMARY/BACKUP è ri-derivato dalla numerazione dei barcode e va rivalidato con l'inventario fisico
(`mtx status`) prima di riprendere a scrivere:
```bash
tape/scripts/bric-tape-rebuild-catalog.sh --out /path/nuovo_tape_catalog.db \
    --tapelib /path/ai/nastri --verify    # --verify rilegge ogni file e ricontrolla sha + dimensioni
```

## Recuperabilità a lungo termine (parametri di cifratura fissati)
Tutte le `openssl enc` fissano esplicitamente `-iter 10000` invece di affidarsi al default di OpenSSL
(che potrebbe cambiare in una versione futura e rendere i nastri indecifrabili). 10000 **è** il default
storico, quindi i blob già scritti restano apribili. Parametri completi (anche in `README_RECOVERY.txt`
su ogni nastro): cipher `aes-256-cbc`; KDF `pbkdf2` `iter=10000` con `sha256`; salt **embedded** di 8
byte (header `Salted__`, niente da annotare a parte); MAC `HMAC-SHA256(ciphertext)` verificato **prima**
di decifrare (Encrypt-then-MAC); chiavi `sha256(user_key + ":encryption" | ":authentication")`. La
ricetta manuale è verificata end-to-end in `test/run_crypto_params.sh` con soli `openssl`, `sha256sum`,
`tar`.

**Perché `iter=10000` e non 600k.** La passphrase di cifratura **non** è una password umana: deriva da
una chiave utente generata casualmente ad alta entropia (`bric-setup-user`/`bric-register-user`), quindi non
è soggetta a brute-force da dizionario e un conteggio iterazioni alto non aggiunge sicurezza reale. È una
scelta, non un bug. Se un domani si volessero ammettere passphrase scelte da umani, alzerei a 100k–600k:
il costo è trascurabile (la derivazione avviene una volta per blob, non per blocco). Il parametro è
**fissato e registrabile** (vedi sotto), quindi un eventuale aumento può convivere con i nastri vecchi.

**Versionamento del formato (`BRIC-FORMAT-V1`).** Ogni formato persistente è versionato così che un
futuro V2 possa evolvere mantenendo la retrocompatibilità: i marker del bus sono `BRIC-MARKER-V1` (con
binding al path), l'indice di nastro è `# BRIC tape TOC v1`, il kit di recovery on-tape inizia con
`BRIC-FORMAT-V1`, e `config.format_version='1'` è registrato in entrambi i cataloghi. I blob e i cataloghi
cifrati sono `aes-256-cbc/pbkdf2/iter10000`: i parametri sono **fissati e registrati** (per-chunk nel
catalogo e in `README_RECOVERY.txt`), quindi un V2 può cambiarli scrivendoli nel nuovo header senza
rendere illeggibili i nastri V1. (Un header di versione in chiaro *davanti* al ciphertext di blob/cataloghi
è esplicitamente lasciato al V2, per non spezzare la retrocompatibilità del path di lettura attuale.)

## Project-scoped tape availability (Review 30E)

The library may contain unrelated, offsite, or temporarily incomplete pairs. A backup reservation
checks only the media required by its project: all pairs already assigned to that project plus the
minimum number of complete onsite EMPTY pairs needed to cover the requested bytes. With 18 TB LTO-9
and 0.30 TB headroom, a new 20 TB project reserves two pairs. Global library pair completeness is
not a production invariant.

## Root onboarding and key separation (Review 30F)

Real archive identities are provisioned with one root-only, idempotent command. The personal key is
installed in the user's home and only its authenticated master-wrapped escrow is stored centrally;
the institution master never enters user Slurm jobs, QNAP or the tape server. `bric-close` writes the
already encrypted `user_key_escrow.v1` artifact, and admin DR can recover from tapes plus the offline
master. Home/escrow mismatches fail closed and unprivileged `BRIC_USER` impersonation is ignored.

The canonical production gate is:

```bash
/opt/bric2/cluster/scripts/bric-setup-user.sh \
    --user vsz652 --strict-runtime-checks
```

The standard virtual suite contains 46 tests, including `run_user_setup.sh`, `run_tar_stream.sh` and `run_stream_reservation.sh`.

## Review 30H: zero-setup user logging

Root onboarding creates `/var/log/bric/users/USER` as central primary plus private `~/.bric/log` fallback. Users run `bric ...` directly; no local
`bric` group, `source`, module command, or writable `/opt` log directory is required.

## Temporary direct execution on supekgate (Review 30J)

When archive compute nodes do not yet have the Isilon/QNAP NFS mounts, enable local mode once as root:

```bash
cluster/scripts/bric-enable-local-mode.sh
```

Users then run only:

```bash
bric backup PROJECT /source/path [--as LOGICAL_ROOT]
bric restore PROJECT /destination/path
```

The complete pipeline runs on supekgate without Slurm. Backup and restore detach by default, print a PID/job id/log path, and survive SSH logout. Use `bric jobs`, `bric log JOB_ID` and `bric cancel JOB_ID`; add `--wait` only when foreground execution is desired. No shell/module initialization is required from the user. Set `BRIC_RUN_MODE=slurm` in `/etc/bric/bric.conf` later to return to distributed execution.

## Review 30L: scalable local planning and clean reset

The planner commits the complete file/chunk map in one SQLite transaction and obtains file metadata directly from `find`, avoiding per-file `sqlite3` and `stat` processes. Live planning counters are shown by `bric status`. Administrators can reset operational catalog state, while preserving user escrow and configuration, with:

```bash
/opt/bric2/cluster/scripts/bric-reset-catalog.sh --yes
```


## Review 30M: tar-driven local backup

La modalità locale Review 32A usa più stream concorrenti **dentro lo stesso run**. Ogni file regolare
appartiene a un solo worker; quindi i dati non vengono duplicati solo per ottenere parallelismo:

```text
                  +-> GNU tar worker 1 -> bric-tar-stream --+
source manifest --+-> GNU tar worker 2 -> bric-tar-stream --+--> QNAP --> tape daemon
                  +-> GNU tar worker 3 -> bric-tar-stream --+
                  +-> GNU tar worker 4 -> bric-tar-stream --+
                                   stesso project / stesso run_id
```

L'utente continua a usare:

```bash
bric backup PROJECT /source/path
bric status
bric log JOB_ID
```

Per la campagna performance Review 32A ogni **tar esterno dei worker locali** usa di default `blocking-factor 8192` (record da 4 MiB), configurabile con `BRIC_TAR_BLOCKING_FACTOR`/`tar_blocking_factor`, per ridurre syscall e pipe overhead. I TAR cifrati e conservati direttamente e il tar interno dei batch sparse mantengono il recording Review 31E7.

Il preflight già obbligatorio fornisce la dimensione logica del source e la modalità parallela costruisce un
manifest NUL-safe cluster-locale (mai sul QNAP) per partizionare i path. Non legge il contenuto dei file:
la lettura dati, l'hash plaintext e la cifratura restano una sola passata per worker. Ogni `TAR_PART` è un
archivio tar indipendente; un file maggiore del target per-worker viene rappresentato da `LARGE_FILE_CHUNK`.

La modalità parallela richiede inizialmente la capacità logica misurata dal preflight. Prima di aprire
ogni nuovo chunk l'allocator serializzato contabilizza ciphertext già pubblicato + budget dei chunk
`ALLOCATED` in corso e invoca il normale gate; se necessario emette `run.RESERVE_EXTEND_REQUEST` prima
che quel worker scriva il nuovo blob. Rimane quindi valida la regola “nessun byte oltre la capacità
prenotata”, anche con più writer concorrenti.

Il binario `cluster/libexec/bric-tar-stream` è statico Linux x86-64; il sorgente Go corrispondente è incluso nello stesso percorso per audit e ricompilazione. I file GNU sparse materialmente significativi conservano la sparse allocation. Da Review 30AH più membri sparse vengono raggruppati in un singolo TAR_PART GNU-sparse valido, senza plaintext temporaneo e senza cambiare BRIC-FORMAT-V1; gli hard link restano dereferenziati come file regolari indipendenti.

## One-command activation of a real OS/AD user

After the Slurm-side host setup, activate each real user as root with one command:

```bash
bric-activate-user ztm319
```

This performs personal-key creation or recovery, authenticated escrow, private home setup, SQLite
ACL installation, strict bus/signing checks and a final CLI test as the target identity. It is
idempotent and refuses a home-key/escrow mismatch instead of rotating the key. No administrator
plaintext handout is produced unless explicitly requested:

```bash
bric-activate-user ztm319 --handout /root/.bric/handouts
```

## Transient QNAP bus cleanup (Review 30V)

Successful terminal runs no longer leave transport marker trees indefinitely on the QNAP. CLOSED and
DENIED cleanup occurs only after the signed tape receipt is verified and committed to the cluster
catalog; FAILED/CANCELLED cleanup additionally waits for signed `run.ABORT_DONE`. Administrators can
inspect and remove leftovers from older releases with `bric-bus-cleanup --dry-run` followed by
`bric-bus-cleanup`.


## CLI validation and user-environment safety (Review 30W)

`bric COMMAND help`, `bric COMMAND --help`, and `bric help COMMAND` are equivalent.
Help exits before loading the operational runtime, running preflight, or creating a
background job. Backup and restore operands are fully validated before detachment, so
malformed commands cannot leave `backup.unknown` or `restore.unknown` job records.

Root onboarding remains confined to `~/.bric` and catalog ACLs. It never edits shell
profiles, module settings, `PATH`, or the login environment. The generated
`~/.bric/env.sh` has a BRIC-managed marker; an unmanaged file at that path is refused,
changed managed versions are backed up, and unchanged content is not rewritten.


### Real tape inventory import

On a configured tape host, use `bric-tape-import-inventory --dry-run` followed by `--apply` to
populate the catalog from `mtx status`. Pairing follows `BRIC_PRIMARY_PARITY`; existing written or
project-assigned tapes are never reinterpreted, incomplete pairs are reported and skipped, and the
catalog is backed up before the transaction.

From Review 30X onward `bric-update` reads `BRIC_ROLE` from `/etc/bric/bric.conf`. A manual `--role`
that conflicts with the file is refused, preventing a tape-role update from being applied to the
Slurm host or vice versa.

## Browse and search backup contents

The cluster catalog retains the relative path, entry type, size, modification time, chunk mapping and plaintext checksum for every archived entry. Review 32B5 adds a stable top-level `logical_root` for each source without changing TAR members or the on-tape format. By default it is the basename of the source path; use `--as NAME` when two different sources would otherwise have the same root. From 32B5R2 the logical root is one NFC path component of at most 255 bytes and may not contain `/`, `,`, control characters, or be `.`/`..`; a source basename containing a comma therefore requires an explicit safe `--as` value.

```bash
bric backup PROJECT /projects/lab/PCA159_N01 --as PCA159_N01
bric contents PROJECT
bric contents PROJECT --long --type file
bric contents PROJECT --history --long
bric find PROJECT sample01.bam
bric find PROJECT PCA159_N01/raw/ --run PROJECT__UTC__NNNN --long
bric restore PROJECT /restore/one --file PCA159_N01/raw/sample01.bam
```

The default `contents`/`find` view is the union of all CLOSED runs in the project, keyed by `logical_root/relative_path`; the newest CLOSED version of a duplicated logical path wins. Files present only in older runs remain visible because 32B5 does not introduce tombstones, so this union is not a claim that the view is a filesystem snapshot at the time of the latest run. `--history` shows every version with its run id; `--run RUN_ID` selects one immutable CLOSED run. `--limit` and `--offset` apply globally to the resulting view, and `--limit 0` disables the result limit. These commands do not read the QNAP staging bus or physical tapes.

A single-file restore normally uses the logical form `--file LOGICAL_ROOT/RELATIVE_PATH`. BRIC resolves the newest CLOSED run containing that logical key, reads the existing physical TAR member `RELATIVE_PATH`, and writes it below `DEST/LOGICAL_ROOT/`. With an explicit `--run`, the historical bare run-relative form remains accepted. A bare automatic lookup that is ambiguous across logical roots is rejected. Full `bric restore PROJECT DEST` is unchanged: it restores only the latest CLOSED run, without adding a logical-root directory.

Destination verification reports `VERIFIED-DESTINATION` when the restored regular file can be re-read and its SHA-256 matches. If authenticated/decrypted extraction succeeded but a final file cannot be re-read (for example mode `000`), 32B5 reports `VERIFIED-STREAM` instead of a false checksum mismatch; this is a weaker guarantee and does not prove physical persistence. A successfully computed unequal digest is `CHECKSUM-MISMATCH` and fails the restore. 32B5 does not change permissions or replay ACLs.

## Review 32B5R1 gate fixes

32B5R1 is a gate-follow-up to Review 32B5. It does not change the logical-namespace
model, database migration identifier, TAR members, tape layout, producer data path,
cryptography, or `BRIC-FORMAT-V1`.

The release reconciles five legacy test contracts with the 32B5 behavior and fixes
three defects found during independent review:

* disaster-recovery destination verification now distinguishes an unreadable final
  destination (`VERIFIED-STREAM`) from a successfully computed but unequal digest
  (`CHECKSUM-MISMATCH`);
* the historical 32B5R1 Slurm backup fix moved `BRIC_*` values into the `sbatch`
  process environment but used `--export=ALL`; 32B5R2 supersedes that transport,
  rejects comma in logical roots, and restores a names-only export allow-list;
* `bric backup --wait` orders submitted Slurm runs by the real `requested_at` column
  (then `run_id`) rather than the nonexistent `created_at` column.

The full restore contract remains unchanged: `bric restore PROJECT DEST` restores
the latest CLOSED run directly under `DEST`. Only automatic single-file logical
restore maps `LOGICAL_ROOT/RELATIVE_PATH` below `DEST/LOGICAL_ROOT/`.

The planned Review 32B5A work remains out of scope: restore journal, restrictive
directory permission relaxation/rollback, ACL/xattr rollback, exact cross-chunk
directory repair, and `--require-destination-verify` are not implemented here.

32B5R1 remains a **candidate** until the complete native suite is rerun on a host with
the real `sqlite3` CLI and ACL tooling and the independent review gate is green.


## Review 32B5R2 gate closure

32B5R2 follows the independent native gate of 32B5R1. The 32B4A baseline is now
present and its SHA-256 is
`095878febc2f71f7f695aaf8976220470a0a445b63532685e6cc5378a4606ca4`, closing
the previously missing byte-identity evidence for the protected producer/tape path.

The release additionally closes the remaining Slurm transport asymmetry and
environment-hygiene finding. Logical roots containing comma are rejected at the
namespace boundary. Backup, restore, array and finalize Slurm submissions place exact
values in the `sbatch` process environment and pass only an allow-list of variable
names to `--export`; blanket `--export=ALL` is not used. This keeps login-shell
variables such as `LD_PRELOAD`, `OPENSSL_CONF`, `PYTHONPATH` and unrelated tokens out
of the submitted job unless BRIC explicitly allow-lists them.

Disaster recovery now emits verification counters and an explicit stream-only warning,
matching the honesty of normal restore: `VERIFIED-STREAM` means authenticated/decrypted
recovery succeeded but the final destination was not independently re-read. It is not
reported as destination checksum proof.

The full-suite default per-test timeout is 600 seconds. This avoids classifying the
real-backend E2E (observed at 319 seconds in the independent gate) as a test failure.

Review 32B5A remains reserved for restore-journal and restrictive-directory
permission/ACL rollback work. 32B5R2 does not implement that scope.


## Review 33 — restore metadata transaction

Review 33 fixes the restrictive-directory restore class without changing `BRIC-FORMAT-V1`,
producer bytes, chunking, encryption, HMAC, tape placement or the 32B5 logical namespace.

During normal restore and disaster recovery BRIC now keeps directory metadata transactional:

- a per-UID SQLite journal is created under `/var/tmp/bric-restore-journal-UID` by default. When
  `BRIC_RESTORE_JOURNAL_ROOT` is set, it is treated as a site/test base and BRIC appends the effective
  numeric UID; the resulting private journal root is refused if it resolves below the restore destination;
- existing ancestors are snapshotted before BRIC temporarily adds owner `rwx` so later chunks can
  pass through directories whose archive-final mode is restrictive;
- directory entries are marked `APPLYING` before tar, recaptured after successful extraction, then
  held `RELAXED` until payload writeback and verification finish;
- `sync -f DEST` and destination verification happen while the directory tree is still traversable;
- final directory mode/ACL/xattr snapshots are replayed deepest-first only after verification;
- a stale journal from a crashed restore is recovered before a new restore starts; a live journal
  owned by another process blocks the new restore;
- metadata drift during the relaxed window fails closed and preserves the journal for inspection.

The journal is newline-safe: directory paths are stored as hexadecimal keys rather than parsed as
line-oriented text. Root and non-root DR use separate per-UID journal roots.

`bric restore ... --require-destination-verify` makes any `VERIFIED-STREAM` outcome fatal. Without
that option the existing tri-state verification semantics remain unchanged.

Review 33 does **not** change what the archive records. The current producer does not invoke GNU tar
with `--acls`/`--xattrs`; therefore this review protects destination ACL/xattr metadata while BRIC
relaxes permissions, but it does not claim source ACL/xattr archival fidelity for old or new tapes.

## Review 33R2 — deterministic restore-metadata gate

Review 33R2 keeps the Review 33 crash-safe restrictive-directory transaction and closes the 33R1 gate follow-ups: deterministic process-group teardown for tape-daemon tests, scoped journal umask, per-test restore-journal roots, and conservative handling of live PIDs with unknown process-start identity. It also retains the D1–D8 hardening (journal trust boundary, user-only xattrs, recovery drift protection, NO-DIGEST classification, existed=0 retry state, DR dependency documentation, sync fallback and PID-reuse handling).

The on-tape format remains `BRIC-FORMAT-V1`; producer/chunking and `tape/**` are unchanged. This release is a candidate until the native suite is green twice serially.


## Review 33R3 gate closure

`BRIC_RESTORE_JOURNAL_ROOT` is a **base directory**, not a shared journal directory. BRIC appends the effective numeric UID and enforces a private mode-0700 local journal directory for that user. A site-wide base therefore remains safe for multi-user Slurm restores.

Review 33R3 also refuses restore-metadata relaxation through symlinked path components: lexical containment blocks `..` escapes and resolved containment blocks symlink escapes. The test harness starts every background tape-daemon loop in its own session/process group and tears down the group before removing its workroot.


## Review 34 — file metadata fidelity

Review 34 preserves source POSIX ACLs, `user.*` xattrs and `system.nfs4_acl` for TAR_PART objects. Oversized `LARGE_FILE_CHUNK` files bypass TAR headers by design, so their permission mode and selected ACL/xattr envelope are stored in the encrypted project catalog and re-applied only after payload checksum verification. Existing pre-34 large-file rows keep `mode=NULL` and an empty envelope; their already-catalogued `mtime` is restored retroactively, while unavailable historical mode/ACL/xattr values are never invented. Ownership remains restore-user ownership (`--no-same-owner`). The physical tape format remains `BRIC-FORMAT-V1`; the catalog migration is `files-v34-mode-metadata`.

## Review 34R1 — metadata gate fixes

Review 34R1 keeps the Review 34 metadata model and closes its native-gate blockers. The serial planner now SQL-escapes the large-file metadata envelope with an explicit quote-safe Bash substitution, restoring the Slurm/orchestrator planning path.

Regular-file special permission bits have an explicit security policy: BRIC preserves ordinary `0777` permissions but does not resurrect setuid, setgid or sticky bits on regular files. This policy is identical for TAR_PART and LARGE_FILE_CHUNK and does not remove sticky semantics from archived directories. UID/GID ownership remains intentionally unrestored.

For restore journals, an explicitly configured `BRIC_RESTORE_JOURNAL_ROOT` is a shared base. If absent and creatable by the caller it is normalized to sticky mode `1777`; every actual per-user journal remains below `<base>/<uid>` with strict ownership, mode-0700 and local-filesystem validation. A pre-existing configured base that cannot safely support multiple UIDs is rejected with an explicit diagnostic.

## Review 34R2rc1 — B3 payload-safe recovery candidate

Review 34R2rc1 is an emergency recovery candidate after the first real Review 34+ restore on an ACL-governed Isilon destination exposed a GNU-tar xattr extraction regression. With PAX xattrs present, tar can create a new file, apply metadata, then reopen it for payload; inherited ACLs can make that reopen fail and leave a zero-byte file. The explicit `--allow-metadata-degradation` recovery path is restricted to a new/empty destination and extracts TAR_PART payload with `--no-xattrs --no-acls`, preserving payload verification while reporting and persisting metadata fidelity as `DEGRADED`. Strict restore remains the default.

The candidate also makes large-file metadata application deterministic, preserves mtime application when an explicitly degradable namespace is unsupported, stops treating synthesized base `getfacl` entries as real extended POSIX ACLs, exposes journal ACL/xattr replay diagnostics, and verifies effective create/unlink access after temporary directory relaxation. Disaster recovery receives the same explicit degraded-payload path; generated standalone recovery scripts avoid the known xattr extraction trap.

This is **not** the final metadata-fidelity Review 34R2. Exact TAR_PART ACL/xattr recovery still requires a second metadata pass and the real OneFS capability result. `BRIC-FORMAT-V1`, `files-v34-mode-metadata`, ownership policy and `tape/**` remain unchanged; `build_state` stays `candidate`. See `CHANGES_REVIEW34R2RC1_B3_PAYLOAD_SAFE_RECOVERY.md`.


## Review 34R2rc2 — rc1 gate fixes

Review 34R2rc2 supersedes rc1 for the emergency degraded-recovery path. It fixes the restore-journal empty-field TAB/IFS corruption found by the native transaction gate and fixes unprivileged metadata application for read-only final files by applying `user.*` before the final mode. Explicit degradation may skip unsupported/permission-denied selected ACL/xattr operations and records `metadata_fidelity=DEGRADED`; strict restore remains fail-closed. See `CHANGES_REVIEW34R2RC2_B3_RECOVERY_GATE_FIXES.md`.


## Review 34R2rc3 — real OneFS EINVAL gate fix

Review 34R2rc3 supersedes rc2 for the emergency degraded-recovery path. The real OneFS/NFSv4 capability probe showed that writing back `system.nfs4_acl` can fail with `EINVAL` even when the same blob was just read from the same object. rc3 therefore treats `EINVAL` as degradable for already-approved xattr/ACL metadata operations when and only when `--allow-metadata-degradation` is explicit. Storage/path failures such as `EIO`, `ESTALE`, `ENOSPC`, `EROFS` and `ENOENT` remain fatal; strict restore remains fail-closed.
