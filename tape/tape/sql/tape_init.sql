-- BRIC Archive 2.0 - TAPE SERVER catalog (authoritative for the PHYSICAL phase).
-- Lives on the tape server. Holds the real library inventory (from mtx), reservations,
-- per-segment placement (VolumeTag + file number) and the verify state. NEVER holds a key:
-- the tape server only ever sees opaque ciphertext blobs.
PRAGMA journal_mode=WAL;

CREATE TABLE IF NOT EXISTS config (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

-- Real cartridges, populated by import_tape_inventory_from_mtx.sh. Barcodes are opaque VolumeTags;
-- role/pair are SYSTEM-assigned at registration (never derived from the label digits).
CREATE TABLE IF NOT EXISTS tapes (
    volumetag        TEXT PRIMARY KEY,
    slot             INTEGER,
    role             TEXT CHECK(role IN ('PRIMARY','BACKUP')) NOT NULL,
    pair_number      INTEGER NOT NULL,
    paired_volumetag TEXT,
    project_name     TEXT,                      -- exclusivity key when tape_exclusivity=project
    owner            TEXT,                      -- exclusivity key when tape_exclusivity=owner
    capacity_tb      REAL DEFAULT 18.0,
    used_tb          REAL DEFAULT 0.0,
    status           TEXT CHECK(status IN ('EMPTY','PARTIAL','FULL','RESERVED','RETIRED')) DEFAULT 'EMPTY',
    -- health / wear telemetry (LTO degrades; surface it before it bites)
    write_count      INTEGER DEFAULT 0,
    mount_count      INTEGER DEFAULT 0,
    write_errors     INTEGER DEFAULT 0,
    read_errors      INTEGER DEFAULT 0,
    last_verify      TEXT,
    health           TEXT CHECK(health IN ('OK','SUSPECT','BAD')) DEFAULT 'OK',
    last_scan        TEXT
);

-- A reservation pins one or more pairs to a run before the cluster produces a single chunk
-- (semantics B: no copy without tapes). Has a TTL/heartbeat so a dead run frees its tapes.
CREATE TABLE IF NOT EXISTS reservation (
    run_id       TEXT PRIMARY KEY,
    project_name TEXT NOT NULL,
    owner        TEXT NOT NULL,
    requested_tb REAL,
    pairs_csv    TEXT,                           -- pair_numbers reserved, e.g. "3,7"
    state        TEXT DEFAULT 'GRANTED',         -- GRANTED|RELEASED|EXPIRED
    granted_at   TEXT DEFAULT (datetime('now')),
    heartbeat_at TEXT DEFAULT (datetime('now')),
    ttl_hours    INTEGER DEFAULT 192             -- 8 days (archive partition MaxTime 7d + margin)
);

-- One physical copy of one chunk on one tape. state=WRITING is written BEFORE the tape write
-- (strategy A): if the daemon restarts and finds WRITING, it abandons the suspect tail and rewrites.
CREATE TABLE IF NOT EXISTS segments (
    seg_id         TEXT PRIMARY KEY,             -- <run>__c<chunk>__<PRIMARY|BACKUP>
    run_id         TEXT NOT NULL,
    project_name   TEXT NOT NULL,
    owner          TEXT NOT NULL,
    chunk_no       INTEGER NOT NULL,
    copy_role      TEXT CHECK(copy_role IN ('PRIMARY','BACKUP')) NOT NULL,
    volumetag      TEXT NOT NULL,
    file_number    INTEGER,
    payload_sha256 TEXT,
    size_bytes     INTEGER,
    state          TEXT DEFAULT 'WRITING',       -- WRITING|WRITTEN|VERIFIED|ABANDONED
    started_at     TEXT DEFAULT (datetime('now')),
    verified_at    TEXT
);

-- NOTE: the on-tape index mechanism is the cumulative plaintext TAPE_TOC appended at each close
-- (rows live in tape_artifacts with kind='TOC'; DR scans backwards from EOD and the latest valid
-- TOC wins). An earlier design had a separate versioned tape_index table; it was never written or
-- read by any code and has been removed (regola di estensione: dead schema is a removal candidate).

-- Non-chunk tape files written at project close (the encrypted catalogs, plaintext recovery
-- scripts, and the per-tape table-of-contents). Same WRITING-before-append / read-back-verify
-- discipline as segments (strategy A), so close is idempotent: a re-entry skips VERIFIED rows and
-- only ever appends a missing/abandoned artifact, never a duplicate.
CREATE TABLE IF NOT EXISTS tape_artifacts (
    artifact_id  TEXT PRIMARY KEY,            -- <run>__close__<volumetag>__<filename>
    run_id       TEXT NOT NULL,
    project_name TEXT NOT NULL,
    volumetag    TEXT NOT NULL,
    filename     TEXT NOT NULL,
    kind         TEXT,                        -- CATALOG | SCRIPT | TOC
    file_number  INTEGER,
    sha256       TEXT,
    state        TEXT DEFAULT 'WRITING',      -- WRITING|VERIFIED|ABANDONED
    started_at   TEXT DEFAULT (datetime('now')),
    verified_at  TEXT
);

CREATE INDEX IF NOT EXISTS idx_tapes_project ON tapes(project_name);
CREATE INDEX IF NOT EXISTS idx_tapes_owner   ON tapes(owner);
CREATE INDEX IF NOT EXISTS idx_tapes_status  ON tapes(status);
CREATE INDEX IF NOT EXISTS idx_seg_run       ON segments(run_id, chunk_no, copy_role);
CREATE INDEX IF NOT EXISTS idx_seg_tape      ON segments(volumetag);

-- Append-only audit trail of physical actions (reservations, writes, FULL, close, verify).
CREATE TABLE IF NOT EXISTS audit_log (
    id     INTEGER PRIMARY KEY AUTOINCREMENT,
    ts     TEXT DEFAULT (datetime('now')),
    actor  TEXT,
    action TEXT NOT NULL,   -- RESERVED|DENIED|SEGMENT_VERIFIED|VERIFY_FAIL|TAPE_FULL|CLOSED|REVERIFY|...
    object TEXT,            -- run_id / volumetag / segment
    result TEXT,            -- OK|FAIL
    detail TEXT
);
CREATE INDEX IF NOT EXISTS idx_audit_ts ON audit_log(ts);

INSERT OR IGNORE INTO config (key,value) VALUES
('tape_exclusivity',     'project'),   -- ONLY 'project' is implemented (reservations/placement/decommission
                                       -- are keyed on project_name). 'owner'/'shared' are reserved for future
                                       -- work; the daemon refuses to start on them.
-- Usable capacity = capacity_tb - tape_headroom_tb. Headroom reserves room for the per-tape close
-- catalogs+TOC, tape index records and end-of-media margin. With 128 GB chunks and 0.30 TB headroom,
-- roughly 138 chunks fit an 18 TB LTO-9 tape; a chunk never spans tapes.
('tape_headroom_tb',     '0.30'),
('chunk_target_bytes',   '128000000000'),  -- mirror of the cluster segment target (for the FULL test)
('parallel_drives',      '1'),         -- 1=serial fallback; 2=PRIMARY/BACKUP concurrent on first two BRIC_TAPE_DRIVES
('poll_seconds',         '10'),
('claim_ttl_hours',      '6'),         -- a CLAIMED chunk not DONE within this is reclaimed
('require_bus_signing',  '0'),         -- 1 = daemon refuses to start unless bus sign+verify keys are set
('primary_parity',       'even'),      -- even = pari onsite/PRIMARY, dispari offsite/BACKUP (BACKUP=PRIMARY+1)
('format_version',       '1'),         -- on-tape format generation (BRIC-FORMAT-V1); see cluster config
('changer_device',      '/dev/sch0');
