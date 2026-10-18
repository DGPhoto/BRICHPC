# CHANGES — Review-13 (file di configurazione centrale)

Suite: **28/28** (27 + il nuovo `run_config_file.sh`).

## Cosa

Tutte le variabili settabili vivono ora in **un solo posto**: `/etc/bric/bric.conf`, lo stesso file
su entrambe le macchine (supekgate e brictape — ogni lato ignora le variabili dell'altro).
Il repo contiene `bric.conf.example` con **ogni** variabile documentata al suo default, raggruppata
(identità/percorsi, bus, timeout, notifiche, hardening, hardware, modello di capacità, safety
hatch), tutta commentata: si scommenta solo ciò che si cambia.

Installazione:
```
sudo install -d /etc/bric
sudo cp bric.conf.example /etc/bric/bric.conf && sudo chmod 644 /etc/bric/bric.conf
```
Per attivare le mail (la domanda che ha originato il batch) ora basta scommentare nel file:
`BRIC_NOTIFY_MAIL=auto`.

## Regole del loader (`bric_load_config`, eseguito al source di lib_common)

1. **Precedenza: l'ambiente vince sempre.** Il file riempie solo le variabili non già settate —
   export espliciti, `Environment=` di systemd e gli harness di test hanno sempre priorità.
2. **Parsato, mai eseguito.** Solo righe `BRIC_NOME=valore` (quote opzionali); chiavi non-BRIC,
   malformate, `PATH=`, `LD_PRELOAD=` e simili sono ignorate; una command substitution in un
   valore resta testo inerte. Il file non può eseguire codice — asserito dal test C.
3. **`BRIC_FAULT_*` rifiutate**: la fault injection non deve mai essere persistibile in un config.
4. Ricerca: `$BRIC_CONFIG` esplicito, altrimenti `/etc/bric/bric.conf`; il valore letterale
   `BRIC_CONFIG=none` disabilita del tutto il caricamento.

## Copia lockstep dichiarata

Il loader vive identico in `cluster/scripts/lib_common.sh` e `tape/scripts/lib_common.sh` (i due
host non condividono file a runtime). È la seconda duplicazione deliberata del progetto, dopo
l'unwrap escrow del DR, marcata con lo stesso commento-contratto: modificarle in coppia.

## Ermeticità della suite

Tutti i 28 test ora esportano `BRIC_CONFIG=none` in testa: un `/etc/bric/bric.conf` reale sulla
macchina non può mai influenzare un test (era il rischio concreto: un `BRIC_NOTIFY_MAIL=auto` di
produzione avrebbe riattivato lo spam di mail durante le suite).

## Test: `run_config_file.sh`

(A) i valori del file si applicano dove l'ambiente tace, su ENTRAMBE le lib; (B) l'ambiente vince;
(C) sicurezza del parser: FAULT rifiutate, injection inerte, nessuna esecuzione di codice;
(D) `none` disabilita; (E) e2e: un backup con `BRIC_NOTIFY_LOG` fornito dal solo file scrive
l'event log al percorso configurato.
