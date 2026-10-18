# CHANGES — Review-14 (generazione chiavi utente: estensione del canonico, non un secondo script)

Suite: **29/29** (28 + il nuovo `run_register_user.sh`).

## Decisione

Richiesto "uno script per la generazione delle chiavi utente": esiste già ed è
`bric-register-user.sh` (32 byte random → base64, chmod 600, escrow autenticato v2 con la master
key, self-check di unwrap). Creare un secondo generatore avrebbe violato la regola "mai una seconda
implementazione" e aperto il rischio peggiore possibile: un percorso di generazione SENZA escrow,
cioè utenti senza break-glass. Si estende il canonico con ciò che mancava davvero.

## Estensioni a `bric-register-user.sh`

1. **`--users-file FILE`** (batch): un nome per riga, commenti `#` e righe vuote ignorati; ogni
   utente registrato re-invocando lo stesso script — il batch è un loop sul canonico, non un
   secondo path. Exit code aggregato (1 se almeno una registrazione fallisce).
2. **Scheda di consegna (`handout`)**, generata di default in `$BRIC_KEYS/handouts/
   <user>_key_handout.txt` (mode 600; directory alternativa con `--handout DIR`, soppressione con
   `--no-handout`, default globale via `BRIC_HANDOUTS`). Testo semplice e stampabile — leggibile
   fra 15 anni — con: la riga della chiave, cosa è, le tre regole di custodia (stampare e tenere
   FUORI dall'università; opzionale password manager; mai email/chat, mai accanto ai nastri),
   cosa succede se la si perde (break-glass; con entrambe le chiavi perse i dati sono
   matematicamente irrecuperabili, by design), e il one-liner di DR d'emergenza.
   Razionale: la tesi è "nastri + chiave UTENTE" — è vera solo se la chiave ce l'ha *l'utente*,
   non solo il cluster. La scheda è l'atto di consegna; va stampata, consegnata e poi cancellata.

## Test: `run_register_user.sh` (6 scenari)

(A) registrazione fresca: chiave 600/44-char base64, escrow v2 presente e **unwrappato in modo
indipendente** con la sola ricetta documentata (HMAC verificato, openssl round-trip alla chiave
esatta — non passando dal tool); (B) handout con chiave, istruzioni DR e regole di custodia;
(C) idempotenza: il re-run NON ruota la chiave; (D) batch: 3 utenti, commenti ignorati, ognuno con
escrow+handout; (E) `--no-handout`; (F) prova end-to-end: una chiave generata qui archivia e
disaster-recovera un progetto bit-identico.

## Nota di processo

Il primo tentativo di edit (batch python con due replace) è abortito su un assert DOPO il primo
replace ma PRIMA della write: il file è rimasto senza il parsing delle nuove opzioni mentre il
blocco handout (aggiunto con un edit separato) c'era — da cui i FAIL D/E alla prima esecuzione del
test. Riapplicato il parsing, 29/29. Lezione ribadita: verificare sempre l'esito eseguendo, mai
fidarsi del "replaced" a video.
