#!/bin/bash
# =====================================================================================================
# bric-setup.sh — bootstrap idempotente di BRIC Archive 2.0 (passi 2–3 del pre-flight).
#
# Inizializza i cataloghi reali, popola l'inventario nastri, registra gli utenti (con escrow), scrive
# la config e (opzionale) genera le chiavi del bus. È SICURO da rieseguire:
#   - lo schema usa CREATE TABLE IF NOT EXISTS (non distrugge dati);
#   - i nastri sono INSERT OR IGNORE (non sovrascrive mai una cartuccia già in uso);
#   - gli utenti sono ri-escrowati in modo idempotente;
#   - ogni catalogo già esistente viene COPIATO in un backup timestamped PRIMA di toccarlo.
# Non esegue alcun DROP. La config del blocco SITE è dichiarativa: rieseguendo, riallinea i valori.
#
# I due cataloghi vivono su host diversi (niente filesystem condiviso), quindi questo script si lancia
# UNA VOLTA PER LATO sull'host giusto:
#   sul cluster:      ./bric-setup.sh --role slurm
#   sul tape server:  ./bric-setup.sh --role tape
#   in staging mono-host (per la prova e2e): ./bric-setup.sh --role all
#
# Anteprima senza scrivere nulla:  ./bric-setup.sh --role all --dry-run
# =====================================================================================================

# ----------------------------------------------------------------------------------------------------
# Config file: setup obeys the SAME precedence as the runtime — environment > /etc/bric/bric.conf >
# the SITE defaults below. Loading happens here, BEFORE the SITE block, so a value in the config file
# fills any variable the environment left unset, and the `: "${VAR:=default}"` lines below only fill
# what remains. Without this, setup could provision paths (QNAP, DB, keys) DIVERGING from what the
# runtime later reads from the config file. The loader is the canonical one from lib_common (parse-
# only, BRIC_FAULT_* refused, BRIC_CONFIG=none disables); sourcing is guarded so a stripped tree
# (one side only) still works. Parse --role FIRST so tape setup loads tape defaults/fallback paths,
# not the Slurm defaults merely because the cluster tree happens to be present too.
ROLE="all"; DRY="no"
while [ "$#" -gt 0 ]; do case "$1" in
    --role) ROLE="${2:-}"; shift 2;;
    --dry-run) DRY="yes"; shift;;
    -h|--help) sed -n '2,33p' "$0"; exit 0;;
    *) echo "ERROR: unknown option: $1" >&2; exit 2;;
esac; done
case "$ROLE" in slurm|cluster|tape|all) ;; *) echo "ERROR: --role must be slurm|tape|all (cluster is accepted as a legacy alias)" >&2; exit 2;; esac
case "$ROLE" in
    cluster|slurm) export BRIC_ROLE=slurm;;
    tape)          export BRIC_ROLE=tape;;
    all)           export BRIC_ROLE=setup;;
esac
_SETUP_HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
case "$ROLE" in
    tape)
        if [ -f "$_SETUP_HERE/tape/scripts/lib_common.sh" ]; then . "$_SETUP_HERE/tape/scripts/lib_common.sh"
        elif [ -f "$_SETUP_HERE/cluster/scripts/lib_common.sh" ]; then . "$_SETUP_HERE/cluster/scripts/lib_common.sh"
        else echo "[setup] WARN: no lib_common found next to bric-setup.sh — /etc/bric/bric.conf will NOT be read" >&2; fi
        ;;
    *)
        if [ -f "$_SETUP_HERE/cluster/scripts/lib_common.sh" ]; then . "$_SETUP_HERE/cluster/scripts/lib_common.sh"
        elif [ -f "$_SETUP_HERE/tape/scripts/lib_common.sh" ]; then . "$_SETUP_HERE/tape/scripts/lib_common.sh"
        else echo "[setup] WARN: no lib_common found next to bric-setup.sh — /etc/bric/bric.conf will NOT be read" >&2; fi
        ;;
esac

# ----------------------------------------------------------------------------------------------------
# SITE DEFAULTS — ultimo strato, NON il posto dove si configura il sito
# ----------------------------------------------------------------------------------------------------
# Il sito si configura in /etc/bric/bric.conf (vedi bric.conf.example). Precedenza effettiva:
#
#     ambiente  >  /etc/bric/bric.conf  >  default di lib_common (sorgiata qui sopra)  >  queste righe
#
# Conseguenza pratica, dichiarata perché non è ovvia: le righe qui sotto sono `: "${VAR:=...}"`,
# quindi riempiono SOLO ciò che è ancora vuoto. Per le variabili che la lib_common già imposta
# (lato cluster: BRIC_HOME, BRIC_DB, BRIC_QNAP, BRIC_KEYS — lato tape: BRIC_TAPE_HOME, BRIC_TAPE_DB,
# BRIC_QNAP) editare QUI non produce alcun effetto: vince la lib. Restano effettive solo le variabili
# che la lib sorgiata non conosce (es. BRIC_TAPE_* quando si esegue con --role cluster/all, che
# sorgia la lib del cluster) e tutte le variabili solo-setup più sotto.
#
# => Per cambiare un percorso: /etc/bric/bric.conf. Non queste righe.
#    I default duplicati fra qui e lib_common DEVONO restare identici: la divergenza è silenziosa
#    (una delle due copie è irraggiungibile) ed è asserita da test/run_config_file.sh.
: "${BRIC_HOME:=/projects/bricsoftware/apps/bric2/cluster}"   # albero del CLUSTER
: "${BRIC_DB:=$BRIC_HOME/db/cluster_catalog.db}"
: "${BRIC_TAPE_HOME:=/opt/bric2/tape}"                        # albero del TAPE SERVER
: "${BRIC_TAPE_DB:=$BRIC_TAPE_HOME/db/tape_catalog.db}"
: "${BRIC_SYSTEMD_AUTO_START:=1}"
: "${BRIC_SYSTEMD_UNIT_DIR:=/etc/systemd/system}"
: "${BRIC_QNAP:=/mnt/data/bric}"                              # bus QNAP NFS (un solo path condiviso)
: "${BRIC_KEYS:=$HOME/.bric}"                                 # compatibility/default admin key root
: "${BRIC_ADMIN_KEYS:=$BRIC_KEYS}"                              # master + bus keys; never a user job path
: "${BRIC_MASTER_KEY_FILE:=}"                                   # optional exact master path

# Inventario nastri (lato tape). Preferisci un file coi BARCODE FISICI REALI, uno per riga, in ordine
# di slot. Le coppie sono numeri consecutivi (BACKUP = PRIMARY+1). Quale parità è PRIMARY/onsite è
# configurabile qui sotto. Se il file non è dato si generano per pattern SOLO a scopo di staging — in
# produzione DEVONO coincidere con le etichette fisiche reali.
: "${BRIC_BARCODES_FILE:=}"                                   # es. /etc/bric/barcodes.txt (40 righe)
: "${BRIC_TAPE_COUNT:=40}"                                    # usato solo se il file non è dato
: "${BRIC_BARCODE_START:=0}"                                  # numero del primo barcode generato (0 -> 000000L9)
: "${BRIC_BARCODE_FMT:=%06dL9}"                               # pattern di fallback: 000000L9..000039L9
: "${BRIC_TAPE_CAPACITY_TB:=18.0}"                            # LTO-9 nativo
: "${BRIC_PRIMARY_PARITY:=even}"                              # even = PARI onsite/PRIMARY, dispari BACKUP/offsite
                                                             #   (con barcode da 0: 000000=PRIMARY, 000001=BACKUP…)

# Utenti archiviazione designati (lato cluster). Spazio-separati, oppure un file (uno per riga).
# Lascia vuoto per saltare: poi registri con  cluster/scripts/bric-register-user --user NOME.
: "${BRIC_USERS:=}"                                           # es. "vsz652 abc123 def456"
: "${BRIC_USERS_FILE:=}"

# Parametri operativi (config dei cataloghi). I default riflettono le scelte già discusse.
: "${BRIC_CHUNK_TARGET_BYTES:=128000000000}"                 # 128 GB decimali (restore-latency bounded default)
: "${BRIC_MAX_CONCURRENT_PRODUCERS:=1}"                           # run-level slots; each local run has internal workers
: "${BRIC_STREAM_PARALLEL_WORKERS:=4}"                              # workers inside one project/run
: "${BRIC_STREAM_WORKER_CHUNK_BYTES:=128000000000}"                 # 128 GB per worker; clamped by segment target
: "${BRIC_TAR_BLOCKING_FACTOR:=8192}"                             # 8192*512 = 4 MiB GNU tar record
: "${BRIC_TAPE_EXCLUSIVITY:=project}"                         # project | owner | shared
: "${BRIC_TAPE_HEADROOM_TB:=0.30}"
: "${BRIC_PARALLEL_DRIVES:=2}"                               # two healthy drives: PRIMARY/BACKUP concurrent
: "${BRIC_POLL_SECONDS:=10}"
: "${BRIC_CLAIM_TTL_HOURS:=6}"
: "${BRIC_CHANGER:=/dev/sch0}"
: "${BRIC_TAPE_DRIVES:=0 1}"
: "${BRIC_DRIVE_LOCK_PREFIX:=/run/bric/drive.lock.}"
: "${BRIC_SLURM_OPENSSL_MODULE:=openssl/3.5.7}"               # preferred; runtime auto-falls back
: "${BRIC_MODULE_INIT:=/etc/profile.d/modules.sh}"
: "${BRIC_LOG_DIR:=/var/log/bric}"
: "${BRIC_LOG_GROUP:=bric}"
: "${BRIC_LOG_ADMIN_GROUP:=bric}"
: "${BRIC_USER_LOG_ROOT:=/var/log/bric/users}"
: "${BRIC_LOG_CAPTURE_STDIO:=1}"
: "${BRIC_REQUIRE_LOGGING:=1}"
: "${BRIC_REQUIRE_SIGNING:=1}"                               # 1 = firma del bus OBBLIGATORIA (consigliato)
: "${BRIC_COMMAND_LINK:=/usr/local/bin/bric}"                    # single user-facing command
: "${BRIC_ACTIVATE_USER_LINK:=/usr/local/sbin/bric-activate-user}" # root-only one-command onboarding
: "${BRIC_BUS_CLEANUP_LINK:=/usr/local/sbin/bric-bus-cleanup}"       # root-only transient-bus cleanup
: "${BRIC_UPDATE_LINK:=/usr/local/sbin/bric-update}"             # root-only in-place updater
: "${BRIC_TAPE_IMPORT_LINK:=/usr/local/sbin/bric-tape-import-inventory}" # root-only real changer inventory import
: "${BRIC_MAN_DIR:=/usr/local/share/man/man1}"                 # standard section-1 manual directory
: "${BRIC_GEN_BUS_KEYS:=yes}"                               # genera le coppie ECDSA P-256 se assenti
# ----------------------------------------------------------------------------------------------------

set -euo pipefail
IFS=$'\n\t'
umask 077
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"

# The role-specific common library above has now loaded config and selected the correct local/NFS
# logging defaults. Start durable setup logging before any catalog or key mutation.
bric_log_process_start "bric-setup-$ROLE" "role=$ROLE" "dry=$DRY"

c_red=$'\033[31m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_off=$'\033[0m'
say()  { printf '%s\n' "$*"; }
note() { printf '%s• %s%s\n' "$c_grn" "$*" "$c_off"; }
warn() { declare -F bric_event >/dev/null 2>&1 && bric_event WARN SETUP_WARNING "$*"; printf '%s! %s%s\n' "$c_yel" "$*" "$c_off"; }
die()  { declare -F bric_event >/dev/null 2>&1 && BRIC_LOG_RC=1 bric_event ERROR SETUP_FATAL "$*" || true; printf '%sERROR: %s%s\n' "$c_red" "$*" "$c_off" >&2; exit 1; }
run()  { if [ "$DRY" = yes ]; then printf '  [dry-run] %s\n' "$*"; else "$@"; fi; }
sqlite_do() { if [ "$DRY" = yes ]; then printf '  [dry-run] sqlite3 %s <<%d chars of SQL>>\n' "$1" "${#2}"; else sqlite3 -batch -cmd '.timeout 60000' "$1" "$2"; fi; }
sql_quote() { printf "%s" "$1" | sed "s/'/''/g"; }

# Tape pairing convention. BACKUP is always PRIMARY+1; which PARITY is PRIMARY/onsite is configurable.
# even -> pari onsite (000000=PRIMARY,000001=BACKUP,…); odd -> dispari onsite (legacy 1-based scheme).
case "${BRIC_PRIMARY_PARITY:-even}" in
    even) PRIMARY_PARITY=0;;
    odd)  PRIMARY_PARITY=1;;
    *) echo "ERROR: BRIC_PRIMARY_PARITY must be even|odd" >&2; exit 2;;
esac
vt_num()     { printf '%s' "$1" | grep -o '[0-9]\+' | head -1; }
vt_is_primary() { local n; n="$(vt_num "$1")"; [ -n "$n" ] && [ $(( 10#$n % 2 )) -eq "$PRIMARY_PARITY" ]; }
vt_sibling() {  # same prefix/width/suffix, step +1 if PRIMARY (BACKUP=PRIMARY+1), else -1
    local vt="$1" n w pre suf step sib
    n="$(vt_num "$vt")"; [ -n "$n" ] || { echo ""; return; }
    pre="${vt%%"$n"*}"; suf="${vt#*"$n"}"; w="${#n}"
    if vt_is_primary "$vt"; then step=1; else step=-1; fi
    sib=$(( 10#$n + step )); printf '%s%0*d%s' "$pre" "$w" "$sib" "$suf"
}
vt_pair() {  # pair number = (primary_num - PRIMARY_PARITY)/2 + 1  (PRIMARY_PARITY == first primary index)
    local n p; n="$(vt_num "$1")"; [ -n "$n" ] || { echo 0; return; }
    if vt_is_primary "$1"; then p=$(( 10#$n )); else p=$(( 10#$n - 1 )); fi
    echo $(( (p - PRIMARY_PARITY)/2 + 1 ))
}

# Provision the preferred local log root. A common BRIC group is preferred; where the group does
# not exist yet, sticky mode keeps per-process files isolated. Runtime still falls back to NFS.
setup_log_dirs() {
    local root="$BRIC_LOG_DIR" fb="$BRIC_LOG_FALLBACK_DIR"
    if [ "$DRY" = yes ]; then
        printf '  [dry-run] provision log roots %s and %s\n' "$root" "$fb"; return 0
    fi
    if [ "$(id -u)" -eq 0 ]; then
        if getent group "$BRIC_LOG_GROUP" >/dev/null 2>&1; then
            install -d -m 2775 -o root -g "$BRIC_LOG_GROUP" "$root"
        else
            install -d -m 1733 -o root -g root "$root"
            warn "group '$BRIC_LOG_GROUP' does not exist; $root created sticky/world-writable for per-process logs"
        fi
    else
        mkdir -p "$root" 2>/dev/null || true
    fi
    if [ "$ROLE" = slurm ] && [ "$(id -u)" -eq 0 ]; then
        if getent group "$BRIC_LOG_ADMIN_GROUP" >/dev/null 2>&1; then
            install -d -m 0751 -o root -g "$BRIC_LOG_ADMIN_GROUP" "$BRIC_USER_LOG_ROOT"
        else
            warn "central user-log admin group '$BRIC_LOG_ADMIN_GROUP' does not exist; user activation will fail closed until it is created"
        fi
    fi
    if [ "$(id -u)" -eq 0 ] && getent group "$BRIC_LOG_GROUP" >/dev/null 2>&1; then
        install -d -m 2770 -o root -g "$BRIC_LOG_GROUP" "$fb"
    else
        mkdir -p "$fb" 2>/dev/null || true
        chmod 1733 "$fb" 2>/dev/null || true
    fi
}

# ---- preconditions ---------------------------------------------------------------------------------
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "comando richiesto non trovato: $1"; }
REVIEW="$(awk -F= '$1=="review"{print $2}' "$HERE/RELEASE" 2>/dev/null | tail -1)"
say "== BRIC Archive 2.0 setup — review=${REVIEW:-unknown} role=$ROLE $( [ "$DRY" = yes ] && echo '(DRY-RUN)')"
need_cmd sqlite3; need_cmd openssl; need_cmd awk; need_cmd sed
ensure_tar_stream_helper() {
    local helper="$HERE/cluster/libexec/bric-tar-stream"
    local source="$HERE/cluster/libexec/bric-tar-stream.go"
    local goarch tmp err probe_out probe_rc probe_diag final_out final_rc _why

    if [ ! -e "$helper" ]; then
        probe_diag="missing: $helper"
    elif [ ! -x "$helper" ]; then
        probe_diag="not executable: $(ls -ld -- "$helper" 2>&1 || printf '%s' "$helper")"
    elif probe_out="$("$helper" --version 2>&1)"; then
        note "tar-stream helper executable: $probe_out"
        return 0
    else
        probe_rc=$?
        probe_diag="exit=$probe_rc: ${probe_out:-no stderr/stdout}"
    fi

    # A previous release accidentally shipped an amd64 helper linked against glibc 2.34.
    # RHEL 8 is amd64 too, but cannot execute that binary. Rebuild without cgo whenever a
    # local Go compiler is available; preserve the original execution error so a rebuild
    # failure cannot mask noexec, loader, policy, filesystem or permission problems.
    if command -v go >/dev/null 2>&1 && [ -r "$source" ]; then
        case "$(uname -m 2>/dev/null || true)" in
            x86_64|amd64)  goarch=amd64 ;;
            aarch64|arm64) goarch=arm64 ;;
            *) die "tar-stream helper unusable (${probe_diag}); local rebuild does not support architecture: $(uname -m 2>/dev/null || echo unknown)" ;;
        esac
        tmp="${helper}.new.$$"
        err="${tmp}.err"
        rm -f "$tmp" "$err"
        note "tar-stream helper probe failed (${probe_diag}); rebuilding locally as static linux/$goarch"
        if (cd "$(dirname "$source")" && env CGO_ENABLED=0 GOOS=linux GOARCH="$goarch"                 go build -trimpath -ldflags='-s -w' -o "$tmp" "$(basename "$source")") 2>"$err"; then
            chmod 0755 "$tmp"
            mv -f "$tmp" "$helper"
            rm -f "$err"
        else
            _why="$(tr '\n' ' ' <"$err" 2>/dev/null || true)"
            rm -f "$tmp" "$err"
            die "tar-stream helper unusable before rebuild (${probe_diag}); static local rebuild failed: ${_why:-unknown go build error}"
        fi
    else
        die "tar-stream helper unusable (${probe_diag}); static local rebuild unavailable (Go compiler or source missing)"
    fi

    if final_out="$("$helper" --version 2>&1)"; then
        note "tar-stream helper executable after rebuild: $final_out"
    else
        final_rc=$?
        die "tar-stream helper still unusable after static rebuild on $(uname -m 2>/dev/null || echo unknown); initial probe: ${probe_diag}; rebuilt helper exit=$final_rc: ${final_out:-no stderr/stdout}"
    fi
}


ensure_file_metadata_helper() {
    local helper="$HERE/cluster/libexec/bric-file-metadata"
    local source="$HERE/cluster/libexec/bric-file-metadata.go"
    local goarch tmp err out rc why
    if [ -x "$helper" ] && out="$("$helper" --version 2>&1)"; then note "file-metadata helper executable: $out"; return 0; fi
    if ! command -v go >/dev/null 2>&1 || [ ! -r "$source" ]; then die "file-metadata helper unusable and static local rebuild unavailable"; fi
    case "$(uname -m 2>/dev/null || true)" in x86_64|amd64) goarch=amd64;; aarch64|arm64) goarch=arm64;; *) die "file-metadata helper rebuild unsupported architecture";; esac
    tmp="${helper}.new.$$"; err="${tmp}.err"; rm -f "$tmp" "$err"
    if (cd "$(dirname "$source")" && env CGO_ENABLED=0 GOOS=linux GOARCH="$goarch" go build -trimpath -ldflags='-s -w' -o "$tmp" "$(basename "$source")") 2>"$err"; then
        chmod 0755 "$tmp"; mv -f "$tmp" "$helper"; rm -f "$err"
    else
        why="$(tr '\n' ' ' <"$err" 2>/dev/null || true)"; rm -f "$tmp" "$err"; die "file-metadata helper static rebuild failed: ${why:-unknown go build error}"
    fi
    "$helper" --version >/dev/null 2>&1 || die "file-metadata helper still unusable after rebuild"
}

case "$ROLE" in
    cluster|slurm|all)
        need_cmd tar
        ensure_tar_stream_helper
        ensure_file_metadata_helper
        ;;
esac
setup_log_dirs
# WAL e ECDSA P-256 devono funzionare in questo userland (non solo nel mio sandbox)
T="$(mktemp)"; jm="$(sqlite3 "$T" 'PRAGMA journal_mode=WAL;' 2>/dev/null || true)"; rm -f "$T" "$T-wal" "$T-shm"
[ "$jm" = "wal" ] || die "sqlite3 non abilita journal_mode=WAL (versione troppo vecchia?)"
# Capability check: prove the host can SIGN and VERIFY, not merely generate a key. Generating an
# Ed25519 key succeeds on OpenSSL 1.1.1 while signing it is impossible there (no CLI path), so a
# keygen-only probe reported "OK" on supekgate and the real failure surfaced much later as an
# undiagnosable "bus signing failed". Exercise the full round trip with OpenSSL's error in hand.
_cap="$(mktemp -d)"
printf 'BRIC-SETUP-CAPABILITY-PROBE' > "$_cap/m"
if openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$_cap/k.pem" 2>"$_cap/e" \
   && openssl pkey -in "$_cap/k.pem" -pubout -out "$_cap/k.pub" 2>>"$_cap/e" \
   && openssl dgst -sha256 -sign "$_cap/k.pem" -out "$_cap/s" "$_cap/m" 2>>"$_cap/e" \
   && openssl dgst -sha256 -verify "$_cap/k.pub" -signature "$_cap/s" "$_cap/m" >/dev/null 2>>"$_cap/e"; then
    rm -rf "$_cap"
else
    _why="$(tr '\n' ' ' < "$_cap/e" 2>/dev/null)"; rm -rf "$_cap"
    die "openssl non può firmare/verificare ECDSA P-256 su questo host ($(openssl version 2>/dev/null)): ${_why:-nessun messaggio}"
fi
note "preconditions OK: sqlite3 WAL, openssl ECDSA P-256 (sign+verify provati), awk/sed presenti"
# Site policy: OpenSSL >= 3.0 on both nodes (module-loaded on the cluster). This is an OPERATIONAL
# alignment, not a recovery requirement — blob format is parameter-pinned and opens on any OpenSSL
# 1.1.1+ (see RECOVERY_HANDBOOK). So: warn, do not die, if below 3.0.
ov="$(openssl version | awk '{print $2}')"; ov_major="${ov%%.*}"
if [ "${ov_major:-0}" -ge 3 ] 2>/dev/null; then
    note "openssl $ov (>= 3.0) — aligned across nodes, good"
else
    warn "openssl $ov è sotto il minimo 3.0. Il runtime BRIC cercherà automaticamente una versione >=3 con module avail (preferenza: $BRIC_SLURM_OPENSSL_MODULE)"
fi

backup_db() {  # path -> copia timestamped se esiste e non è vuoto
    local db="$1"
    if [ -s "$db" ]; then
        local bk="$db.bak.$(date +%Y%m%d%H%M%S)"
        run cp -p "$db" "$bk"; note "backup del catalogo esistente: $bk"
    fi
}

ensure_master_key() {
    local mk; mk="$(master_key_file)"
    run mkdir -p "$(dirname "$mk")"
    if [ -s "$mk" ]; then note "master key presente: $mk"; return; fi
    warn "master key assente: la genero (32 byte casuali, 0400). CUSTODISCILA: senza, gli escrow non si aprono."
    if [ "$DRY" = no ]; then ( umask 077; head -c 32 /dev/urandom | base64 > "$mk.tmp.$$" ) && mv -f "$mk.tmp.$$" "$mk" && chmod 400 "$mk"; fi
    note "master key generata: $mk (0400)"
}

gen_bus_keys() {
    [ "$BRIC_GEN_BUS_KEYS" = yes ] || { warn "generazione chiavi bus saltata (BRIC_GEN_BUS_KEYS!=yes)"; return; }
    run "$HERE/cluster/scripts/bric-bus-keygen.sh" "$BRIC_ADMIN_KEYS"
    cat <<EOF
  ${c_yel}Distribuzione chiavi del bus (manuale, niente SSH automatico):${c_off}
    CLUSTER     : BRIC_BUS_SIGN_KEY=$BRIC_ADMIN_KEYS/cluster_bus_ecdsa_p256.pem  BRIC_BUS_VERIFY_KEY=$BRIC_ADMIN_KEYS/tape_bus_ecdsa_p256.pub
    TAPE SERVER : BRIC_BUS_SIGN_KEY=$BRIC_ADMIN_KEYS/tape_bus_ecdsa_p256.pem     BRIC_BUS_VERIFY_KEY=$BRIC_ADMIN_KEYS/cluster_bus_ecdsa_p256.pub
    Copia su ciascun host SOLO la sua privata + la pubblica del peer; le .pub possono stare in chiaro.
EOF
}

set_config() {  # db  key  value
    sqlite_do "$1" "INSERT INTO config(key,value) VALUES('$(sql_quote "$2")','$(sql_quote "$3")')
                    ON CONFLICT(key) DO UPDATE SET value='$(sql_quote "$3")';"
}

# ---- CLUSTER ---------------------------------------------------------------------------------------
setup_cluster() {
    say; say "-- lato CLUSTER --"
    run mkdir -p "$(dirname "$BRIC_DB")" "$(dirname "$BRIC_DB")/runstate" "$BRIC_HOME/sql"
    [ -f "$HERE/cluster/sql/cluster_init.sql" ] || die "manca cluster/sql/cluster_init.sql nel pacchetto"
    backup_db "$BRIC_DB"
    note "init schema cluster (idempotente)"
    if [ "$DRY" = no ]; then sqlite3 "$BRIC_DB" < "$HERE/cluster/sql/cluster_init.sql" >/dev/null; else printf '  [dry-run] sqlite3 %s < cluster_init.sql\n' "$BRIC_DB"; fi
    set_config "$BRIC_DB" segment_target_bytes "$BRIC_CHUNK_TARGET_BYTES"
    set_config "$BRIC_DB" max_concurrent_producers "$BRIC_MAX_CONCURRENT_PRODUCERS"
    set_config "$BRIC_DB" stream_parallel_workers "$BRIC_STREAM_PARALLEL_WORKERS"
    set_config "$BRIC_DB" stream_worker_chunk_bytes "$BRIC_STREAM_WORKER_CHUNK_BYTES"
    set_config "$BRIC_DB" tar_blocking_factor "$BRIC_TAR_BLOCKING_FACTOR"
    set_config "$BRIC_DB" compression none
    note "config cluster: segment_target_bytes=$BRIC_CHUNK_TARGET_BYTES, max_concurrent_producers=$BRIC_MAX_CONCURRENT_PRODUCERS, stream_parallel_workers=$BRIC_STREAM_PARALLEL_WORKERS, stream_worker_chunk_bytes=$BRIC_STREAM_WORKER_CHUNK_BYTES, tar_blocking_factor=$BRIC_TAR_BLOCKING_FACTOR, compression=none"

    ensure_master_key

    # utenti + escrow (richiede la master key, presente su questo host admin)
    # Batch registration is delegated to the CANONICAL --users-file mode of bric-register-user
    # (never a second implementation of the same mechanism). BRIC_USERS (space-separated) is
    # normalized into a temp file and sent down the same path. NB: this also removes an IFS
    # hazard — this script runs with IFS=$'\n\t', so a `for u in $users` loop would NOT split
    # a space-separated list (the whole list would be passed as one bogus username).
    local users="" uf
    [ -n "$BRIC_USERS" ] && users="$BRIC_USERS"
    if [ -n "$BRIC_USERS_FILE" ] && [ -f "$BRIC_USERS_FILE" ]; then users="$users $(grep -vE '^\s*#|^\s*$' "$BRIC_USERS_FILE" | tr '\n' ' ')"; fi
    users="$(printf '%s' "$users" | tr -s ' ' | sed 's/^ //;s/ $//')"
    if [ -z "$users" ]; then
        warn "nessun utente in BRIC_USERS/BRIC_USERS_FILE — salto la registrazione."
        warn "registra un vero utente OS/AD con: cluster/scripts/bric-setup-user.sh --user NOME (come root)"
    else
        uf="$(mktemp)"; printf '%s' "$users" | tr ' ' '\n' > "$uf"
        note "registro utenti logici/staging ($(printf '%s' "$users" | tr ' ' ',')); per utenti OS/AD usa bric-setup-user.sh"
        run env "BRIC_DB=$BRIC_DB" "BRIC_KEYS=$BRIC_ADMIN_KEYS" "BRIC_ADMIN_KEYS=$BRIC_ADMIN_KEYS" "BRIC_MASTER_KEY_FILE=$(master_key_file)" "$HERE/cluster/scripts/bric-register-user.sh" --users-file "$uf"
        rm -f "$uf"
    fi

    set_config "$BRIC_DB" require_user_escrow 1
    note "require_user_escrow=1 (ogni backup richiede onboarding amministrativo dell'utente)"

    if [ "$BRIC_REQUIRE_SIGNING" = 1 ]; then
        if [ -s "$BRIC_ADMIN_KEYS/cluster_bus_ecdsa_p256.pem" ] && [ -s "$BRIC_ADMIN_KEYS/tape_bus_ecdsa_p256.pub" ]; then
            set_config "$BRIC_DB" require_bus_signing 1; note "require_bus_signing=1 (firma OBBLIGATORIA)"
        else
            set_config "$BRIC_DB" require_bus_signing 0
            warn "require_bus_signing lasciato a 0: chiavi del bus non ancora presenti su questo host."
            warn "dopo aver distribuito le chiavi:  sqlite3 $BRIC_DB \"UPDATE config SET value='1' WHERE key='require_bus_signing';\""
        fi
    fi
    note "QNAP bus atteso in: $BRIC_QNAP  (montato NFS, *scrivibile solo* dal service account)"
}

install_user_command() {
    local target="$HERE/cluster/bin/bric-run" link="$BRIC_COMMAND_LINK" resolved=""
    [ -x "$target" ] || die "manca il wrapper utente eseguibile: $target"
    case "$link" in /*) ;; *) die "BRIC_COMMAND_LINK deve essere assoluto (got '$link')";; esac
    if [ "$DRY" = yes ]; then
        printf '  [dry-run] ln -sfn %s %s\n' "$target" "$link"
        return 0
    fi
    mkdir -p "$(dirname "$link")"
    if [ -e "$link" ] && [ ! -L "$link" ]; then
        die "$link esiste già e non è un symlink; non lo sovrascrivo"
    fi
    if [ -L "$link" ]; then
        resolved="$(readlink -f "$link" 2>/dev/null || true)"
        [ "$resolved" = "$target" ] || ln -sfn "$target" "$link"
    else
        ln -s "$target" "$link"
    fi
    note "comando utente installato: $link -> $target"
}


install_update_command() {
    local target="$HERE/bric-update" link="$BRIC_UPDATE_LINK" resolved=""
    [ -x "$target" ] || die "manca il comando update eseguibile: $target"
    case "$link" in /*) ;; *) die "BRIC_UPDATE_LINK deve essere assoluto (got '$link')";; esac
    if [ "$DRY" = yes ]; then
        printf '  [dry-run] ln -sfn %s %s\n' "$target" "$link"
        return 0
    fi
    mkdir -p "$(dirname "$link")"
    if [ -e "$link" ] && [ ! -L "$link" ]; then
        die "$link esiste già e non è un symlink; non lo sovrascrivo"
    fi
    if [ -L "$link" ]; then
        resolved="$(readlink -f "$link" 2>/dev/null || true)"
        [ "$resolved" = "$target" ] || ln -sfn "$target" "$link"
    else
        ln -s "$target" "$link"
    fi
    note "updater installato: $link -> $target"
}



install_tape_import_command() {
    local target="$HERE/tape/bin/bric-tape-import-inventory" link="$BRIC_TAPE_IMPORT_LINK" resolved=""
    [ -x "$target" ] || die "manca il comando import inventario tape: $target"
    case "$link" in /*) ;; *) die "BRIC_TAPE_IMPORT_LINK deve essere assoluto (got '$link')";; esac
    if [ "$DRY" = yes ]; then
        printf '  [dry-run] ln -sfn %s %s\n' "$target" "$link"
        return 0
    fi
    mkdir -p "$(dirname "$link")"
    if [ -e "$link" ] && [ ! -L "$link" ]; then
        die "$link esiste già e non è un symlink; non lo sovrascrivo"
    fi
    if [ -L "$link" ]; then
        resolved="$(readlink -f "$link" 2>/dev/null || true)"
        [ "$resolved" = "$target" ] || ln -sfn "$target" "$link"
    else
        ln -s "$target" "$link"
    fi
    note "import inventario tape installato: $link -> $target"
}

install_admin_user_activation_command() {
    local target="$HERE/cluster/bin/bric-activate-user" link="$BRIC_ACTIVATE_USER_LINK" resolved=""
    [ -x "$target" ] || die "manca il comando amministrativo eseguibile: $target"
    case "$link" in /*) ;; *) die "BRIC_ACTIVATE_USER_LINK deve essere assoluto (got '$link')";; esac
    if [ "$DRY" = yes ]; then
        printf '  [dry-run] ln -sfn %s %s\n' "$target" "$link"
        return 0
    fi
    mkdir -p "$(dirname "$link")"
    if [ -e "$link" ] && [ ! -L "$link" ]; then
        die "$link esiste già e non è un symlink; non lo sovrascrivo"
    fi
    if [ -L "$link" ]; then
        resolved="$(readlink -f "$link" 2>/dev/null || true)"
        [ "$resolved" = "$target" ] || ln -sfn "$target" "$link"
    else
        ln -s "$target" "$link"
    fi
    note "attivazione utenti installata: $link -> $target"
}


install_bus_cleanup_command() {
    local target="$HERE/cluster/bin/bric-bus-cleanup" link="$BRIC_BUS_CLEANUP_LINK" resolved=""
    [ -x "$target" ] || die "manca il comando amministrativo eseguibile: $target"
    case "$link" in /*) ;; *) die "BRIC_BUS_CLEANUP_LINK deve essere assoluto (got '$link')";; esac
    if [ "$DRY" = yes ]; then
        printf '  [dry-run] ln -sfn %s %s\n' "$target" "$link"
        return 0
    fi
    mkdir -p "$(dirname "$link")"
    if [ -e "$link" ] && [ ! -L "$link" ]; then
        die "$link esiste già e non è un symlink; non lo sovrascrivo"
    fi
    if [ -L "$link" ]; then
        resolved="$(readlink -f "$link" 2>/dev/null || true)"
        [ "$resolved" = "$target" ] || ln -sfn "$target" "$link"
    else
        ln -s "$target" "$link"
    fi
    note "pulizia bus installata: $link -> $target"
}


install_man_page() {
    local source="$HERE/docs/man/bric.1" target="$BRIC_MAN_DIR/bric.1"
    [ -f "$source" ] || die "manca la pagina manuale utente: $source"
    case "$BRIC_MAN_DIR" in /*) ;; *) die "BRIC_MAN_DIR deve essere assoluto (got '$BRIC_MAN_DIR')";; esac
    if [ "$DRY" = yes ]; then
        printf '  [dry-run] install -D -m 0644 %s %s\n' "$source" "$target"
        return 0
    fi
    install -d -m 0755 "$BRIC_MAN_DIR"
    install -m 0644 "$source" "$target"
    note "pagina man installata: $target (usa: man bric)"
}

install_tape_systemd() {
    local source="$HERE/tape/systemd/bric-tape-daemon.service"
    local target="$BRIC_SYSTEMD_UNIT_DIR/bric-tape-daemon.service"
    [ -f "$source" ] || die "manca unità systemd tape: $source"
    if [ "$DRY" = yes ]; then
        printf '  [dry-run] install -D -m 0644 %s %s\n' "$source" "$target"
        printf '  [dry-run] systemctl daemon-reload && systemctl enable%s bric-tape-daemon.service\n' "$([ "$BRIC_SYSTEMD_AUTO_START" = 1 ] && echo ' --now' || true)"
        return 0
    fi
    install -d -m 0755 "$BRIC_SYSTEMD_UNIT_DIR"
    install -m 0644 "$source" "$target"
    if command -v systemctl >/dev/null 2>&1 && [ "$(ps -p 1 -o comm= 2>/dev/null | tr -d ' ')" = systemd ]; then
        systemctl daemon-reload
        if [ "$BRIC_SYSTEMD_AUTO_START" = 1 ]; then
            # Stop any manually launched copy first; systemd must be the sole owner of the daemon lock.
            local pids
            pids="$(pgrep -f '[b]ric-tape-daemon --loop' || true)"
            [ -z "$pids" ] || { kill -TERM $pids || true; sleep 2; }
            rm -f /tmp/bric_tape.lock /tmp/bric_tape.lock.work
            systemctl enable --now bric-tape-daemon.service
            sleep 1
            if ! systemctl is-active --quiet bric-tape-daemon.service; then
                systemctl status --no-pager -l bric-tape-daemon.service >&2 || true
                die "systemd installed the tape daemon but it did not remain active; inspect: journalctl -u bric-tape-daemon.service -n 100 --no-pager"
            fi
            note "systemd: bric-tape-daemon.service enabled, started and active"
        else
            systemctl enable bric-tape-daemon.service
            note "systemd: bric-tape-daemon.service enabled (not started; BRIC_SYSTEMD_AUTO_START=0)"
        fi
    else
        warn "systemd non attivo: unità installata in $target ma non abilitata/avviata"
    fi
}

# ---- TAPE ------------------------------------------------------------------------------------------
load_barcodes() {  # echo dei barcode in ordine di slot, uno per riga
    if [ -n "$BRIC_BARCODES_FILE" ]; then
        [ -f "$BRIC_BARCODES_FILE" ] || die "BRIC_BARCODES_FILE non trovato: $BRIC_BARCODES_FILE"
        grep -vE '^\s*#|^\s*$' "$BRIC_BARCODES_FILE"
    else
        if [ "${BRIC_TAPE_BACKEND:-real}" = real ]; then
            die "BRIC_TAPE_BACKEND=real requires BRIC_BARCODES_FILE with the physical cartridge inventory; refusing to invent barcode labels"
        fi
        warn "BRIC_BARCODES_FILE non impostato: genero $BRIC_TAPE_COUNT barcode dal numero $BRIC_BARCODE_START col pattern '$BRIC_BARCODE_FMT' (SOLO simulazione/staging)." >&2
        local k=0; while [ "$k" -lt "$BRIC_TAPE_COUNT" ]; do printf "$BRIC_BARCODE_FMT\n" "$((BRIC_BARCODE_START + k))"; k=$((k+1)); done
    fi
}

setup_tape() {
    say; say "-- lato TAPE SERVER --"
    run mkdir -p "$(dirname "$BRIC_TAPE_DB")" "$BRIC_TAPE_HOME/sql"
    [ -f "$HERE/tape/sql/tape_init.sql" ] || die "manca tape/sql/tape_init.sql nel pacchetto"
    backup_db "$BRIC_TAPE_DB"
    note "init schema tape (idempotente)"
    if [ "$DRY" = no ]; then sqlite3 "$BRIC_TAPE_DB" < "$HERE/tape/sql/tape_init.sql" >/dev/null; else printf '  [dry-run] sqlite3 %s < tape_init.sql\n' "$BRIC_TAPE_DB"; fi

    set_config "$BRIC_TAPE_DB" tape_exclusivity "$BRIC_TAPE_EXCLUSIVITY"
    set_config "$BRIC_TAPE_DB" tape_headroom_tb "$BRIC_TAPE_HEADROOM_TB"
    set_config "$BRIC_TAPE_DB" chunk_target_bytes "$BRIC_CHUNK_TARGET_BYTES"
    set_config "$BRIC_TAPE_DB" parallel_drives "$BRIC_PARALLEL_DRIVES"
    set_config "$BRIC_TAPE_DB" poll_seconds "$BRIC_POLL_SECONDS"
    set_config "$BRIC_TAPE_DB" claim_ttl_hours "$BRIC_CLAIM_TTL_HOURS"
    set_config "$BRIC_TAPE_DB" changer_device "$BRIC_CHANGER"
    set_config "$BRIC_TAPE_DB" primary_parity "$BRIC_PRIMARY_PARITY"
    note "config tape: exclusivity=$BRIC_TAPE_EXCLUSIVITY headroom=${BRIC_TAPE_HEADROOM_TB}TB drives=$BRIC_PARALLEL_DRIVES poll=${BRIC_POLL_SECONDS}s changer=$BRIC_CHANGER primary_parity=$BRIC_PRIMARY_PARITY"
    [ "$BRIC_PARALLEL_DRIVES" = 1 ] && warn "parallel_drives=1: PRIMARY+BACKUP serializzati."
    if [ "$BRIC_PARALLEL_DRIVES" -ge 2 ] 2>/dev/null; then
        local _ifs="$IFS"; IFS=" "; set -- $BRIC_TAPE_DRIVES; IFS="$_ifs"
        [ "$#" -ge 2 ] || die "BRIC_PARALLEL_DRIVES=2 requires at least two entries in BRIC_TAPE_DRIVES"
        [ "$1" != "$2" ] || die "the first two BRIC_TAPE_DRIVES entries must be distinct"
        note "parallel write enabled: PRIMARY drive $1, BACKUP drive $2"
    fi

    if [ "$BRIC_REQUIRE_SIGNING" = 1 ]; then
        if [ -s "$BRIC_ADMIN_KEYS/tape_bus_ecdsa_p256.pem" ] && [ -s "$BRIC_ADMIN_KEYS/cluster_bus_ecdsa_p256.pub" ]; then
            set_config "$BRIC_TAPE_DB" require_bus_signing 1; note "require_bus_signing=1 (il daemon rifiuta di partire senza chiavi)"
        else
            set_config "$BRIC_TAPE_DB" require_bus_signing 0
            warn "require_bus_signing lasciato a 0: chiavi del bus non presenti su questo host. Attivalo dopo la distribuzione."
        fi
    fi

    # inventario nastri: ruolo per PARITÀ del barcode (BACKUP = PRIMARY+1), pairing coerente. INSERT OR IGNORE.
    say "  popolo l'inventario nastri (parità: $BRIC_PRIMARY_PARITY onsite; INSERT OR IGNORE — non tocca cartucce già presenti):"
    local idx=0 added=0 sql=""
    local -a BC=(); while IFS= read -r b; do [ -n "$b" ] && BC+=("$b"); done < <(load_barcodes)
    [ "${#BC[@]}" -ge 2 ] || die "servono almeno 2 barcode (una coppia)"
    [ $(( ${#BC[@]} % 2 )) -eq 0 ] || warn "numero di barcode dispari (${#BC[@]}): un nastro potrebbe restare senza partner"
    while [ "$idx" -lt "${#BC[@]}" ]; do
        local bc="${BC[$idx]}" role pair sib
        if vt_is_primary "$bc"; then role=PRIMARY; else role=BACKUP; fi
        sib="$(vt_sibling "$bc")"; pair="$(vt_pair "$bc")"
        sql="$sql
INSERT OR IGNORE INTO tapes(volumetag,slot,role,pair_number,paired_volumetag,capacity_tb,used_tb,status)
VALUES('$(sql_quote "$bc")',$((idx+1)),'$role',$pair,'$(sql_quote "$sib")',$BRIC_TAPE_CAPACITY_TB,0.0,'EMPTY');"
        added=$((added+1)); idx=$((idx+1))
    done
    sqlite_do "$BRIC_TAPE_DB" "BEGIN IMMEDIATE;$sql
COMMIT;"
    if [ "$DRY" = no ]; then
        local tot pri bak; tot="$(sqlite3 "$BRIC_TAPE_DB" 'SELECT COUNT(*) FROM tapes;')"
        pri="$(sqlite3 "$BRIC_TAPE_DB" "SELECT COUNT(*) FROM tapes WHERE role='PRIMARY';")"
        bak="$(sqlite3 "$BRIC_TAPE_DB" "SELECT COUNT(*) FROM tapes WHERE role='BACKUP';")"
        note "inventario: $tot nastri totali in catalogo ($pri PRIMARY + $bak BACKUP); proposti ora: $added"
    else note "proposti $added nastri (dry-run)"; fi
    note "tapelib/backend: con BRIC_TAPE_BACKEND=real il daemon usa il changer $BRIC_CHANGER; verifica mtx/mt prima del primo write reale"
}

# ---- run -------------------------------------------------------------------------------------------
# Le chiavi del bus vanno create PRIMA dei due lati: così, se presenti, require_bus_signing parte già a 1.
# (bric-bus-keygen genera ENTRAMBE le coppie; in produzione due-host generale una volta e distribuiscile,
#  poi cancella dal cluster la privata del tape e viceversa.)
if [ "$BRIC_GEN_BUS_KEYS" = yes ]; then say; say "-- chiavi del bus --"; gen_bus_keys; fi
if [ "$ROLE" = cluster ] || [ "$ROLE" = slurm ]; then
    setup_cluster
    install_user_command
    install_admin_user_activation_command
    install_bus_cleanup_command
    install_update_command
    install_man_page
elif [ "$ROLE" = all ]; then
    setup_cluster
    note "staging role=all: user command symlink not installed; run --role slurm on the cluster host"
fi
if [ "$ROLE" = tape ]; then setup_tape; install_update_command; install_tape_import_command; install_tape_systemd
elif [ "$ROLE" = all ]; then setup_tape; install_tape_import_command; install_tape_systemd; fi

say
note "setup completato${DRY:+ }$( [ "$DRY" = yes ] && echo '(DRY-RUN: nessuna scrittura effettuata)')"
cat <<EOF

Prossimi passi:
  1) distribuisci le chiavi del bus sui due host (vedi sopra) e, se non già a 1, attiva
     require_bus_signing su entrambi i cataloghi.
  2) verifica le mount: Isilon (NFS, read) sui nodi archive; QNAP ($BRIC_QNAP) NFS scrivibile
     SOLO dal service account.
  3) attiva ogni utente reale sul cluster: bric-activate-user NOME
  4) verifica la release installata:       bric version   (cluster) / bric-update --current (root)
  5) verifica il daemon systemd:          systemctl status bric-tape-daemon
  6) prova un progetto PICCOLO:            bric backup test_piccolo /percorso
  7) restore + DR di verifica:            cluster/scripts/bric-dr-from-tapes.sh ...  e
                                        tape/scripts/bric-tape-rebuild-catalog.sh --out /tmp/rb.db --verify
EOF
[ "$ROLE" = all ] && say "In staging mono-host puoi validare l'intera catena con:  test/run_local_e2e.sh"
exit 0
