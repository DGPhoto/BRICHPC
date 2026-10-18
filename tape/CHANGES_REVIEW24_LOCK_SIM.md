# CHANGES — Review-24 (il lock del singleton: fix esteso al ramo SIM; causa confermata dal diag)

Il diagnostico eseguito su supekgate ha CHIUSO la questione del timeout di daemon_crash:

    -- chi tiene il lock DOPO il kill:  3641329
    -- il daemon B riuscirebbe a prendere il lock ADESSO?
       NO -> lock TENUTO da orfano: E' QUESTA la causa del timeout 300s

## Causa, ora certa e riprodotta

Quando il daemon (padre) viene ucciso, un figlio forkato in un command-substitution
( `fn="$(tape_append_file ...)"` ) sopravvive come **orfano** tenendo l'fd 9 EREDITATO — il flock
del singleton. Il daemon di recovery parte, trova il lock tenuto, si rifiuta ("another daemon
holds ..."), e il run va in stallo fino al drain timeout (300s). Confermato: bash 4.4/kernel el8
(supekgate) via il diag; e riprodotto anche sul mio bash 5.2 (la volta scorsa passava solo per
timing fortunato — il meccanismo è identico e universale).

## Perché il fix di review22/23 non bastava

Quel fix chiudeva l'fd 9 nei subshell del ramo **REAL** della lib IO (dd/mtx). Ma
`run_daemon_crash` e il daemon del CLUSTER girano in backend **SIM**, che non entra in quei
subshell: usa `cp`/`find` nel corpo della funzione. Il ramo sim non era coperto. (Su brictape con
IO nastro reale il fix real contava; su supekgate/sim no — da qui il FAIL solo lì.)

## Fix

`tape_append_file`, ramo sim: chiude l'fd 9 come primo atto ( `{ exec 9>&-; } 2>/dev/null || true` ).
È SICURO perché la funzione è invocata solo da command-substitution (verificato su tutto il
codebase): la chiusura tocca la copia dell'fd nel subshell del `$(...)`, non quella del daemon; se
un kill orfana quel subshell, non trattiene più il lock. Guardato: no-op se il chiamante non ha
fd 9 aperto (es. run_vtl che chiama la funzione direttamente in backend real — path diverso,
comunque innocuo).

Metodo verificato: cloexec via fcntl NON basta (il command-subst forka bash senza exec, eredita
l'fd comunque); l'unica via portabile è la chiusura esplicita nel subshell — dimostrato con test
mirati su bash 5.2.

## Regressione (già presente, ora efficace)

`run_daemon_crash.sh` asserisce direttamente che daemonB NON sia stato rifiutato con "another
daemon holds". Prima del fix, sotto la riproduzione del meccanismo, falliva lì; ora passa pulito
(EXIT=0, 0 contese) su run isolati ripetuti.

## Validazione — inclusa la prova che mancava

- 30/30 sotto OpenSSL 3.x.
- Suite crypto (bus_signing, close_hardening, crypto_params, escrow, security, setup_e2e,
  require_signing) + daemon_crash sotto **OpenSSL 1.1.1 SIMULATO** (wrapper che rifiuta
  `pkeyutl -rawin` e si spaccia per 1.1.1k): PASS. Questa validazione sotto-1.1.1 è ora parte del
  processo per ogni tocco a firma/lock.
- IO/backup (local_e2e, real_e2e, vtl, real_backend_mock, posix, close_faultinj, partial_pair,
  restore_fallback): 8/8 — il fix non tocca il percorso caldo di scrittura.

## Nota di processo

Due errori miei in questa vicenda, entrambi per non aver riprodotto l'ambiente di David:
(1) test con `pkeyutl -rawin` che passavano solo dove `-rawin` esiste (review23);
(2) fix del lock nel solo ramo real quando il test/cluster gira in sim. Correttivo permanente: il
wrapper 1.1.1 e i test daemon_crash ripetuti fanno ora parte della checklist prima di ogni
consegna che tocchi crypto o locking.
