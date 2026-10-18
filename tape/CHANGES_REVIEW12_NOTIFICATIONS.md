# CHANGES — Review-12 (notifiche email + event log root-readable)

Suite: **27/27** (26 + il nuovo `run_notifications.sh`).

## Una sola implementazione: `bric_notify` in `cluster/scripts/lib_common.sh`

`bric_notify EVENT OWNER RUN_ID "detail"` fa due cose, sempre in quest'ordine e **senza mai poter
far fallire l'operazione chiamante** (ritorna sempre 0 — un mailer rotto o un log non scrivibile non
devono mai abbattere un archivio o un restore):

1. **Email best-effort** a `<owner>@$BRIC_MAIL_DOMAIN` (default `ku.dk`), via `mail -s` o, in
   assenza, `sendmail -t`. Soggetto `[BRIC Archive] EVENT run_id`, corpo con host, ora UTC e
   dettaglio. **Opt-in**: `BRIC_NOTIFY_MAIL` default **off** ("l'opzionale resta opzionale" — le
   suite di test e le sessioni di sviluppo non devono spammare caselle vere); in produzione si
   attiva con `BRIC_NOTIFY_MAIL=auto` nell'ambiente del servizio su supekgate.
2. **Riga di log strutturata**, SEMPRE scritta, 7 campi pipe-separated pensati per il digest cron:
   `ISO8601|EVENT|owner|run_id|host|detail|mail=sent/skipped/failed/none`
   Percorso: `$BRIC_NOTIFY_LOG`, default **`/var/log/bric/events.log`**; se non scrivibile
   dall'utente corrente, fallback `$BRIC_HOME/log/events.log`, poi `/tmp/bric_events.log`.
   Il dettaglio è sanificato (niente newline/pipe, max 500 char) per garantire una riga = un evento.

## Eventi innestati (tutti lato cluster, dove lo stato è autoritativo)

| Evento | Dove | Quando |
|---|---|---|
| `BACKUP_START` | `bric-plan` | reservation GRANTED, chunk pianificati: il backup comincia formalmente |
| `BACKUP_DENIED` | `bric-plan` | reservation negata (capacità o hardware gate), col motivo del daemon |
| `BACKUP_FAILED` | `bric-plan` (no files) e `fail_run` in `bric-finalize` | run fallito/abortito, col motivo |
| `CHUNK_ERROR` | `bric-chunk` | quiescence violation o produce fallito dopo i retry |
| `BACKUP_DONE` | `bric-close` | run CLOSED: dati su entrambe le copie, cataloghi e kit sigillati |
| `RESTORE_START` | `bric-restore` | owner e run risolti, prima della staging |
| `RESTORE_FAILED` | `bric-restore` | via trap EXIT: qualunque `die` dopo lo START produce esattamente un evento; anche gli errori di verifica finali |
| `RESTORE_DONE` | `bric-restore` | albero ripristinato e sha256-verificato |

## Test: `run_notifications.sh` (7 scenari)

Mailer mockato che registra To/Subject: (A) backup e2e → START+DONE loggati una volta e spediti a
`vsz652@ku.dk`, esito `mail=sent` nella riga; (B) reservation negata → BACKUP_DENIED col motivo;
(C) violazione di quiescenza → CHUNK_ERROR + BACKUP_FAILED; (D) restore e2e → START+DONE;
(E) restore che muore (staging timeout) → RESTORE_FAILED via trap; (F) **mailer che esce 1 →
l'operazione riesce comunque**, riga con `mail=failed`; (G) **nessun mailer nel PATH → operazione
intatta**, `mail=skipped`. Più un sanity check di formato: ogni riga ha esattamente 7 campi.

## Attivazione in produzione (supekgate)

```
# nell'ambiente del servizio / profilo degli operatori:
export BRIC_NOTIFY_MAIL=auto           # abilita le mail
export BRIC_MAIL_DOMAIN=ku.dk          # (già il default)
# il log eventi per il cron di root:
#   /var/log/bric/events.log           (creare la dir: mkdir -p /var/log/bric)
# esempio di digest giornaliero per root:
#   0 7 * * * root grep "$(date -u -d yesterday +\%Y-\%m-\%d)" /var/log/bric/events.log | mail -s "BRIC events digest" root
```
