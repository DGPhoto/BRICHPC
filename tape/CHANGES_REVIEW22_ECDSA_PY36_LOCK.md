# CHANGES — Review-22 (supekgate su ambiente più vecchio: 3 fix + 1 bug reale del daemon)

Contesto: suite 30/30 su brictape, 25/30 su supekgate (RHEL 8: OpenSSL 1.1.1k, Python 3.6). I 5
FAIL avevano tre cause ambientali distinte più un bug reale del daemon che il timeout mascherava.

## Fix 1 — Python 3.6: ThreadingHTTPServer (run_web_restore_async)

Introdotto in Python 3.7; RHEL 8 ha 3.6. Import con fallback che ricostruisce la classe
(`socketserver.ThreadingMixIn` + `HTTPServer`, `daemon_threads=True`). Verificato simulando
l'assenza del simbolo.

## Fix 2 — firma del bus: Ed25519 → ECDSA P-256 (bus_signing, close_hardening, setup_e2e)

Diagnosi confermata sul ferro: OpenSSL 1.1.1k NON ha alcun percorso CLI per firmare Ed25519
(`pkeyutl -rawin` esiste solo da OpenSSL 3.0; `dgst -sign` rifiuta il keytype su ogni versione).
Migrato a **ECDSA P-256 su SHA-256** via `openssl dgst -sha256 -sign/-verify`, identico su 1.1.1 e
3.x. Cambiati: keygen (`genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256` + self-test
sign/verify), firma e verifica in ENTRAMBE le lib_common (lockstep), nomi chiave
(`*_bus_ed25519.*` → `*_bus_ecdsa_p256.*`), e ogni riferimento in setup/conf/README/ARCHITECTURE/
runbook/handbook.

Impatto sulla recuperabilità a 15 anni: **nessuno**. Le firme del bus sono transitorie — non
finiscono mai su nastro (gli artifact on-tape sono cataloghi/script/README/schema/TOC), la firma è
default-off, e l'input firmato canonico (BRIC-MARKER-V1: dominio + progetto/run/marker + corpo) è
invariato: cambia solo la primitiva che produce il .sig. La recuperabilità resta AES-256-CBC +
HMAC-SHA256. Tutte le proprietà anti-replay/relocation del bus restano verdi.

Difetti collaterali corretti nello stesso giro:
- `marker_set_signed` ingoiava lo stderr di openssl → "bus signing failed" era non
  diagnosticabile. Ora il die riporta errore reale di OpenSSL, versione e dimensione chiave.
- `run_bus_signing.sh` asseriva solo l'ESISTENZA dei file chiave (falso OK su un host dove le
  chiavi non sono usabili) → ora fa un round trip sign+verify reale.
- Il check di capacità di `bric-setup` provava la GENERAZIONE, non la FIRMA (stesso falso
  negativo) → ora prova sign+verify completo con l'errore di OpenSSL in mano.

## Fix 3 (BUG REALE del daemon) — il lock del singleton tenuto da un figlio orfano

`run_daemon_crash` andava in timeout (300 s) invece dei ~13 s di brictape. NON un flake: causa
reale con impatto in produzione. Quando il daemon viene ucciso/crasha mentre un `dd`/`mtx` di
scrittura nastro è in corso, quel sottoprocesso può sopravvivere qualche istante come **orfano**
tenendo aperto l'fd 9 EREDITATO — che è il flock del singleton. Il daemon di recovery parte, trova
il lock ancora tenuto, si rifiuta ("another daemon holds ..."), e l'intero run va in stallo fino al
drain timeout. Riprodotto in isolamento.

**Fix**: le funzioni di IO reale (`tape_append_file`/`read`/`sniff`) chiudono l'fd 9 come primo
atto del ramo real-backend — cioè dentro il subshell che il command-substitution chiamante ha già
forkato, PRIMA di ogni fork di dd/mt/mtx. Il flock resta valido (vive sull'fd 9 del daemon,
intatto); nessun figlio di IO può più ereditarlo. Verificato: dopo il fix il daemon di recovery
parte pulito, "nessuna contesa lock", run a CLOSED. Nota su bash: gli fd `{var}>` NON sono
close-on-exec e bash non espone O_CLOEXEC — la chiusura esplicita nel subshell corretto è l'unica
via portabile (1.1.1/RHEL8 e AlmaLinux).

Regressione dedicata in `run_daemon_crash.sh`: asserisce direttamente che daemonB NON sia stato
rifiutato con "another daemon holds" (diagnosi precisa della causa radice invece di un timeout
generico).

## Validazione

Suite **30/30**. IO nastro reale (real_e2e, real_backend_mock, vtl, tape_rebuild, restore_fallback,
partial_pair) 6/6 dopo la ricollocazione della chiusura fd. daemon_crash verde con la normale
quiescenza fra test; l'intermittenza residua nei batch ravvicinati è contaminazione del sandbox fra
run consecutivi (daemon del run precedente ancora in terminazione), non il bug — con quiescenza
adeguata non compare mai la contesa del lock.

## Da fare su supekgate al prossimo giro
1. Deploy review22 su ENTRAMBE le macchine.
2. **Rigenerare le chiavi del bus** con il nuovo `bric-bus-keygen` (nomi file cambiati:
   `*_bus_ecdsa_p256.*`) e ridistribuirle (ognuno la propria privata + la pubblica del peer).
   Le vecchie chiavi ed25519 non sono più usate.
3. Aggiornare BRIC_BUS_SIGN_KEY / BRIC_BUS_VERIFY_KEY in /etc/bric/bric.conf ai nuovi nomi.
4. `run_all_tests.sh` come utenza operativa: atteso 30/30 su entrambe.
