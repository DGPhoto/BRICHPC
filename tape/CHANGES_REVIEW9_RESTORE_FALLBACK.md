# CHANGES — Review-9 (fallback PRIMARY→BACKUP nel restore via bus)

Batch nato da una segnalazione esterna ("c'è un errore nella fase di restore"). Confermata e
riprodotta. Suite: **25/25** (24 + il nuovo `run_restore_fallback.sh`).

## Il bug

`handle_restore` nel tape daemon violava l'invariante 5 così come dichiarato in ARCHITECTURE.md
("bric-restore: verify-before-decrypt, **fallback PRIMARY→BACKUP**"): il fallback esisteva nel DR
(`read_good_blob`) ma **non** nel restore via bus. Tre difetti concreti:

1. **Selezione a copia singola**: `SELECT ... ORDER BY (copy_role='PRIMARY') DESC LIMIT 1` prendeva
   solo la PRIMARY; la BACKUP non veniva mai tentata.
2. **Nessuna verifica del blob staged**: la copia letta dal nastro veniva pubblicata sul bus senza
   confronto con `segments.payload_sha256`. Un nastro degradato produceva un blob corrotto che il
   cluster rifiutava con HMAC mismatch e `die` — restore fallito, nessuna auto-guarigione, nonostante
   la copia BACKUP intatta fosse a un `fsf` di distanza.
3. **Un nastro illeggibile uccideva il daemon**: `tape_read_file` chiama `die` su errore di lettura e
   non era in subshell — un errore fisico durante una staging terminava l'intero daemon.

## Il fix (daemon)

`handle_restore` ora itera **tutte** le copie VERIFIED (PRIMARY prima, poi BACKUP); ogni candidata è
letta **in subshell** (un errore fisico logga, audita `RESTORE_READ_FAIL` e passa alla successiva) e
**verificata sha256** contro il record del segmento prima della pubblicazione; su mismatch il nastro
viene marcato SUSPECT con `read_errors+1` (stessa regola di `write_copy` per le scritture) e si passa
alla copia successiva. Solo se **tutte** le copie falliscono viene pubblicato il marker
`staged_<chunk>.ERROR` con motivazione esplicita ("no readable verified copy").

## Il fix (cluster)

`bric-restore` ora riporta la motivazione del marker ERROR del daemon invece del fuorviante
"staged blob missing". L'HMAC check del cluster resta invariato: è l'ultima linea di difesa.

## Il test di sicurezza andava aggiornato, non il fix

`run_security.sh` test 2 corrompeva la sola PRIMARY e **pretendeva che il restore fallisse** —
codificava il comportamento difettoso. Riscritto in due asserzioni più forti:

- **2a (auto-heal)**: PRIMARY manomessa su nastro → il restore riesce trasparentemente dalla BACKUP,
  file bit-identico, nastro manomesso marcato SUSPECT.
- **2b (tape server compromesso)**: l'attaccante riscrive il blob **e** aggiorna
  `segments.payload_sha256` per farlo combaciare — il daemon stagea convinto, e il **cluster**
  rifiuta con HMAC mismatch prima del decrypt. È il vero test end-to-end dell'Encrypt-then-MAC:
  senza la chiave utente l'HMAC non si forgia, nemmeno controllando l'intero tape server.

## Nuovo test dedicato

`run_restore_fallback.sh`: (A) PRIMARY corrotta → restore OK dalla BACKUP + SUSPECT + read_errors=1;
(B) file su nastro fisicamente illeggibile → restore OK e **daemon vivo**; (C) entrambe le copie
distrutte → fallimento con la motivazione esplicita del daemon, e daemon ancora vivo.

## Nota di riproducibilità

Durante la validazione, due falsi allarmi su `run_daemon_crash` sono risultati ambientali (sandbox
lenta/reset a metà esecuzione: il daemon aveva scritto 0 copie nella finestra di 4 s prima del kill).
La riproduzione strumentata e la riesecuzione isolata passano; nessuna regressione dal fix.
