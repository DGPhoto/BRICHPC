# CHANGES — Review-7 (costo DR reale, guardia di quiescenza, fallback TOC, continuità post-rebuild)

Batch che implementa i quattro punti aperti dalla review esterna del Review-6, in ordine di priorità.
Suite: **22/22** (21 esistenti + il nuovo `run_resilience_continuity.sh`).

## 1. `tape_sniff_first_block`: lo scan del TOC non legge più file interi (CRITICO sul backend reale)

Il backward scan del Review-6 era corretto ma, sul backend `real`, riconoscere un candidato con
`tape_read_file` significava leggere il file **intero**: un candidato non-TOC è un blob da ~980 GB →
ore di nastro e ~1 TB di scratch **per tentativo**. Nuova primitiva in `lib_tape_io.sh`:
`tape_sniff_first_block VT FILENO DEST` legge **un solo blocco** (`dd count=1` dopo il posizionamento;
`head -c` in sim). DR e rebuild ora: sniff del primo blocco → match dell'header → solo allora lettura
completa. Costo per candidato: un `fsf` + 256 KiB. Con ~18 chunk/nastro lo scan resta minuti per
cartuccia, non giorni. Costo documentato nel README (nuova sezione "Costo del DR su hardware reale").

## 2. Guardia di quiescenza della sorgente (size+mtime, abort su deriva)

L'assunzione documentata al Review-6 ("sorgente quiescente dal plan alla produzione") ora è
**imposta**, non solo dichiarata:

- `cluster_init.sql`: colonna `files.mtime` (stat `%Y` al planning; NULL per dir/symlink).
  **Migrazione per DB esistenti**: `ALTER TABLE files ADD COLUMN mtime INTEGER;` (i run già
  pianificati senza mtime degradano con grazia: la guardia salta il confronto mtime, mantiene size).
- `bric-plan.sh`: una sola `stat -c'%s|%Y'` cattura size+mtime per ogni file regolare.
- `bric-chunk.sh`: `check_chunk_quiescent` riverifica ogni membro regolare del chunk contro il piano
  **prima** dello sha bookkeeping e **di nuovo dopo** tar/dd, prima di pubblicare il READY (la
  finestra di gara residua scende da "plan→produce", potenzialmente giorni su SLURM, a secondi).
  Ogni pezzo LARGE riverifica l'intero file (i pezzi girano come task array in momenti diversi).
  Su deriva: chunk in ERROR con messaggio esplicito `quiescence violation: ...` e die.
- `bric-finalize.sh`: il reconcile iniziale ora include lo stato `ERROR` → il run fallisce **subito**
  (run.ABORTED firmato, reservation rilasciata) invece di aspettare il drain-timeout. Vale anche per
  i produce-fail preesistenti.
- Scelta deliberata: **niente inode** nella guardia. L'inode cambia legittimamente con snapshot,
  migrazioni e copie (Isilon): includerlo trasformerebbe una guardia di correttezza in una fonte di
  falsi positivi destinata a essere disattivata in blocco. Size+mtime coprono la classe di guasto
  reale (file che cambia contenuto) senza tassare le sorgenti legittimamente ricollocate.
- Sempre attiva, nessun flag: non è hardening opzionale contro un avversario, è un check di
  correttezza agganciato all'invariante 3 (una `stat` per membro, costo trascurabile).

## 3. Test: fallback su TOC corrotto

`run_resilience_continuity.sh` sezione B: due close sullo stesso nastro (due TOC), poi l'header
dell'**ultimo** TOC viene corrotto su ogni nastro. Asserzioni: il DR scavalca il TOC corrotto, trova
il precedente valido e recupera un file di run1 bit-identico; il file presente solo nel TOC corrotto
(run2) è riportato irrecuperabile — degradazione attesa e ora **caratterizzata da un test**, non solo
ragionata. Limite noto e documentato: se la corruzione risparmia l'header e colpisce il corpo, il TOC
viene accettato e le righe malformate scartate in silenzio (il TOC non porta un checksum di sé su
nastro; lo sha del TOC vive solo nel DB, assente in DR). Un trailer di integrità è una modifica di
formato → rimandata a BRIC-FORMAT-V2, coerentemente con la scelta già presa per l'header dei blob.
Mitigazioni esistenti: TOC cumulativi + copia speculare sull'altro nastro della coppia.

## 4. Test: continuità operativa sul catalogo ricostruito

`run_resilience_continuity.sh` sezione C: dopo run1+run2 il tape catalog viene distrutto e
ricostruito (`--verify`); un **nuovo daemon** parte sul catalogo ricostruito e serve un **nuovo run
APPEND** fino a CLOSED (reservation, drain, close, TOC cumulativo). Asserzioni: nessuna riga
`segments` duplicata (il fix del padding `seg_id` del Review-6 è ciò che lo rende possibile) e il DR
finale dai soli nastri ricostruisce l'albero completo dei tre run — attraversando l'era del catalogo
originale e quella del ricostruito. Il catalogo ricostruito non è solo *equivalente*: è
*indistinguibile* dal punto di vista operativo.

Nota emersa scrivendo il test: i barcode dell'harness devono seguire la convenzione di produzione
(`primary_parity=even`, pari=PRIMARY), altrimenti `pair_of()` del rebuild spezza la coppia in due
pair diversi e la reservation post-rebuild viene negata ("need 1 more tape pair"). È lo stesso
controllo da fare sul ferro reale prima del primo run: le etichette fisiche devono rispettare la
parità configurata (verifica con `mtx status` contro l'inventario).

## Sezione A del nuovo test (bonus)

La guardia di quiescenza è coperta end-to-end: plan → mutazione del file → produzione rifiutata,
chunk in ERROR con messaggio esplicito, run FAILED **senza** attendere il drain-timeout, reservation
RELEASED dal daemon via run.ABORTED.
