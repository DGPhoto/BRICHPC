# CHANGES — Review-20 (il blocco SITE di bric-setup: cosa è vivo e cosa è morto)

Domanda di David: "perché setup non usa i valori del conf?", mostrando il blocco SITE.

## Risposta 1: li usa (dimostrato)

Con `/etc/bric/bric.conf` contenente `BRIC_QNAP` e `BRIC_HOME`, `bric-setup --dry-run` riporta i
valori del FILE, non i default. Il fix di Review-16 (setup sorgia lib_common, che esegue
`bric_load_config`, PRIMA del blocco SITE) funziona. Precedenza effettiva:

    ambiente > /etc/bric/bric.conf > default di lib_common > blocco SITE di setup

Le righe del blocco sono `: "${VAR:=...}"`: riempiono solo ciò che è ancora vuoto, quindi non
possono scavalcare il file.

## Risposta 2: però metà di quelle righe è irraggiungibile, e il banner mentiva

Il blocco era intestato `*** EDITA QUESTI VALORI PER IL TUO SITO PRIMA DI LANCIARE IN PRODUZIONE ***`.
Falso per metà delle variabili: lib_common viene sorgiata PRIMA e imposta già i suoi default, quindi

- con `--role cluster` / `--role all` (sorgia la lib del CLUSTER): `BRIC_HOME`, `BRIC_DB`,
  `BRIC_QNAP`, `BRIC_KEYS` arrivano dalla lib → **editarle in setup non produce alcun effetto**;
  restano effettive `BRIC_TAPE_HOME` e `BRIC_TAPE_DB` (che la lib cluster non conosce);
- con `--role tape` su un albero solo-tape (sorgia la lib del TAPE): si inverte.

Quale copia vinca dipende dal ruolo e dal layout dell'albero. Nessun bug di comportamento oggi —
ho verificato che tutti e sei i default duplicati sono **identici** — ma un operatore che edita il
blocco per cambiare un percorso non ottiene nulla e non riceve alcun avviso.

## Fix

1. **Banner riscritto e onesto**: il blocco non è più "SITE CONFIG" ma "SITE DEFAULTS — ultimo
   strato, NON il posto dove si configura il sito", con la catena di precedenza esplicita, l'elenco
   di quali variabili sono irraggiungibili in quale ruolo, e l'indicazione secca: per cambiare un
   percorso si edita `/etc/bric/bric.conf`.
2. **Lint anti-divergenza** (`run_config_file.sh` scenario G): per ogni variabile con un default sia
   in `bric-setup.sh` sia in una `lib_common`, i due testi devono essere IDENTICI. La divergenza è
   il caso pericoloso — una delle due copie diventa irraggiungibile in silenzio. Verificato che il
   lint fallisca davvero iniettando una divergenza su `BRIC_QNAP` (poi ripristinata): confronta 6
   default duplicati e li riporta col valore di entrambe le parti.

## Non fatto (deferred, dichiarato)

La correzione strutturale sarebbe un unico file di default sorgiato da entrambe le lib e da setup —
eliminando la terza dichiarazione degli stessi valori, come da regola "mai una seconda
implementazione". È un cambio allo startup di ogni script: **non da fare a ridosso del primo test
con dati reali**. Il lint copre nel frattempo il rischio concreto (divergenza silenziosa).

## Validazione

run_config_file 11/11 (incluso il nuovo lint, e la prova che fallisce su divergenza iniettata);
regressione su setup_e2e, local_e2e, register_user, escrow, posix: tutti PASS.
