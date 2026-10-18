#!/bin/bash
# Lancia l'interfaccia web di BRIC come job SLURM, raggiungibile via tunnel SSH (stesso schema del
# template RStudioServer). Una sessione per utente: il job gira con il TUO uid, quindi ogni comando
# bric usa la tua identità e la tua chiave personale. Nessun login applicativo: il tunnel SSH è il
# confine di rete e un token di sessione casuale protegge l'URL.
#
#   sbatch /projects/bricsoftware/apps/bric2/cluster/web/bric-web.sbatch
#   # poi segui le istruzioni di tunnel SSH stampate nel log del job.
#
#SBATCH --job-name=bric-web
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=2G
#SBATCH --time=08:00:00
#SBATCH --output=%j_bric_web.log
#SBATCH --partition=normal_prio

#==============================================================================
# CONFIGURAZIONE — adatta al sito
#==============================================================================
# Radice dell'installazione BRIC (contiene cluster/bin/bric e cluster/web/bric-web.py)
BRIC_INSTALL="${BRIC_INSTALL:-/projects/bricsoftware/apps/bric2}"
# Gateway SSH usato per il tunnel (come nel template RStudio)
SSH_GATEWAY="${BRIC_SSH_GATEWAY:-supekgate.unicph.domain}"
# File env opzionale del sito: può esportare BRIC_HOME/BRIC_DB/BRIC_QNAP/BRIC_USER_KEY_FILE/le chiavi del bus.
SITE_ENV="${BRIC_SITE_ENV:-$BRIC_INSTALL/cluster/web/bric-web.env}"
#==============================================================================

set -uo pipefail
HERE="$BRIC_INSTALL/cluster"
WEB="$HERE/web/bric-web.py"
[ -f "$WEB" ] || { echo "ERRORE: bric-web.py non trovato in $WEB (controlla BRIC_INSTALL)"; exit 1; }

# Carica l'eventuale env di sito (path dei cataloghi, QNAP, chiavi). Se assente, si usano i default
# compilati in lib_common.sh (chiave personale da ~/.bric/env.sh), che bric-setup-user.sh ha già popolato.
if [ -f "$SITE_ENV" ]; then echo "Carico env di sito: $SITE_ENV"; set -a; . "$SITE_ENV"; set +a; fi

# Modalità di esecuzione: in produzione i backup vanno sottomessi come job SLURM.
export BRIC_RUN_MODE="${BRIC_RUN_MODE:-slurm}"
export BRIC_HOME="${BRIC_HOME:-$HERE}"
# Do not duplicate stdout here: it contains the capability URL/token. The Slurm output remains the
# controlled hand-off channel; lifecycle/module/errors still go to the structured BRIC event log.
export BRIC_LOG_CAPTURE_STDIO=0
. "$BRIC_HOME/scripts/lib_common.sh"
bric_log_process_start "slurm-web" "$@"
BRIC_LOG_RC=0 bric_event INFO WEB_JOB_START "slurm_output=${SLURM_JOB_ID:-unknown}_bric_web.log"

# Python 3 (solo stdlib, nessun pip). Prova il module system, poi il python3 di sistema.
bric_event INFO MODULE_LOAD_BEGIN "module=python3-or-python"
if module load python3; then
    bric_event INFO MODULE_LOAD_END "module=python3 executable=$(command -v python3 2>/dev/null)"
elif module load python; then
    bric_event INFO MODULE_LOAD_END "module=python executable=$(command -v python3 2>/dev/null)"
else
    bric_event WARN MODULE_LOAD_SKIPPED "python module unavailable; trying system python3"
fi
command -v python3 >/dev/null 2>&1 || die "python3 non disponibile"

# Porta libera casuale 8000-9000 (come il template RStudio).
export BRIC_WEB_ADDR="0.0.0.0"   # il gateway raggiunge la porta del nodo via LAN del cluster
export PORT=$(shuf -i 8000-9000 -n 1)
while ss -ltn 2>/dev/null | grep -q ":$PORT " || netstat -tuln 2>/dev/null | grep -q ":$PORT "; do
    export PORT=$(shuf -i 8000-9000 -n 1)
done
export BRIC_WEB_PORT="$PORT"

# Token di sessione casuale (capability URL): protegge l'interfaccia anche se la porta è raggiungibile.
export BRIC_WEB_TOKEN="$(python3 -c 'import secrets;print(secrets.token_urlsafe(24))')"

# Scadenza della sessione = fine della walltime del job (per il countdown mostrato nell'interfaccia).
DEADLINE_EPOCH=""
if command -v scontrol >/dev/null 2>&1 && [ -n "${SLURM_JOB_ID:-}" ]; then
    ET="$(scontrol show job "$SLURM_JOB_ID" 2>/dev/null | tr ' ' '\n' | sed -n 's/^EndTime=//p' | head -1)"
    [ -n "$ET" ] && [ "$ET" != "Unknown" ] && DEADLINE_EPOCH="$(date -d "$ET" +%s 2>/dev/null || true)"
fi
if [ -z "$DEADLINE_EPOCH" ]; then          # fallback: ricava dalla walltime richiesta (HH:MM:SS o D-HH:MM:SS)
    WALL="${BRIC_WEB_WALLTIME:-08:00:00}"
    SECS="$(awk -F'[:-]' '{ if(NF==4) print ((($1*24)+$2)*60+$3)*60+$4; else print (($1*60)+$2)*60+$3 }' <<<"$WALL")"
    DEADLINE_EPOCH=$(( $(date +%s) + ${SECS:-28800} ))
fi
export BRIC_WEB_DEADLINE="$DEADLINE_EPOCH"

cat <<EOF

=========================================================================
                BRIC Archive — interfaccia web avviata
=========================================================================

  Utente:  $USER     Nodo: $HOSTNAME     Porta: $PORT     Job: $SLURM_JOB_ID

  Per collegarti dal TUO computer:

  1) Apri un NUOVO terminale in locale e crea il tunnel SSH:
       ssh -L 8787:$HOSTNAME:$PORT $USER@$SSH_GATEWAY

  2) Tieni aperta quella sessione SSH, poi apri il browser su:
       http://localhost:8787/$BRIC_WEB_TOKEN/

     (l'URL contiene il token di sessione: non condividerlo)

  Per fermare l'interfaccia:
       scancel $SLURM_JOB_ID

  Log del job: ${SLURM_JOB_ID}_bric_web.log
=========================================================================

EOF

# Avvia il server (resta in foreground così il job vive finché serve).
python3 "$WEB"
rc=$?
bric_log_process_end "$rc"
trap - EXIT
exit "$rc"
