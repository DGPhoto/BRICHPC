# CHANGES — Review-23 (i test firmavano con pkeyutl -rawin: falso FAIL su OpenSSL 1.1.1)

Contesto: review22 su supekgate → 27/30, tre FAIL (bus_signing, close_hardening, daemon_crash).
brictape → 30/30. Stesso tarball. Due dei tre FAIL sono un MIO errore di test; il terzo è
ambientale e non ancora riproducibile qui.

## L'errore (mio) — i TEST usavano ancora `pkeyutl -rawin`

In review22 ho migrato il CODICE di produzione da Ed25519 (`pkeyutl -rawin`) a ECDSA P-256
(`dgst -sha256`), risolvendo il fatto che 1.1.1 non ha `-rawin`. Ma ho lasciato `pkeyutl -rawin`
in DUE punti dei test:
- `run_bus_signing.sh`: il probe di usabilità delle chiavi che avevo aggiunto in review21 — usava
  `pkeyutl -rawin`, la stessa primitiva assente su 1.1.1. Quindi su supekgate riportava "keys NOT
  usable" mentre il codice reale (`marker_set_signed`, che usa `dgst`) firmava benissimo: la prova
  è nel log stesso, "signed run reached CLOSED" e tutte le firme verdi SOTTO l'asserzione fallita.
- `run_close_hardening.sh`: l'helper `csign()` che simula la firma del cluster — idem.

Un probe di capacità DEVE esercitare lo stesso percorso del codice reale, non uno diverso.
Entrambi ora usano `openssl dgst -sha256 -sign/-verify`.

## Perché non l'avevo preso: il mio ambiente non riproduceva il tuo

La mia OpenSSL è 3.0.13, dove `pkeyutl -rawin` ESISTE — quindi i test passavano da me e
fallivano da te. Lezione applicata: ho creato un **wrapper che simula OpenSSL 1.1.1** (rifiuta
`pkeyutl -rawin`, riporta versione 1.1.1k) e ho rieseguito TUTTA la suite crypto sotto di esso.
Ora 10/10 di bus_signing/close_hardening/crypto_params/escrow/security/dr_e2e/setup_e2e/
require_signing/local_e2e/tape_rebuild passano sotto 1.1.1 simulato. Questa validazione è ora
parte del processo per ogni tocco alla firma.

## Caccia globale: nessun `pkeyutl` residuo attivo

`grep -rn pkeyutl` su cluster/tape/test/setup → solo commenti che spiegano perché NON si usa. Zero
invocazioni attive.

## Il terzo FAIL (daemon_crash, 300s su supekgate) — NON risolto, diagnostico allegato

Onestà: non riesco a riprodurlo. daemon_crash gira in backend SIM, quindi il fix del lock che ho
fatto (ramo REAL della lib IO) non lo tocca. Su brictape passa in 12s, su supekgate va a 300s a
parità di codice → è ambientale (bash/kernel/carico diversi). Ipotesi: un figlio del daemon ucciso
(cp/find del ramo sim, o altro) sopravvive tenendo l'fd 9 del lock, impedendo al daemon di recovery
di partire — ma su questo bash/kernel non lo provoco.

NON invento una toppa per un problema che non osservo. Allegato `bric_diag_daemoncrash_supekgate.sh`
(read-only): riproduce il nucleo del test con logging di `fuser` sul lock prima/dopo il kill, e dice
esplicitamente se un orfano tiene il lock su QUEL host. Con il suo output potrò scrivere il fix
mirato e verificabile.

Nota: il fix del lock del ramo REAL (chiusura fd 9 nei 4 subshell di IO) resta e conta per brictape
(IO nastro reale). Validato: real_e2e, vtl, real_backend_mock, daemon_crash tutti PASS.

## Validazione
30/30 sotto OpenSSL 3.x; 10/10 crypto sotto OpenSSL 1.1.1 SIMULATO (il test che mancava). Il fix
di daemon_crash su supekgate è rimandato al responso del diagnostico.
