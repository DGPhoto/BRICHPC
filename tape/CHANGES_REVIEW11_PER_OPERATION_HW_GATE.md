# CHANGES — Review-11 (gate hardware per-operazione su backup e restore)

Suite: **26/26**.

## Cosa

`tape_hw_quickcheck` (nuova primitiva in `lib_tape_io.sh`): controllo **read-only, ~1-2 s** dello
stato dell'hardware — nodi dispositivo presenti, `mtx status` risponde, almeno un drive element
configurato visibile al changer, sense del changer NON nella condizione bloccante
0x02/04/03 "manual intervention required". No-op in sim. Escape hatch `BRIC_SKIP_HW_CHECK=1`
(loggato) per le sessioni di troubleshooting hardware in cui si vuole procedere comunque.

Invocato dal daemon **all'inizio di ogni operazione richiesta da un utente**, in subshell (mai
fatale per il daemon):

- **Backup** → in `handle_reservation`, prima di qualunque logica di capacità: se l'hardware non è
  pronto il run è **DENIED subito** con `reason=tape hardware not ready: <diagnosi>` — l'utente lo
  vede prima che venga prodotto un solo chunk.
- **Restore** → in `handle_restore`, prima della staging: `request.STAGED` pubblicato come
  `refused: tape hardware not ready: <diagnosi>`; `bric-restore` ora legge il corpo del marker
  STAGED e, se inizia con `refused:`, muore con quel motivo (prima sarebbe morto con un fuorviante
  "staged blob missing").

Deliberatamente **non** per-chunk: `_load` fallisce già rumorosamente a metà volo, e tassare il
percorso caldo con chiamate sg non aggiunge sicurezza. Il gate serve a non *iniziare* operazioni
contro hardware visibilmente rotto, con una diagnosi leggibile.

## Bug propri trovati e corretti durante la validazione

1. **IFS**: il daemon gira con `IFS=$'\n\t'`; il loop `for D in $BRIC_TAPE_DRIVES` nel quickcheck
   non splittava "0 1" e cercava il drive "/dev/nst0 1". Fix: `local IFS=$' \t\n'` nella funzione.
2. Il messaggio di `die` catturato portava il prefisso timestamp/ERROR del log dentro il marker
   DENIED: ora viene ripulito.
3. Il log "hw quickcheck passed" veniva catturato dalla subshell e scartato: ora è inoltrato.

## Regressione legittima in `run_real_e2e`

Il test usava `BRIC_CHANGER=/mock/sch0` **senza creare il nodo**: il gate lo ha correttamente
bloccato ("changer node missing"). Il test ora crea i nodi fittizi, così il gate viene
**esercitato** (asserito "hw quickcheck passed" nel log) invece che aggirato. Prova sul campo che
il gate morde davvero.

## Test

`run_library_preflight.sh` esteso con: (H) changer bloccato dal sense 04/03 → backup DENIED e
restore rifiutato *prima* dell'inizio, con la diagnosi nel marker, e daemon vivo (rc=0);
(I) hardware sano → il gate passa e l'eventuale DENIED è solo di capacità; "hw quickcheck passed"
presente nel log.
