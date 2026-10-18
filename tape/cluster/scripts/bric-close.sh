#!/bin/bash
# bric-close: seal a project run. It runs as the archive owner and therefore uses ONLY the owner's
# personal key. The institution master key never enters a user job.
# On tape it writes:
#   1. catalog_project.enc   - project catalog, encrypted with the USER key
#   2. user_key_escrow.v1    - the already master-wrapped/authenticated user key (ciphertext only)
#   3. recovery scripts/schema - plaintext, non-secret
# Admin break-glass recovery unwraps user_key_escrow.v1 with the offline master, then opens the same
# project catalog. Legacy tapes containing catalog_system.enc remain supported by the DR script.
set -euo pipefail
IFS=$'\n\t'
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
. "$HERE/lib_common.sh"
bric_log_process_start "bric-close" "$@"
require_cmds sqlite3 openssl awk
enforce_bus_signing   # refuse to run unsigned when config require_bus_signing=1

RUN_ID=""
while [ "$#" -gt 0 ]; do case "$1" in --run) RUN_ID="${2:-}"; shift 2;; *) die "unknown option: $1";; esac; done
[ -n "$RUN_ID" ] || die "usage: bric-close --run RUN_ID"

IFS='|' read -r PROJECT OWNER <<EOF
$(sqlc "SELECT project_name,owner FROM runs WHERE run_id='$(sql_quote "$RUN_ID")';")
EOF
[ -n "$PROJECT" ] || die "run not found: $RUN_ID"
RUN_DIR="$(qnap_run_dir "$PROJECT" "$RUN_ID")"
# Review 34 additive schema is part of the encrypted project catalog. This also handles a run
# started under 32B4A and closed after upgrade, before any SELECT * style catalog copy occurs.
bric_ensure_v34_cluster_schema

# Sensitive close work MUST stay on local cluster storage.  The QNAP bus is shared with the
# keyless tape server and may be readable by other archive users; only the final encrypted catalogs
# and the intentionally-plaintext recovery kit are published there.
LOCAL_TMP_ROOT="${BRIC_LOCAL_TMPDIR:-/tmp}"
[ -d "$LOCAL_TMP_ROOT" ] && [ -w "$LOCAL_TMP_ROOT" ] || die "local temp root is not writable: $LOCAL_TMP_ROOT"
LOCAL_TMP="$(mktemp -d "$LOCAL_TMP_ROOT/bric-close.XXXXXX")"
_close_exit(){ local rc=$?; trap - EXIT; rm -rf "$LOCAL_TMP"; bric_log_process_end "$rc"; exit "$rc"; }
trap _close_exit EXIT

ANS="$(marker_wait "$RUN_DIR" run.CLOSE_PLACEMENT "" "${BRIC_CLOSE_TIMEOUT:-3600}")" || die "timed out waiting for placement"
marker_verify "$RUN_DIR" run.CLOSE_PLACEMENT || die "placement failed signature verification (forged?)"
[ "$(marker_field run_id "$RUN_DIR/run.CLOSE_PLACEMENT")" = "$RUN_ID" ] || die "placement not bound to this run"
PLACEMENT="$(marker_read "$RUN_DIR" run.CLOSE_PLACEMENT)"
VOLTAGS="$(printf '%s' "$PLACEMENT" | awk -F= '/^volumetags=/{print $2}' | tr ',' ' ')"

# decision (b): record the project's tapes on the cluster (read-only comfort; tape server stays authoritative)
for vt in $VOLTAGS; do
    [ -n "$vt" ] || continue
    sql "INSERT OR IGNORE INTO project_tapes (project_name,volumetag) VALUES ('$(sql_quote "$PROJECT")','$(sql_quote "$vt")');"
done

CLOSE="$RUN_DIR/close"; mkdir -p "$CLOSE"
UKF="$(user_key_file "$OWNER")"; [ -f "$UKF" ] || die "user key not found for $OWNER: $UKF"
derive_keys "$(cat "$UKF")"
ENCPASS="$LOCAL_TMP/.encpass"; printf '%s' "$ENC_KEY" > "$ENCPASS"; chmod 600 "$ENCPASS"

# The escrow is already encrypted+authenticated with the institution master key in the cluster DB.
# Publishing that ciphertext on tape does not expose the user key, but lets an administrator recover
# from tapes + master without making the master readable by this user-owned close job.
ESCROW="$(sql "SELECT key_escrow FROM users WHERE username='$(sql_quote "$OWNER")';")"
if [ -z "$ESCROW" ] && [ "$(cfg require_user_escrow 2>/dev/null)" = 1 ]; then
    die "owner '$OWNER' has no institutional key escrow; refusing close"
fi

# --- level 1: project catalog (user-key encrypted) ---
PDB="$LOCAL_TMP/catalog_project.db"; rm -f "$PDB"
sqlite3 "$PDB" < "${BRIC_SQL_INIT:-$HERE/../sql/cluster_init.sql}" >/dev/null
SRC_RUN_COLS="$(sqlite3 -batch "$BRIC_DB" "SELECT group_concat(name,'|') FROM pragma_table_info('runs');")"
DST_RUN_COLS="$(sqlite3 -batch "$PDB" "SELECT group_concat(name,'|') FROM pragma_table_info('runs');")"
[ -n "$SRC_RUN_COLS" ] && [ "$SRC_RUN_COLS" = "$DST_RUN_COLS" ]     || die "runs schema mismatch during close; refusing to publish recovery catalog (src=$SRC_RUN_COLS dst=$DST_RUN_COLS)"
SRC_FILE_COLS="$(sqlite3 -batch "$BRIC_DB" "SELECT group_concat(name,'|') FROM pragma_table_info('files');")"
DST_FILE_COLS="$(sqlite3 -batch "$PDB" "SELECT group_concat(name,'|') FROM pragma_table_info('files');")"
[ -n "$SRC_FILE_COLS" ] && [ "$SRC_FILE_COLS" = "$DST_FILE_COLS" ] || die "files schema mismatch during close; refusing to publish recovery catalog"
sqlite3 "$PDB" "ATTACH '$BRIC_DB' AS src;
  INSERT OR REPLACE INTO projects SELECT * FROM src.projects WHERE project_name='$(sql_quote "$PROJECT")';
  INSERT OR REPLACE INTO runs(run_id,project_name,kind,source_path,submitted_by,owner,slurm_array_job,n_chunks,total_bytes,status,error,requested_at,closed_at,source_canonical_path,logical_root)
    SELECT run_id,project_name,kind,source_path,submitted_by,owner,slurm_array_job,n_chunks,total_bytes,status,error,requested_at,closed_at,source_canonical_path,logical_root
    FROM src.runs WHERE project_name='$(sql_quote "$PROJECT")';
  INSERT OR REPLACE INTO chunks   SELECT * FROM src.chunks   WHERE run_id IN (SELECT run_id FROM src.runs WHERE project_name='$(sql_quote "$PROJECT")');
  INSERT OR REPLACE INTO files    SELECT * FROM src.files    WHERE run_id IN (SELECT run_id FROM src.runs WHERE project_name='$(sql_quote "$PROJECT")');
  INSERT OR REPLACE INTO run_exclusions SELECT * FROM src.run_exclusions WHERE run_id IN (SELECT run_id FROM src.runs WHERE project_name='$(sql_quote "$PROJECT")');
  INSERT OR REPLACE INTO run_source_scan SELECT * FROM src.run_source_scan WHERE run_id IN (SELECT run_id FROM src.runs WHERE project_name='$(sql_quote "$PROJECT")');
  INSERT OR REPLACE INTO run_source_semantics SELECT * FROM src.run_source_semantics WHERE run_id IN (SELECT run_id FROM src.runs WHERE project_name='$(sql_quote "$PROJECT")');
  INSERT OR REPLACE INTO run_source_changes SELECT * FROM src.run_source_changes WHERE run_id IN (SELECT run_id FROM src.runs WHERE project_name='$(sql_quote "$PROJECT")');
  INSERT OR REPLACE INTO project_tapes SELECT * FROM src.project_tapes WHERE project_name='$(sql_quote "$PROJECT")';"
# embed placement so DR knows chunk -> tape/file without the tape server
sqlite3 "$PDB" "CREATE TABLE IF NOT EXISTS placement(run_id TEXT,chunk_no INT,copy_role TEXT,volumetag TEXT,file_number INT);"
printf '%s\n' "$PLACEMENT" | awk -F';' '/^chunk=/{c=r=v=f="";for(i=1;i<=NF;i++){split($i,a,"=");if(a[1]=="chunk")c=a[2];if(a[1]=="role")r=a[2];if(a[1]=="vt")v=a[2];if(a[1]=="file")f=a[2]}print c"|"r"|"v"|"f}' \
  | while IFS='|' read -r c r v f; do [ -n "$c" ] && sqlite3 "$PDB" "INSERT INTO placement VALUES ('$(sql_quote "$RUN_ID")',$c,'$r','$v',$f);"; done
sqlite3 "$PDB" .dump > "$LOCAL_TMP/catalog_project.sql"; rm -f "$PDB"
openssl enc -aes-256-cbc -pbkdf2 -iter 10000 -salt -pass file:"$ENCPASS" -in "$LOCAL_TMP/catalog_project.sql" -out "$CLOSE/catalog_project.enc"
rm -f "$LOCAL_TMP/catalog_project.sql"

# --- level 2: project-bound authenticated escrow (master-wrapped ciphertext, never plaintext) ---
if [ -n "$ESCROW" ]; then
    ESCROW_B64="$(printf '%s' "$ESCROW" | openssl base64 -A)"
    cat > "$CLOSE/user_key_escrow.v1" <<EOF_ESCROW
BRIC-USER-ESCROW-V1
project=$PROJECT
owner=$OWNER
escrow_b64=$ESCROW_B64
EOF_ESCROW
    chmod 644 "$CLOSE/user_key_escrow.v1"
fi
rm -f "$ENCPASS"

# --- level 3: plaintext recovery kit ---
cp -f "${BRIC_SQL_INIT:-$HERE/../sql/cluster_init.sql}" "$CLOSE/schema.sql"
cat > "$CLOSE/README_RECOVERY.txt" <<EOF
BRIC-FORMAT-V1
BRIC Archive 2.0 - on-tape recovery kit for project: $PROJECT
Persistent format generation: 1. Markers are BRIC-MARKER-V1; the tape index header is
"# BRIC tape TOC v1". Blobs and catalogs are aes-256-cbc / pbkdf2 / iter 10000 (parameters PINNED and
also recorded in the catalog), so a future BRIC-FORMAT-V2 can change them while old tapes still open.
This tape holds opaque encrypted chunk blobs plus the project recovery artifacts:
  catalog_project.enc  : this project's catalog (your data map), encrypted with YOUR user key.
                         Review 31 catalogs include run_exclusions (intentional omissions) and
                         run_source_scan (pre-reservation source size/progress denominator),
                         run_source_semantics (sparse/allocation and consistency policy), and
                         run_source_changes (recorded FILE_CHANGED_DURING_READ diagnostics).
  user_key_escrow.v1   : YOUR key already wrapped/authenticated with the institution master key.
                         It is ciphertext, not a usable data-decryption key.
  schema.sql           : the catalog schema, to rebuild a database from the .sql dump.
The master key is never used by a user job and never written to tape. An administrator can unwrap
user_key_escrow.v1 with the offline master and then decrypt catalog_project.enc. Legacy BRIC tapes
may instead contain catalog_system.enc; the DR script remains backward-compatible with them.
Chunk payloads: TAR_PART is an independent tar archive emitted by the one-pass tar stream; LARGE_FILE_CHUNK is a raw contiguous piece of one oversized file. Each payload is encrypted with openssl-compatible aes-256-cbc / pbkdf2 / iter 10000
Crypto parameters — PINNED so recovery is independent of any OpenSSL default changing (OpenSSL 1.1.1+/3.x):
  cipher   = aes-256-cbc (CBC; integrity provided externally by the HMAC below, Encrypt-then-MAC)
  kdf      = pbkdf2, iter = 10000 (EXPLICIT, equals the historical OpenSSL default so old blobs still open)
  salt     = embedded, 8 random bytes in the 'Salted__' header (so no salt needs to be recorded anywhere)
  digest   = sha256 (the enc app's pbkdf2 prf and our key derivation both use SHA-256)
  MAC      = HMAC-SHA256(ciphertext), verified BEFORE decrypt; expected value in chunks.payload_hmac
  keys     = ENC_PASS = sha256(USER_KEY + ":encryption"),  HMAC_KEY = sha256(USER_KEY + ":authentication")
Derive your two keys from your USER KEY (literal suffixes, no spaces):
  ENC_PASS=\$(printf '%s:encryption'     "\$USER_KEY" | sha256sum | awk '{print \$1}')
  HMAC_KEY=\$(printf '%s:authentication' "\$USER_KEY" | sha256sum | awk '{print \$1}')
AUTHENTICATE BEFORE DECRYPT (Encrypt-then-MAC). The expected per-chunk HMAC is in the project
catalog (chunks.payload_hmac). Verify, then decrypt:
  test "\$(openssl dgst -sha256 -hmac "\$HMAC_KEY" chunk_0001.enc | awk '{print \$NF}')" = "\$EXPECT_HMAC"
  printf '%s' "\$ENC_PASS" > pass.txt && chmod 600 pass.txt
  openssl enc -d -aes-256-cbc -pbkdf2 -iter 10000 -pass file:pass.txt -in catalog_project.enc -out catalog_project.sql
  openssl enc -d -aes-256-cbc -pbkdf2 -iter 10000 -pass file:pass.txt -in chunk_0001.enc | tar -x
See restore_from_tape.sh for the scripted version. Your data does not depend on BRIC continuing to exist.
EOF
cat > "$CLOSE/restore_from_tape.sh" <<'EOF'
#!/bin/bash
# Minimal standalone restore of one decrypted chunk blob, given your USER KEY.
# Authenticated-by-default: if an expected HMAC is available it is verified BEFORE decrypting, so a
# tampered/forged blob is rejected instead of being fed to tar. Provide it via EXPECT_HMAC=<hex>
# (read payload_hmac for this chunk from catalog_project: 'SELECT payload_hmac FROM chunks WHERE
# run_id=... AND chunk_no=...'). Without it the script still works but prints a clear warning.
set -euo pipefail
BLOB="${1:?usage: [EXPECT_HMAC=hex] restore_from_tape.sh chunk_XXXX.enc DEST_DIR}"; DEST="${2:?dest dir}"
: "${USER_KEY:?export USER_KEY=...}"
ENC_PASS=$(printf '%s:encryption'     "$USER_KEY" | sha256sum | awk '{print $1}')
HMAC_KEY=$(printf '%s:authentication' "$USER_KEY" | sha256sum | awk '{print $1}')
if [ -n "${EXPECT_HMAC:-}" ]; then
  GOT=$(openssl dgst -sha256 -hmac "$HMAC_KEY" "$BLOB" | awk '{print $NF}')
  [ "$GOT" = "$EXPECT_HMAC" ] || { echo "HMAC MISMATCH on $BLOB — refusing to decrypt (tampered/forged?)" >&2; exit 1; }
  echo "HMAC verified for $BLOB" >&2
else
  echo "WARNING: EXPECT_HMAC not set — decrypting WITHOUT authentication. Set EXPECT_HMAC=<payload_hmac> to verify." >&2
fi
printf '%s' "$ENC_PASS" > .pass && chmod 600 .pass
mkdir -p "$DEST"
# Never pass -P: GNU tar strips leading '/' and refuses '..' members (no path traversal).
echo "WARNING: standalone recovery restores payload/mode/mtime only; ACL/xattr fidelity requires the BRIC restore tooling." >&2
openssl enc -d -aes-256-cbc -pbkdf2 -iter 10000 -pass file:.pass -in "$BLOB" | tar -C "$DEST" -xp --no-same-owner --delay-directory-restore --no-acls --no-xattrs -f -
rm -f .pass
echo "restored $BLOB -> $DEST"
EOF
chmod +x "$CLOSE/restore_from_tape.sh"

# Build a signed manifest of EXACTLY the close artifacts (filename|kind|sha256). The tape server must
# append all of them and refuse to seal if any is missing or its content does not match this manifest.
MANIFEST=""
SPECS=("catalog_project.enc:CATALOG" "restore_from_tape.sh:SCRIPT" "README_RECOVERY.txt:SCRIPT" "schema.sql:SCRIPT")
[ -z "$ESCROW" ] || SPECS+=("user_key_escrow.v1:ESCROW")
for spec in "${SPECS[@]}"; do
    f="${spec%%:*}"; kind="${spec##*:}"
    [ -f "$CLOSE/$f" ] || die "close artifact missing before handoff: $f"
    ash="$(sha256sum "$CLOSE/$f" | awk '{print $1}')"
    MANIFEST="${MANIFEST}artifact|$f|$kind|$ash
"
done
# Signed + bound to this run/project. The daemon verifies the signature, checks run_id/project match
# the bus path, then enforces the manifest before sealing.
marker_set_signed "$RUN_DIR" run.CLOSE_CATALOGS "run_id=$RUN_ID
project=$PROJECT
${MANIFEST}"
log "catalogs built and encrypted; handed to tape server with signed artifact manifest"
marker_wait "$RUN_DIR" run.CLOSED "" "${BRIC_CLOSE_TIMEOUT:-3600}" >/dev/null || die "timed out waiting for tape server to seal"
marker_verify "$RUN_DIR" run.CLOSED || die "CLOSED failed signature verification (forged?)"
[ "$(marker_field run_id "$RUN_DIR/run.CLOSED")" = "$RUN_ID" ] || die "CLOSED not bound to this run"
sql "UPDATE runs SET status='CLOSED', closed_at=datetime('now') WHERE run_id='$(sql_quote "$RUN_ID")';"
run_status_event "$RUN_ID" "$PROJECT" CLOSED "both copies, artifacts, TOCs and media-release barriers complete"
bric_notify BACKUP_DONE "$OWNER" "$RUN_ID" "project=$PROJECT run CLOSED: all chunks on PRIMARY+BACKUP tape, catalogs and recovery kit sealed"
audit RUN_CLOSED "$RUN_ID" OK "project=$PROJECT tapes=$VOLTAGS"
log "run $RUN_ID CLOSED; project '$PROJECT' lives on: $VOLTAGS"
bus_cleanup_run_dir "$PROJECT" "$RUN_ID" CLOSED || warn_log "run CLOSED but QNAP bus cleanup was deferred: $RUN_DIR"
