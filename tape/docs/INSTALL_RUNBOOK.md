# BRIC Archive 2.0 — Installation & Test Runbook (A → Z)

Target: **supekgate** (cluster side) + **brictape** (tape side, HPE MSL3040, AlmaLinux 10.2).
Run every phase in order. Each phase ends with a **GATE**: do not continue unless it holds.
Commands are written to be run as the OPERATIONAL user (`vsz652`), not root, unless stated.

Conventions used below:
    $REPO      = the deployed tree (e.g. /home/vsz652/bric2 or /opt/bric2)
    CLUSTER    = run on supekgate        TAPE = run on brictape        BOTH = run on each

---

## Phase 0 — Prerequisites (BOTH)

Have in hand before starting:
- [ ] The **Review 29 dual-drive/host-role** tree (or later).
- [ ] The list of **physical barcodes** of the LTO-9 cartridges, one per line, in slot order
      (read them from the labels / `mtx -f /dev/sg4 status`, NOT invented). Pairs are consecutive
      numbers; **even = PRIMARY = onsite** is the coded convention.
- [ ] Decision on paths: QNAP mount point, DB/keys locations (defaults are fine).
- [ ] HPE case 5403618424 resolved enough that the changer answers (no 0x02/04/03 sense).
      Phases 0–7 do NOT need working hardware; phases 8+ do.

Packages (verify, don't assume):

    command -v sqlite3 openssl tar awk dd flock || echo MISSING
    # TAPE only:
    command -v mtx mt sg_inq sg_turs sg_requests || echo MISSING

Mounts:
- CLUSTER: Isilon (NFS, read) reachable from the archive nodes; QNAP bus mounted **writable**.
- TAPE: QNAP bus mounted (same tree as the cluster sees); device nodes present:
  `/dev/sg4` (changer), `/dev/nst0` + `/dev/nst1` (drives).

**Bus mount (NFS).** Each host must mount from the address that matches its own entry in the
QNAP's NFS host allow-list (Control Panel > Shared Folders > Edit Shared Folder Permission >
NFS host access), otherwise the export is refused:

    # CLUSTER (supekgate, allow-listed as its corporate IP)
    <qnap-corporate-ip>:/<share>  /mnt/data  nfs  rw,hard,nosuid,nodev,proto=tcp,timeo=600,retrans=2,_netdev  0 0
    # TAPE (brictape, allow-listed as its point-to-point IP)
    192.168.1.3:/<share>          /mnt/data  nfs  rw,hard,nosuid,nodev,proto=tcp,timeo=600,retrans=2,_netdev  0 0

`nosuid,nodev` are not optional on a multi-user login node sharing a writable export.
Enable **`secure`** on the QNAP share (forces privileged source ports).

**Identity mapping.** BRIC never uses POSIX ownership: a run's owner is a string in the catalog,
and bus integrity comes from ECDSA P-256 signatures + HMAC/sha256 (verified from source — there is
not a single ownership check in the bus logic). So the UID/GID of bus files is irrelevant to
correctness, and AD-vs-local UID divergence between the two hosts does NOT need fixing for its
own sake. Only ONE thing must actually work: **the tape daemon must be able to delete the blobs
written by cluster users** (it frees them as soon as both copies are VERIFIED on tape). If the
daemon runs as root — which it needs anyway for the SCSI devices — `no_root_squash`
("Squash no users" on QNAP) makes this work regardless of any UID mismatch. Do not join brictape
to AD: it would make the tape server depend on corporate infrastructure, contradicting the
"recoverable without surviving infrastructure" principle. Phase 9 verifies the deletion
empirically instead of trusting this reasoning.

**GATE 0**: all commands found; QNAP visible from both sides with the same content.

---

## Phase 1 — Deploy the tree (BOTH)

    tar xzf bric_archive_2_0_review29_*.tar.gz -C ~/         # or /opt, your call
    cd ~/bric2
    chmod +x bric-setup.sh cluster/bin/* cluster/scripts/*.sh tape/bin/* tape/scripts/*.sh test/*.sh

**GATE 1**: `bash -n bric-setup.sh` silent; `test/run_all_tests.sh` exists.

---

## Phase 2 — Software validation: full test suite (BOTH, as the operational user)

    cd ~/bric2/test
    bash run_all_tests.sh                       # full virtual suite; real-tape smoke deliberately excluded

Expected: **every test PASS**. The suite is hermetic (never touches /etc/bric/bric.conf, real
devices, or a real mailer). If anything fails: stop, keep the printed log path, do not proceed.
Optional second pass as root (`sudo bash run_all_tests.sh`) — also expected all-PASS; the
unprivileged-DR section of dr_e2e only runs in the root pass.

**GATE 2**: all-PASS as the operational user on BOTH machines.

---

## Phase 3 — System config: /etc/bric/bric.conf + lock directory (BOTH, root once)

    sudo install -d -m 755 /etc/bric
    # supekgate:
    sudo cp ~/bric2/config/bric-slurm.conf.example /etc/bric/bric.conf
    # brictape:
    sudo cp ~/bric2/config/bric-tape.conf.example /etc/bric/bric.conf
    sudo $EDITOR /etc/bric/bric.conf

Minimum to set (uncomment + edit). Precedence everywhere is **environment > file > built-in**:

    # BOTH
    BRIC_QNAP=/mnt/data/bric                   # your real mount point
    BRIC_NOTIFY_MAIL=auto                      # mail on backup/restore events
    BRIC_NOTIFY_LOG=/var/log/bric/events.log
    # TAPE — your MSL3040 device map (VERIFY with lsscsi -g / sg_inq):
    BRIC_TAPE_BACKEND=real
    BRIC_CHANGER=/dev/sg4
    BRIC_DRIVE0=/dev/nst0
    BRIC_DRIVE1=/dev/nst1
    BRIC_TAPE_DRIVES="0 1"
    BRIC_TAPE_LOCK=/var/lock/bric_tape.lock      # 31C+ canonical singleton; absolute/local
    BRIC_TAPE_WORK_LOCK=/var/lock/bric_tape.lock.work # crash-generation fence; 31C also fences legacy /tmp and /run names
    BRIC_CHANGER_LOCK=/run/bric/changer.lock

Provision the runtime dirs (survive reboot via tmpfiles):

    sudo install -d -m 1777 /var/log/bric
    echo 'd /run/bric 0775 root root -' | sudo tee /etc/tmpfiles.d/bric.conf
    sudo systemd-tmpfiles --create /etc/tmpfiles.d/bric.conf

**GATE 3**: `BRIC_CONFIG=/etc/bric/bric.conf bash -c '. ~/bric2/cluster/scripts/lib_common.sh; echo $BRIC_QNAP'`
prints YOUR value, not the default.

**OpenSSL runtime.** `brictape` must expose OpenSSL 3.x to the daemon. On `supekgate`, BRIC does
not rely on the login shell and does not assume that one module is loadable by every UID. Local and
Slurm execution first keep the current OpenSSL when its major version is at least 3. Otherwise BRIC:

    module purge
    module -t avail openssl
    # tries compatible versions from newest to oldest
    module load <first loadable OpenSSL >=3>
    openssl version

`BRIC_SLURM_OPENSSL_MODULE` remains an optional preferred first candidate. For example, if
`openssl/3.5.7` is visible but denied to root, the resolver can fall back to `openssl/3.1.0`.
A module loaded by BRIC is purged by the job EXIT trap. Validate this from an actual Slurm job, not
only interactively. This is an operational alignment, not a recovery prerequisite: disaster recovery
uses parameter-pinned `enc`/`dgst` and remains readable with OpenSSL 1.1.1+.

---

## Phase 4 — Full rehearsal on the VTL (TAPE; zero cartridges consumed)

Dress rehearsal of the ENTIRE production flow against fake file-backed devices. Open a
**dedicated shell** (the VTL env redirects changer/drives for the whole session):

    cd ~/bric2
    tape/bin/bric-vtl create /tmp/vtl --tapes 4 --drives 2
    eval "$(tape/bin/bric-vtl env /tmp/vtl)"
    export BRIC_CONFIG=none                     # rehearsal is self-contained
    tape/bin/bric-library-preflight             # must be GREEN on the healthy VTL
    bash test/run_vtl.sh                        # scripted version of this whole rehearsal

Then, if you want the manual feel: start the daemon, run `bric backup`, `bric restore`, and a
`bric-dr-from-tapes.sh` exactly as in Phase 9, but on the VTL. When done:

    tape/bin/bric-vtl destroy /tmp/vtl --force
    exec bash            # IMPORTANT: fresh shell — drop the VTL environment before real hardware

NB: the VTL lives in the shell ENVIRONMENT (`eval env` = mock binaries in PATH + device vars).
Pointing /etc/bric/bric.conf at VTL paths is NOT enough: without the mock PATH, the real
mtx/sg_* run and the preflight rightly fails. Rehearse in the eval'd shell; the config file is
for real hardware.

**GATE 4**: preflight green + run_vtl PASS. You have now seen the whole flow end-to-end.

---

## Phase 5 — bric-setup (one run PER SIDE, as the operational user)

Prepare the physical barcode file on TAPE (one barcode per line, slot order, count must be EVEN):

    $EDITOR /etc/bric/barcodes.txt             # e.g. 40 lines, from the REAL labels

Dry-run first, READ the output, then run for real:

    # CLUSTER (supekgate): host/catalog/master only; real OS/AD users are onboarded in Phase 7
    cd /opt/bric2
    bash bric-setup.sh --role slurm --dry-run
    bash bric-setup.sh --role slurm

    # TAPE (brictape)
    BRIC_BARCODES_FILE=/etc/bric/barcodes.txt bash bric-setup.sh --role tape --dry-run
    BRIC_BARCODES_FILE=/etc/bric/barcodes.txt bash bric-setup.sh --role tape

Notes:
- Real OS/AD users are not batch-generated by host setup: use `bric-setup-user.sh` in Phase 7 so
  their NSS home, ownership, personal key and escrow are verified as one transaction.
- Setup is **idempotent**: safe to re-run; it never rotates the master, never duplicates tapes,
  and backs up any existing catalog before touching it.
- Setup generates the **bus key pairs** (ECDSA P-256) if absent and prints the distribution
  instructions — used in Phase 6.
- Setup generates the **master key** if absent (`BRIC_MASTER_KEY_FILE`, normally `/root/.bric/master.key`, mode 0400) — Phase 7.

Turn ON the escrow policy (deliberate explicit step, on CLUSTER):

    sqlite3 "$BRIC_DB" "UPDATE config SET value='1' WHERE key='require_user_escrow';"
    sqlite3 "$BRIC_DB" "SELECT value FROM config WHERE key='require_user_escrow';"   # -> 1

Verify the tape inventory against physical reality (TAPE):

    sqlite3 "$BRIC_TAPE_DB" "SELECT volumetag,role,pair_number FROM tapes ORDER BY volumetag;"
    mtx -f /dev/sg4 status          # compare: every barcode present, even=PRIMARY odd=BACKUP

**GATE 5**: dry-run output matches your intent; catalogs exist; inventory matches the physical
labels INCLUDING parity; `require_user_escrow=1`.

---

## Phase 6 — Bus keys: distribute + enforce signing (BOTH)

Setup printed this; execute it literally. Each host gets **its own private + the peer's public**:

    CLUSTER keeps:  cluster_bus_ecdsa_p256.pem  +  tape_bus_ecdsa_p256.pub
    TAPE keeps:     tape_bus_ecdsa_p256.pem     +  cluster_bus_ecdsa_p256.pub

Copy the two .pub files across (scp is fine — they are public). Private keys never leave their
host. Then set in each host's /etc/bric/bric.conf:

    BRIC_BUS_SIGN_KEY=/path/to/<own>_bus_ecdsa_p256.pem
    BRIC_BUS_VERIFY_KEY=/path/to/<peer>_bus_ecdsa_p256.pub

Prove enforcement (TAPE): with keys configured, the daemon must start in MANDATORY mode; with
`BRIC_BUS_SIGN_KEY=` emptied on purpose it must REFUSE to start. Both behaviors are the ones
`run_require_signing.sh` validated in Phase 2.

**GATE 6**: daemon starts in MANDATORY mode; refuses unsigned when keys are removed.

---

## Phase 7 — Master key custody + root onboarding of real users (CLUSTER)

**Master key custody — before the first real backup:**

    stat -c '%U:%G %a %s %n' /root/.bric/master.key

Expected: root-owned, mode `400`, non-empty. Keep at least two protected offline copies. Never copy
it to an ordinary user's home, QNAP, tape server or tape.

**Onboard each real NSS/AD user as root.** This is the canonical production path:

    BRIC_CONFIG=/etc/bric/bric.conf \
    BRIC_MASTER_KEY_FILE=/root/.bric/master.key \
      /opt/bric2/cluster/scripts/bric-setup-user.sh --user vsz652 --strict-runtime-checks

The command is idempotent and performs the complete operation:

- resolves `vsz652` through `getent passwd`;
- creates `~vsz652/.bric` as the user (works with root-squashed UID-based homes);
- generates one 32-byte personal key, or recovers the existing one from escrow;
- installs `~vsz652/.bric/vsz652_user_key.txt` as `0600`, user-owned;
- writes `~vsz652/.bric/env.sh` with paths only;
- stores only authenticated master-wrapped escrow in `users.key_escrow`;
- refuses a home-key/escrow mismatch instead of rotating either copy;
- verifies that the user can write the QNAP bus and read the configured bus-signing keys.

No administrator plaintext handout is created by default. To produce one deliberately:

    /opt/bric2/cluster/scripts/bric-setup-user.sh \
      --user vsz652 --handout /root/.bric/handouts

Verify without printing secrets:

    stat -c '%U:%G %a %s %n' ~vsz652/.bric/vsz652_user_key.txt ~vsz652/.bric/env.sh
    sqlite3 "$BRIC_DB" "SELECT username, substr(key_escrow,1,3) FROM users WHERE username='vsz652';"

Expected: ownership `vsz652`, modes `600`, escrow prefix `v2:`. The user's normal session then uses:

    bric backup NAME PATH --wait

The wrapper reads `~/.bric/env.sh` itself; local and Slurm execution keep OpenSSL >=3 when already active, otherwise they auto-select a loadable compatible module.

**GATE 7**: master offline twice; user key present only in the user's home; v2 escrow present; rerunning
onboarding leaves the key unchanged; user runtime can reach QNAP and signing keys.

---

## Phase 8 — Hardware phase (TAPE; needs the MSL3040 answering)

1. **Preflight, read-only** — no tape is touched:

       BRIC_CONFIG=/etc/bric/bric.conf tape/bin/bric-library-preflight

   Must be green: device nodes, sg_inq (compare drive firmware — S2S1 vs S2SD is a WARN),
   clean sense (0x02/04/03 = STOP, call HPE), safe Linux st filemark/EOD options, full inventory,
   valid barcode inventory and drive mapping; project reservation checks only the complete onsite pairs needed by that project.

2. **Smoke test on ONE scratch pair** (WRITES real tape — uses a cartridge you can re-label):

       BRIC_CONFIG=/etc/bric/bric.conf BRIC_TAPE_BACKEND=real \
         test/run_real_tape_smoke.sh --vt <SCRATCH_BARCODE> --yes-write <SCRATCH_BARCODE>

   CAUTION: the FIRST load of a new LTO-9 cartridge can take up to **2 hours of media
   initialization. Do not interrupt it.** Details: docs/RUNBOOK_scratch_tape.md.

**GATE 8**: preflight green on real hardware; smoke round-trip SHA-identical on a scratch tape.

---

## Phase 9 — Acceptance on a sacrificial project (CLUSTER + TAPE)

Real pipeline, real tapes, data you can afford to lose (a few GB copied from Isilon):

    # TAPE: daemon under the real config
    BRIC_CONFIG=/etc/bric/bric.conf tape/bin/bric-tape-daemon --loop &

    # CLUSTER
    # The hardware preflight is local to brictape. After it is green there, the gate must skip
    # that one local-device check; OpenSSL/QNAP are still checked manually below.
    bric-run --skip-preflight backup --project accept_test --source /path/to/sacrificial/copy --wait
    bric status                                          # run must reach CLOSED
    bric-run --skip-preflight restore --project accept_test --dest /tmp/accept_restore
    diff -r /path/to/sacrificial/copy /tmp/accept_restore    # empty output

    # The archive claim itself — DR from tapes + user key ALONE (no catalogs, no QNAP):
    cluster/scripts/bric-dr-from-tapes.sh --project accept_test \
        --user-key-file ~vsz652/.bric/vsz652_user_key.txt --dest /tmp/accept_dr
    diff -r /path/to/sacrificial/copy /tmp/accept_dr         # empty output

    # Break-glass drill (admin path, master key only):
    cluster/scripts/bric-dr-from-tapes.sh --project accept_test \
        --master-key-file /root/.bric/master.key --dest /tmp/accept_bg
    diff -r /path/to/sacrificial/copy /tmp/accept_bg         # empty output

**Bus drain check — do NOT skip this one.** The daemon frees each blob from the QNAP as soon as
both copies are VERIFIED. That free is deliberately non-fatal, so a permission problem on a bus
shared by two hosts would leave ~segment-sized blobs behind. It is no longer silent (the daemon
logs `WARNING: could not free bus blob ...`), but verify it with your own eyes at least once,
during a run with several chunks:

    watch -n2 'ls /mnt/data/bric/archive/accept_test/<run_id>/*.enc 2>/dev/null | wc -l; \
               du -sh /mnt/data/bric/archive/accept_test'
    grep -i "could not free bus blob" /var/log/bric/daemon.log     # must stay empty

Blobs must APPEAR and then DISAPPEAR as chunks reach tape (the bus holds ~max_inflight of them,
not all of them). If the count only grows while the log says DONE, stop: the staging area will
fill up. With 128 GB segments the remaining headroom is consumed in 128 GB quanta, so stop before the free-space margin is exhausted.

Also check the notifications arrived: `grep accept_test /var/log/bric/events.log` and the
BACKUP_DONE mail to vsz652@ku.dk.

**GATE 9**: all three diffs empty; bus drains (blob count falls back); no free warnings; events
logged; mail received.

---

## Phase 10 — Go-live

- [ ] First 1–2 real user projects, supervised, one at a time.
- [ ] Watch `/var/log/bric/events.log` (7 pipe-separated fields — greppable; a root cron digest
      can mail a daily summary).
- [ ] Keep the standing safety rules: any network/sysctl change on brictape only with an armed
      `at`-rollback; the QNAP point-to-point link (192.168.1.x) is the out-of-band recovery path.
- [ ] Periodic re-verify of written tapes is available (`REVERIFY` audit trail) — schedule it
      monthly once a few tapes are FULL.
- [ ] Print docs/RECOVERY_HANDBOOK.html and store a copy WITH the offsite key material.

## Appendix — If something fails
- Any suite failure (Phase 2): stop; the runner prints the per-test log path.
- Preflight FAIL (Phase 8): the report names the component and the operator action; sense
  0x02/04/03 → HPE case, do not force.
- Setup mistakes: re-run setup — it is idempotent and backs up catalogs first; nothing it does
  destroys data.
- A backup stuck/failed: `bric status`; the run's reservation is released on abort
  (job-lifecycle path); tapes written by an abandoned run stay append-only and harmless.
- TOTAL loss rehearsal any time you want confidence: Phase 4 (VTL) reproduces the whole flow,
  including DR, with zero hardware.
