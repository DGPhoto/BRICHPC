# CHANGES — Review-15 (bug di produzione: la suite su brictape come utente non-root)

Origine: prima esecuzione della suite sul ferro reale (brictape, utente vsz652): **18/28 FAIL**.
Diagnosi dai log, riproduzione locale come utente non privilegiato, fix. Esito: **28/28 come
non-root E come root**.

## Causa 1 (principale, mia): `bric_notify` non manteneva la sua garanzia per i non-root

Quasi tutti i test morti morivano subito dopo "reservation GRANTED" — la riga successiva è
`bric_notify BACKUP_START`. Con l'utente non-root, `mkdir -p /var/log/bric` fallisce; quella riga
NON era corazzata e, sotto il `set -e` di `bric-plan`, uccideva il plan (e quindi backup, abort,
finalize, DR-harness, ...). In sandbox non era emerso perché giravo come root. La garanzia
dichiarata ("notify non può mai far fallire l'operazione") era falsa esattamente nel caso che
conta: l'utente normale.

**Fix**: ogni statement della funzione è ora armored (`|| true`); il fallback dei percorsi log
funziona (`/var/log/bric` → `$BRIC_HOME/log` → `/tmp/bric_events.log`).
**Regressione root-agnostica** (scenario H di `run_notifications.sh`): backup completo con
`BRIC_NOTIFY_LOG=/proc/nonexistent/...` e `BRIC_HOME=/proc/nx2` (non scrivibili nemmeno da root)
→ deve arrivare a CLOSED col fallback. Riproduce l'incidente per chiunque, per sempre.

## Causa 2: scenario G del test notifiche non ermetico su host con mailer reale

G rimuoveva il mock `mail`: su brictape questo esponeva il mailer VERO (mailx/postfix) — assert
fallita e, peggio, rischio di consegne reali durante i test. Riscritto come unit-test ermetico:
`bric_notify` invocata sotto un PATH minimale senza alcun mailer → `mail=skipped` asserito, più la
verifica che la pipeline resti intatta. Nessun mailer reale è ora raggiungibile da alcun test.

## Causa 3: pulizia non-root in `run_posix`

La trap faceva `rm -rf` su un albero contenente una dir 0500: come root passa, come utente no
("Permission denied" nei tuoi log). Ora `chmod -R u+w` prima della rimozione (stesso pattern già
usato in `run_dr_e2e`).

## Causa 4 (scoperta estendendo la riproduzione): chmod incondizionati e lock stantio

- 22 test facevano `chmod +x` sui file del repo sotto `set -e`: da un checkout non posseduto
  (condiviso/sola lettura) il chmod fallisce e uccide il test. Ora tolleranti
  (`2>/dev/null || true`) ovunque.
- `run_real_e2e` era l'unico test senza `BRIC_TAPE_LOCK` proprio: un `/tmp/bric_tape.lock` stantio
  di un ALTRO utente (root, nel repro) impediva l'avvio del daemon. Allineato agli altri test.
  Nota operativa: in produzione il default del lock va comunque puntato a `/run/bric/` via
  `bric.conf` (già documentato) — `/tmp` condiviso è fragile su macchine multi-utente.

## Validazione

Suite completa eseguita in TRE condizioni: root (sandbox), utente non-root proprietario del
checkout (la condizione di brictape), e i punti sensibili ri-verificati come root dopo i fix.
28/28 in tutte. Lezione incorporata nel processo: la suite d'installazione va eseguita
dall'utenza operativa reale, non da root — ed è ora un requisito che i test stessi sopportano.
