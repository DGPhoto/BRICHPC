# CHANGES — Review-15b (dr_e2e: sezione unprivileged con repo sotto home 0700)

Origine: run come **root** su brictape con l'albero PRE-review15 (26/28). Dei due FAIL:

- `run_notifications` (scenario G "mail outcome missing"): già corretto in Review-15 — il log
  mostra il VECCHIO scenario G, che rimuoveva il mock esponendo il mailer reale di brictape.
  Nessuna azione: il review15 contiene il G ermetico + lo scenario H. Il run come root conferma
  peraltro la diagnosi di Review-15 al contrario: root schiva le cause non-root e passa quasi tutto.
- `run_dr_e2e` (✗ unprivileged DR FAILED): bug REALE del test, riprodotto e corretto qui.

## Il bug

La sezione unprivileged (attiva solo quando la suite gira da root) esegue il DR come `nobody`
**direttamente dal repo**. Su brictape il repo vive in `/home/vsz652` (0700): `nobody` non può
attraversare la home e fallisce con EACCES prima ancora che il DR parta — errore per giunta
silenziato (`>/dev/null 2>&1`). In sandbox non emergeva perché il repo stava sotto /tmp
world-readable.

## Il fix (e una scoperta)

1. La sezione ora esegue una **copia** del DR dal workroot world-readable. La prima versione del
   fix (copia del solo script) ha smascherato — grazie alla diagnostica non più silenziata — che
   `bric-dr-from-tapes.sh` NON è a zero source come da progetto dichiarato: sourcia
   `../../tape/scripts/lib_tape_io.sh` relativo a se stesso. La copia preserva quindi il layout
   (`drcopy/cluster/scripts/` + `drcopy/tape/scripts/`).
2. Lo stderr del DR unprivileged finisce in `$ROOT/dr_nobody.log` e le ultime righe vengono
   stampate in caso di FAIL: mai più un ✗ senza il perché.

Nota architetturale registrata: la dipendenza del DR da `lib_tape_io.sh` è corretta (è il reader
dei nastri) ma smentisce la dicitura "self-contained" usata in alcuni commenti/documenti; il kit
on-tape resta coerente perché `restore_from_tape.sh` (l'artifact del kit) è davvero standalone.

## Validazione

Tripla: (a) repo copiato sotto una directory 0700 (la condizione esatta di brictape) come root →
PASS con "unprivileged DR PASSED"; (b) albero normale come root → PASS; (c) come utente non-root →
PASS (sezione unprivileged correttamente saltata: richiede root).
