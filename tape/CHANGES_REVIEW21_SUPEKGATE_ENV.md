# CHANGES — Review-21 (supekgate: ambiente più vecchio — Python 3.6, firma bus non funzionante)

Contesto: suite **30/30 su brictape**, **25/30 su supekgate**. I 5 FAIL hanno DUE cause, entrambe
ambientali (supekgate è su una distribuzione più vecchia), non regressioni del codice.

## Causa A — Python 3.6: `ThreadingHTTPServer` non esiste (run_web_restore_async)

`ThreadingHTTPServer` è stato introdotto in Python 3.7; supekgate ha 3.6 (default della famiglia
RHEL). **Fixato**: import con fallback che ricostruisce la classe equivalente
(`socketserver.ThreadingMixIn` + `HTTPServer`, `daemon_threads = True`). Verificato simulando
l'assenza del simbolo: il server si istanzia e ha daemon_threads attivo. Nessuna dipendenza da un
interprete più recente sul lato cluster.

## Causa B — la firma Ed25519 del bus fallisce (bus_signing, close_hardening, setup_e2e, e con
ogni probabilità il timeout di daemon_crash)

`ERROR: bus signing failed for marker run.RESERVE_REQUEST`. Le chiavi vengono **generate**
correttamente (`openssl genpkey -algorithm ed25519` riesce) ma `openssl pkeyutl -sign -rawin`
fallisce. La causa esatta non è determinabile dai log perché **l'errore di openssl era buttato in
`/dev/null`**. Due difetti nostri hanno reso il guasto non diagnosticabile, entrambi corretti:

1. **`marker_set_signed` ingoiava lo stderr di openssl.** Ora il `die` riporta la ragione vera di
   OpenSSL, la sua versione e la dimensione del file chiave. Verificato firmando con una chiave
   corrotta: il messaggio ora contiene `OpenSSL 3.0.13 ...` e `Could not read private key ...
   pkeyutl: Error initializing context`. Applicato in **lockstep** su entrambe le lib_common.
2. **`run_bus_signing.sh` dava un falso OK.** Asseriva solo l'ESISTENZA dei quattro file
   (`[ -f ... ]`), quindi dichiarava "both Ed25519 key pairs generated" su un host dove le chiavi
   non erano utilizzabili, spostando il guasto molto più avanti. Ora esegue un **round trip
   sign+verify** reale e, se fallisce, stampa la versione di OpenSSL e il suo errore, aggiungendo
   che `require_bus_signing=1` bloccherebbe ogni run su quell'host.

## Da eseguire su supekgate per chiudere la causa B

`bric_diag_supekgate.sh` (read-only): stampa versione OpenSSL/Python, stato FIPS, e prova in
sequenza genpkey → firma con `-rawin` → verifica → firma senza `-rawin`. L'output identifica se
si tratta di OpenSSL troppo vecchio per Ed25519, di modalità FIPS (Ed25519 non è FIPS-approvato e
viene rifiutato in firma), o dell'opzione `-rawin` non supportata.

## Nota su run_daemon_crash (300 s, timeout del runner)

Su brictape passa in 13 s. Non ancora spiegato: potrebbe essere conseguenza della causa B (il
backup di ripristino non completa mai e resta in attesa fino al drain timeout) oppure il flake già
osservato in sandbox sotto carico. Da rivalutare dopo il fix della firma, eseguendolo isolato.

## Validazione

Regressione su bus_signing, close_hardening, setup_e2e, require_signing, local_e2e, security,
web_restore_async: tutti PASS. Fallback Python verificato simulando Python 3.6.
