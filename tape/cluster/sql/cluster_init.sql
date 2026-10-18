-- BRIC Archive 2.0 - CLUSTER catalog (authoritative for the DATA phase).
-- Lives on the SLURM cluster. Holds projects, runs, chunks, the per-file map and plaintext
-- checksums (computed during tar, NEVER written to the QNAP), and a convenience copy of the
-- VolumeTags a project lives on (populated at close; the tape server stays authoritative).
PRAGMA journal_mode=WAL;
PRAGMA foreign_keys=ON;

CREATE TABLE IF NOT EXISTS config (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

-- Key escrow: each designated archive user's secret key, wrapped and authenticated with the
-- institution MASTER key. Normal archive jobs read only the user's own ~/.bric key and never need the
-- master. At close, the already-wrapped escrow ciphertext is copied to each project tape as
-- user_key_escrow.v1, enabling tapes+master break-glass recovery without exposing the master to Slurm.
-- Legacy tapes may contain catalog_system.enc and remain readable by the DR script.
CREATE TABLE IF NOT EXISTS users (
    username    TEXT PRIMARY KEY,
    key_escrow  TEXT NOT NULL,                 -- base64(openssl enc -aes-256-cbc -pbkdf2, master key)
    created_at  TEXT DEFAULT (datetime('now')),
    updated_at  TEXT DEFAULT (datetime('now'))
);

CREATE TABLE IF NOT EXISTS projects (
    project_name TEXT PRIMARY KEY,
    owner        TEXT NOT NULL,
    exclusivity  TEXT NOT NULL DEFAULT 'project',   -- project | owner | shared
    created_at   TEXT DEFAULT (datetime('now')),
    status       TEXT DEFAULT 'ACTIVE'              -- ACTIVE | RETIRED
);

-- One run = one `bric backup` invocation. The first run for a project is the initial archive;
-- later runs of the same project are APPENDs (each is a self-contained increment / snapshot).
CREATE TABLE IF NOT EXISTS runs (
    run_id          TEXT PRIMARY KEY,               -- <project>__<UTCstamp>__<counter>
    project_name    TEXT NOT NULL,
    kind            TEXT NOT NULL DEFAULT 'ARCHIVE',-- ARCHIVE | APPEND | RESTORE
    source_path     TEXT,
    submitted_by    TEXT NOT NULL,
    owner           TEXT NOT NULL,
    slurm_array_job TEXT,
    n_chunks        INTEGER DEFAULT 0,
    total_bytes     INTEGER DEFAULT 0,
    status          TEXT DEFAULT 'PLANNING',        -- PLANNING|RESERVED|DENIED|PRODUCING|DRAINING|CLOSING|CLOSED|FAILED|CANCELLED
    error           TEXT,
    requested_at    TEXT DEFAULT (datetime('now')),
    closed_at       TEXT,
    source_canonical_path TEXT,
    logical_root          TEXT,
    FOREIGN KEY (project_name) REFERENCES projects(project_name)
);

-- One chunk = one segment = one SLURM array task = one `.enc` blob on the QNAP.
CREATE TABLE IF NOT EXISTS chunks (
    run_id         TEXT NOT NULL,
    chunk_no       INTEGER NOT NULL,
    type           TEXT NOT NULL DEFAULT 'TAR_PART', -- TAR_PART | LARGE_FILE_CHUNK
    size_bytes     INTEGER DEFAULT 0,
    payload_sha256 TEXT,
    payload_hmac   TEXT,
    state          TEXT DEFAULT 'PLANNED',           -- PLANNED|PRODUCED|READY|CLAIMED|DONE|ERROR
    qnap_path      TEXT,
    -- LARGE_FILE_CHUNK only:
    big_rel_path   TEXT,
    chunk_index    INTEGER,
    total_chunks   INTEGER,
    offset_bytes   INTEGER,
    error          TEXT,
    updated_at     TEXT DEFAULT (datetime('now')),
    PRIMARY KEY (run_id, chunk_no),
    FOREIGN KEY (run_id) REFERENCES runs(run_id)
);

-- The per-file map + PLAINTEXT checksums. This is what makes single-file restore possible.
-- It stays on the cluster only and is never copied to the world-readable QNAP.
CREATE TABLE IF NOT EXISTS files (
    run_id       TEXT NOT NULL,
    rel_path     TEXT NOT NULL,
    size_bytes   INTEGER NOT NULL,
    mtime        INTEGER,               -- archived mtime; retained for legacy LARGE_FILE_CHUNK recovery.
                                        -- The producer re-stats before AND after tar/dd and ABORTS on
                                        -- drift: a source changing between plan and production would
                                        -- otherwise land on tape as a silent MIX of versions, detected
                                        -- only at restore. (Quiescence guard; see README assumptions.)
    sha256_plain TEXT NOT NULL,            -- '' for non-regular entries (dirs, symlinks)
    chunk_no     INTEGER NOT NULL,        -- which chunk this file (or its first piece) is in
    member_index INTEGER DEFAULT 0,       -- position within the chunk's tar (0-based)
    entry_type   TEXT NOT NULL DEFAULT 'F', -- F=regular file, L=symlink, D=directory
    mode         INTEGER,               -- Review 34: source permission bits for regular files; NULL on legacy rows.
    metadata_b64 TEXT NOT NULL DEFAULT '', -- Review 34: v1 base64 envelope of selected ACL/xattrs for LARGE_FILE_CHUNK.
    PRIMARY KEY (run_id, rel_path),
    FOREIGN KEY (run_id) REFERENCES runs(run_id)
);

-- Mirror of the reservation the tape server granted for this run.
CREATE TABLE IF NOT EXISTS reservation (
    run_id       TEXT PRIMARY KEY,
    project_name TEXT NOT NULL,
    requested_tb REAL,
    n_pairs      INTEGER,
    state        TEXT DEFAULT 'REQUESTED', -- REQUESTED|GRANTED|DENIED|RELEASED
    granted_at   TEXT,
    heartbeat_at TEXT,
    FOREIGN KEY (run_id) REFERENCES runs(run_id)
);

-- Convenience copy (decision (b)): which VolumeTags a project lives on. Populated at close.
-- The tape server remains authoritative; this is read-only comfort for `bric list --long`.
CREATE TABLE IF NOT EXISTS project_tapes (
    project_name TEXT NOT NULL,
    volumetag    TEXT NOT NULL,
    PRIMARY KEY (project_name, volumetag)
);

-- Append-only audit trail of user-facing actions (who did what, when, with what result).
CREATE TABLE IF NOT EXISTS audit_log (
    id     INTEGER PRIMARY KEY AUTOINCREMENT,
    ts     TEXT DEFAULT (datetime('now')),
    actor  TEXT,
    action TEXT NOT NULL,   -- RUN_REQUESTED|RESERVED|DENIED|RUN_CLOSED|RESTORE_REQUESTED|RESTORE_DONE|...
    object TEXT,            -- run_id / project / file
    result TEXT,            -- OK|FAIL|...
    detail TEXT
);
CREATE INDEX IF NOT EXISTS idx_audit_ts ON audit_log(ts);

CREATE INDEX IF NOT EXISTS idx_runs_project ON runs(project_name);
CREATE INDEX IF NOT EXISTS idx_runs_owner   ON runs(owner);
CREATE INDEX IF NOT EXISTS idx_chunks_state ON chunks(state);
CREATE INDEX IF NOT EXISTS idx_files_chunk  ON files(run_id, chunk_no);

-- Review 31: explicit, auditable omissions and the source-scan denominator used for progress/ETA.
-- Exclusions are exact relative paths/subtrees declared by the user before reservation; they are copied
-- into the encrypted project catalog so future DR can distinguish intentional scope from missing data.
CREATE TABLE IF NOT EXISTS run_exclusions (
    run_id       TEXT NOT NULL,
    ordinal      INTEGER NOT NULL,
    rel_path     TEXT NOT NULL,
    reason       TEXT NOT NULL DEFAULT 'user-declared',
    declared_at  TEXT DEFAULT (datetime('now')),
    PRIMARY KEY (run_id, ordinal),
    UNIQUE (run_id, rel_path),
    FOREIGN KEY (run_id) REFERENCES runs(run_id)
);

CREATE TABLE IF NOT EXISTS run_source_scan (
    run_id          TEXT PRIMARY KEY,
    regular_files   INTEGER NOT NULL DEFAULT 0,
    logical_bytes   INTEGER NOT NULL DEFAULT 0,
    allocated_bytes INTEGER NOT NULL DEFAULT 0,
    exclusion_count INTEGER NOT NULL DEFAULT 0,
    scanner_uid     INTEGER,
    scanned_at      TEXT DEFAULT (datetime('now')),
    FOREIGN KEY (run_id) REFERENCES runs(run_id)
);

-- Review 31B: source-consistency semantics are explicit. GNU PAX sparse maps preserve byte content
-- efficiently, but allocation topology is not promised on filesystems/protocols that do not expose it.
CREATE TABLE IF NOT EXISTS run_source_semantics (
    run_id                   TEXT PRIMARY KEY,
    sparse_map_method        TEXT NOT NULL DEFAULT 'gnu-pax-0.1-map',
    allocation_topology      TEXT NOT NULL DEFAULT 'not-guaranteed',
    restore_allocation_effect TEXT NOT NULL DEFAULT 'zero-ranges-may-restore-as-holes',
    source_change_policy     TEXT NOT NULL DEFAULT 'strict',
    source_consistency       TEXT NOT NULL DEFAULT 'pending',
    source_changed_count     INTEGER NOT NULL DEFAULT 0,
    tar_exit_code            INTEGER,
    updated_at               TEXT DEFAULT (datetime('now')),
    FOREIGN KEY (run_id) REFERENCES runs(run_id)
);

CREATE TABLE IF NOT EXISTS run_source_changes (
    run_id          TEXT NOT NULL,
    ordinal         INTEGER NOT NULL,
    kind            TEXT NOT NULL DEFAULT 'FILE_CHANGED_DURING_READ',
    path_text       TEXT NOT NULL,
    path_encoding   TEXT NOT NULL DEFAULT 'gnu-tar-escape',
    diagnostic      TEXT NOT NULL,
    recorded_at     TEXT DEFAULT (datetime('now')),
    PRIMARY KEY (run_id, ordinal),
    FOREIGN KEY (run_id) REFERENCES runs(run_id)
);

INSERT OR IGNORE INTO config (key,value) VALUES
-- Chunk target is a restore-latency bound as well as a packing quantum. A chunk never spans tapes.
-- 128 GB decimal caps random-restore read amplification and reduces worst-case tail waste while
-- remaining large enough for streaming LTO throughput. Decimal GB matches LTO capacity ratings.
('segment_target_bytes', '128000000000'),    -- 128 GB decimal chunk target (restore-latency bounded)
('compression',          'none'),            -- genomic data already compressed; ciphertext incompressible
('qnap_budget_bytes',    '101177331187712'), -- ~92 TB cap on total bytes staged on the QNAP bus;
                                             -- enforced per-chunk in bric-chunk (the producer): before
                                             -- staging a blob it waits if the sum of chunk_*.enc files
                                             -- on the bus is at/over this. 0 disables. Paired with
                                             -- max_inflight_chunks (per-run blob-count window).
('max_inflight_chunks',  '8'),               -- sliding window: chunks staged on QNAP at once
('sparse_batch_target_bytes','4294967296'), -- 4 GiB GNU PAX sparse-map data target for batched TAR_PARTs
-- Network is the real bottleneck (Isilon read + NFS write to the QNAP). Only this many backups may be
-- in the PRODUCING phase (tar->QNAP) at once, system-wide. Others wait. Tape writing is a separate
-- stage (the daemon) and overlaps freely: a run that has finished producing moves to DRAINING and frees
-- the slot, so the next backup streams to the QNAP while the previous one's blobs drain to tape.
('source_change_policy', 'strict'),          -- strict=abort on file-changed; record=close with cataloged warnings
('max_concurrent_producers', '1'),             -- run-level concurrency; one run already has parallel internal workers
('stream_parallel_workers', '4'),              -- local single-run data workers (same project/run_id)
('stream_worker_chunk_bytes', '128000000000'), -- default per-worker target; clamped by segment_target_bytes
('tar_blocking_factor', '8192'),          -- 8192 x 512 B = 4 MiB GNU tar record; lowers syscall/pipe overhead
('tape_exclusivity',     'project'),         -- ONLY 'project' is implemented; 'owner'/'shared' are reserved
                                             -- for future work (the tape daemon refuses to start on them).
('require_user_escrow',  '0'),               -- 1 = refuse to plan a run unless the owner's key is escrowed
('require_bus_signing',  '0'),               -- 1 = refuse to operate unless bus signing+verify keys are configured
('reservation_overhead_pct', '2'),          -- extra % over plaintext to cover tar/openssl framing when reserving tape
('format_version',       '1'),               -- persistent on-disk/on-tape format generation (BRIC-FORMAT-V1):
                                             -- markers=BRIC-MARKER-V1, TOC="# BRIC tape TOC v1",
                                             -- blobs/catalogs=aes-256-cbc/pbkdf2/iter10000 (params pinned &
                                             -- recorded per chunk). Bump for a future V2 wire format.
('run_counter',          '0');
