# CHANGES — Review-19 (l'ultimo fallimento silenzioso del bus + runbook NFS)

Origine: migrazione del bus QNAP da SMB a NFS. La domanda di David — "a me interessa che l'utente
sia unico? che mi importa, se il backup riesce?" — era corretta e ha riorientato l'analisi.

## Il punto di merito: l'identità NON conta, il permesso di CANCELLARE sì

Verificato da sorgente: BRIC non ha un solo controllo di proprietà POSIX sul bus; l'owner di un
run è una stringa (`BRIC_USER`/`whoami`) nel catalogo; l'integrità è Ed25519 sui marker + HMAC/
sha256 sui blob. Quindi allineare gli UID fra AD (supekgate) e utenti locali (brictape) non è un
obiettivo: sotto SMB l'identità unica era un effetto collaterale della credenziale di mount, non
un requisito di progetto.

Delle quattro operazioni sul bus, tre falliscono in modo rumoroso (scrittura blob → il backup
fallisce; lettura → marker ERROR; staging del restore → errore). La quarta no:

    rm -f "$blob" "$rd/$cb.enc.sha256" "$rd/$cb.enc.hmac" 2>/dev/null || true

Errori scartati, `|| true`, e subito dopo il log stampa comunque `DONE chunk N`. Con il daemon
privo del permesso di cancellare i blob scritti dagli utenti del cluster, il run arriva a CLOSED
e **il bus non si svuota, senza che nulla lo segnali**: con segmenti da ~980 GB bastano due o tre
chunk per riempire lo staging e piantare il run successivo con una diagnosi che non punta a nulla.

## Fix: `_free_bus_blob()` — mai fatale, mai silenzioso

Helper unico (i due call site duplicavano la logica e scrivevano i sidecar in due modi diversi:
`$blob.sha256` vs `$rd/$cb.enc.sha256` — stessi file, due grafie, ora unificate). Tenta la
rimozione con le stesse protezioni di prima (il daemon gira sotto `set -euo pipefail`), poi
**verifica** l'esito e, se il blob è sopravvissuto, logga un WARNING che nomina la conseguenza
("the bus will NOT drain") e l'utente/uid con cui il daemon sta operando. Ritorna sempre 0.

## Regressione (`run_posix.sh`, sezione nuova)

L'helper viene estratto dal daemon ed esercitato contro un blob **non cancellabile in modo
deterministico per qualunque utente, root incluso** (una directory non vuota al posto del blob:
`rm -f` non può rimuoverla), evitando dipendenze da DAC o da runuser. Asserisce: rc=0 (non
abortirebbe il daemon), warning presente, conseguenza nominata; più l'happy path — blob e sidecar
rimossi, nessun warning spurio. Sul codice precedente il test fallisce alla prima asserzione
(l'helper non esiste).

## Runbook

- Fase 0/3: righe fstab NFS per i due lati (ognuno dall'indirizzo che corrisponde alla propria
  entry nella allow-list del QNAP), `nosuid,nodev` obbligatori sul nodo di login multi-utente,
  `secure` attivo. Sezione "Identity mapping": perché il disallineamento AD/locale non va
  inseguito, perché brictape NON va aggiunto ad AD (contraddirebbe il principio di recuperabilità
  senza infrastruttura superstite), e qual è l'unica condizione che deve reggere.
- Fase 9: **bus drain check** esplicito con `watch` sul conteggio dei blob e grep sul warning nel
  log del daemon. Il GATE 9 ora lo include.

## Validazione

run_posix 7/7 sulla nuova sezione; regressione su 18 test attorno al percorso daemon/bus
(local_e2e, dr_e2e, close_faultinj, partial_pair, restore_fallback, tape_rebuild, vtl, real_e2e,
real_backend_mock, security, job_lifecycle, setup_e2e, close_hardening, bus_signing, audit_health,
notifications, concurrency, daemon_crash): tutti PASS.
