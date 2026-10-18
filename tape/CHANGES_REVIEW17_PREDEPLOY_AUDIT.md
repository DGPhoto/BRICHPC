# CHANGES — Review-17 (audit pre-deploy: variabili, setup e2e, suite integrale)

Suite: **29/29 come root** (28 + il nuovo `run_setup_e2e.sh`); campione critico come non-root
tutto verde (daemon_crash flake ambientale del sandbox al primo giro, PASS isolato).

## 1. Audit delle variabili (config ↔ codice)

Verifica incrociata `bric.conf.example` vs tutte le `BRIC_*` usate: **zero duplicati, zero
variabili morte nel file, zero variabili deployabili mancanti** (le assenti sono le categorie
dichiarate: per-invocazione, setup-time, fault hook, meta). Due difetti trovati e corretti:

- **`BRIC_CHANGER_DEVICE`** in bric-setup: nome divergente dal canonico `BRIC_CHANGER` del
  runtime. Un `BRIC_CHANGER` nel bric.conf sarebbe stato ignorato da setup, che avrebbe stampato
  e registrato nel DB un changer diverso da quello reale. Unificato su `BRIC_CHANGER`
  (la chiave informativa `changer_device` nel DB resta, ora col valore giusto; nessun consumer
  runtime la legge).
- **Default del conf.example non veritieri**: il file dichiara "shown at its DEFAULT" ma 8 valori
  non corrispondevano ai default compilati (BRIC_HOME, BRIC_DB, BRIC_SQL_INIT, BRIC_KEYS,
  BRIC_RUNSTATE, BRIC_QNAP, BRIC_TAPE_HOME/DB/SQL_INIT, lock). Riallineati; per i lock il default
  vero (/tmp, /var/lock) è mostrato con l'override `/run/bric/` marcato esplicitamente come
  RACCOMANDATO in produzione, non come default.

## 2. Nuovo test: `run_setup_e2e.sh` — "il setup è corretto?" ora ha una prova

Nessun test esercitava bric-setup. Il nuovo test fa il provisioning VERO (non dry) via config
file: (A) DBs creati ai path del file, 4 nastri con parità rispettata, utenti con escrow
autenticato + handout; (B) **idempotenza**: secondo run → zero duplicati, chiavi NON ruotate;
(C) il sistema provisionato FUNZIONA: backup CLOSED → restore bit-identico → DR dai soli
nastri+chiave, **con la firma obbligatoria del bus attiva** (setup genera le chiavi e la abilita:
il test distribuisce le chiavi esattamente come le istruzioni di setup prescrivono);
(D) l'ambiente vince sul file anche in setup.

## 3. Bug di setup trovato dal test: registrazione batch rotta

`for u in $users` girava sotto l'`IFS=$'\n\t'` di setup: la lista spazio-separata NON veniva
splittata e l'intera stringa `' vsz652 alice9 '` finiva a register-user come UN nome (→ die
"invalid user name"). Stessa classe di bug del quickcheck (Review-11). Fix strutturale, non
rattoppo: setup ora **delega al batch canonico** `bric-register-user --users-file` (il loop di
setup era una seconda implementazione della registrazione batch — rimossa per regola).

## Verdetto pre-deploy

Variabili: dichiarate una volta, consumate correttamente, default veritieri. Setup: provato
end-to-end incluso idempotenza e pipeline completa. Suite: 29/29. Restano le fasi hardware
(preflight reale, smoke su scratch, collaudo) che per definizione si fanno sul ferro.
