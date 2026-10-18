# CHANGES — Review-16 (bric-setup legge il config + fix di precedenza del loader)

Suite: **28/28** come root; campione critico riconfermato come non-root.

## La domanda e la risposta

"bric-setup.sh legge i file di config?" — **No, non li leggeva**: usava solo ambiente + i default
del blocco SITE. Divario di coerenza concreto: un `/etc/bric/bric.conf` con (es.) `BRIC_QNAP`
diverso dal default avrebbe fatto provisionare a setup percorsi (bus, DB, chiavi) DIVERSI da quelli
che il runtime avrebbe poi letto dal file.

## Fix 1: setup carica il config con le stesse semantiche del runtime

`bric-setup.sh` ora sourcia la `lib_common` adiacente (cluster, fallback tape, warn se assente) —
verificata priva di side effect al source — PRIMA del blocco SITE. Precedenza risultante identica
al runtime: **ambiente > /etc/bric/bric.conf > default SITE**. `--dry-run` riflette i valori dal
file (asserito dal nuovo scenario F del test).

## Fix 2 (scoperto validando): il loader girava DOPO i default di sito delle lib

Bug di precedenza della Review-13 rimasto invisibile: in entrambe le `lib_common`, le assegnazioni
`: "${VAR:=default}"` di sito (BRIC_HOME, BRIC_DB, BRIC_QNAP, BRIC_KEYS, ...) stavano PRIMA della
chiamata a `bric_load_config` → per quelle variabili il file non poteva MAI applicarsi (il loader
le vedeva già settate e le saltava). Il test di Review-13 non lo copriva perché asseriva solo
variabili prive di default. Riordinate entrambe le lib (lockstep): loader prima, default dopo, con
commento `site defaults (AFTER the config file: env > file > these)`.

## Test

`run_config_file.sh` esteso: (A) ora asserisce anche una variabile CON default di sito
(`BRIC_QNAP`) caricata dal file — la regressione del Fix 2; (F) `bric-setup --dry-run` riflette il
valore dal file, e l'ambiente continua a vincere anche in setup.

## Nota di processo

Due miei errori operativi durante il batch, entrambi beccati dalla verifica immediata: un edit
python abortito su assert prima della write (nulla applicato, riprovato con ancore esatte) e un
sed che ha rotto il quoting di una riga slittata (riparato e ri-testato). La regola resta: nessun
"fatto" senza un'esecuzione verde dopo.
