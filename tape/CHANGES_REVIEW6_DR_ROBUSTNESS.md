# CHANGES — Review-6 (robustezza DR, coerenza rebuild, contabilità nastro)

Baseline: 21/21 test verdi. Tutti i difetti sotto sono stati **riprodotti** prima del fix e coperti da
nuove asserzioni di regressione; la suite chiude a 21/21 anche dopo i fix.

## 1. DR: finestra di scansione del TOC troppo piccola (GRAVE — rompeva la tesi)

`bric-dr-from-tapes` cercava il TOC solo negli ultimi **5** file del nastro (il rebuild negli ultimi 6).
Ma un run successivo (APPEND in corso, o crashato/abortito prima della close) appende blob chunk a
**entrambi** i nastri della coppia dopo l'ultimo TOC. Riprodotto: con 6 blob appesi dopo il TOC su
entrambi i nastri, il DR falliva con `catalog_project.enc not found on any tape` — progetto
**irrecuperabile** dai nastri pur avendo dati e TOC fisicamente presenti. Fix: scansione a ritroso
dall'EOD **fino al file 1** (il DR è raro; la correttezza vale il tempo di lettura), sniffando solo la
prima riga dei candidati (niente warning NUL sui blob binari). Applicato anche a
`bric-tape-rebuild-catalog`. Regressione in `run_dr_e2e.sh` (6 blob spuri su ogni nastro prima del DR).

## 2. DR: ordine di estrazione — chunk di metadati prima dei file grandi (GRAVE per utenti non-root)

Il DR full-project estraeva tutti i TAR_PART (incluso il chunk di metadati finale, che ripristina i
permessi delle directory) e **poi** riassemblava i LARGE_FILE_CHUNK. Una directory read-only (es.
dataset "congelato" `chmod 555`) contenente un file > segment_target veniva quindi resa r-x **prima**
della scrittura del file → `Permission denied` per qualunque utente non-root (riprodotto con `runuser
-u nobody`). `bric-restore` era già corretto (ordine `chunk_no` interleaved). Fix: il DR ora processa
tutti i chunk del run in ordine `chunk_no`, per tipo, come il restore — il chunk di metadati arriva
ultimo. In più: il primo pezzo di un file grande tronca il file anche se la lettura fallisce (mai
append su contenuto stantio). Regressione in `run_dr_e2e.sh`: DR rieseguito come utente non
privilegiato su un dataset con `frozen/` 555 + file grande.

## 3. DR: ordine dei run deterministico (latest wins)

Il loop sui run era `SELECT DISTINCT run_id ... ` **senza ORDER BY**: se lo stesso path esiste in più
run con contenuto diverso, il contenuto finale dipendeva dall'ordine di ritorno del query planner.
Fix: `ORDER BY run_id` (lessicografico == cronologico per costruzione: `project__UTCstamp__counter`),
così l'ultimo run vince deterministicamente — stessa semantica del `--file`, che già faceva
`ORDER BY run_id DESC`.

## 4. DR: verifica sha256 dei cataloghi PRIMA del decrypt (I6 esteso ai cataloghi)

`catalog_project.enc` / `catalog_system.enc` venivano decifrati senza alcun controllo di integrità,
mentre il TOC in chiaro ne registra già lo sha256. Con CBC, una corruzione media in mezzo al file può
decifrare con padding valido e produrre SQL sottilmente corrotto. Fix: sha256 del blob confrontato con
il TOC prima di darlo a openssl; su mismatch il DR muore con l'indicazione di provare l'altro nastro
della coppia. (È uno sha, non un HMAC: protegge dal bit-rot, che è la minaccia reale qui; l'attaccante
con accesso in scrittura ai nastri è fuori dal threat model dei cataloghi in chiaro/TOC.)

## 5. Rebuild: seg_id ricostruito con formato divergente (il bug "seconda implementazione")

Il daemon crea `<run>__c%04d__<ROLE>` (chunk zero-padded); il rebuild creava `<run>__c<N>__<ROLE>`
senza padding. Su un catalogo ricostruito, un successivo `INSERT OR REPLACE` del daemon avrebbe creato
righe **duplicate** per lo stesso segmento fisico invece di sostituirle (doppie voci nel TOC, doppia
contabilità). Il test di equivalenza non lo vedeva perché la proiezione escludeva `seg_id`. Fix:
padding nel rebuild + `seg_id` incluso nella proiezione di `run_tape_rebuild.sh` (il diff ora è
byte-identico id compresi).

## 6. Rebuild: status del nastro con --verify

I nastri ricostruiti erano sempre `PARTIAL`, anche se fisicamente pieni: con `used_tb` noto (--verify)
lo status ora è ricalcolato con la stessa regola del daemon (capacity − headroom − used < chunk_target
→ FULL). Senza `--verify` resta PARTIAL con `used_tb=0`: riprendere le SCRITTURE su un catalogo
ricostruito senza `--verify` rischia l'overfill fisico — resta l'avvertenza nelle note finali.

## 7. Daemon: spazio nastro dei write falliti/abbandonati non contabilizzato

`write_copy` su verify-fail marcava il segmento ABANDONED e il nastro SUSPECT ma **non** incrementava
`used_tb` — eppure dati+filemark restano sul nastro append-only come orfani. Un solo chunk
abbandonato (~1 TB) supera l'headroom (0.30 TB): il check di eleggibilità sovrastimava lo spazio
libero e una scrittura successiva poteva incontrare il fine-nastro fisico. Fix: `used_tb` incrementato
anche sul path ABANDONED (stessa filosofia di contabilità onesta di `handle_abort`); `recover()` ora
contabilizza conservativamente anche i WRITING abbandonati al riavvio.

## 8. Documentazione e schema

- **ARCHITECTURE.md I5**: diceva "nastro **dispari** onsite + pari offsite" — contraddiceva config
  (`primary_parity=even`), setup e test (`pari=PRIMARY`). Corretto: pari onsite/PRIMARY, dispari
  offsite/BACKUP (BACKUP = PRIMARY+1).
- **ARCHITECTURE.md I4**: citava un `latest index_version` mai implementato; riscritto sul meccanismo
  reale (TAPE_TOC cumulativo, vince l'ultimo TOC valido a ritroso dall'EOD).
- **tape_init.sql**: rimossa la tabella `tape_index`, mai scritta né letta da alcun codice (regola di
  estensione: schema morto = candidato al taglio). Nota esplicativa al suo posto.
- **README**: documentate due assunzioni scoperte in review: (a) la sorgente deve essere quiescente
  dal plan alla fine della produzione (offset LARGE fissati al plan, sha calcolati alla produzione:
  un file che cambia nel mezzo produce una copia mista, rilevata solo al restore); (b) gli hard link
  non sono deduplicati (ogni link archiviato come file indipendente).

## Non toccato (segnalato soltanto)

- `handle_chunk` riscrive anche la copia PRIMARY già VERIFIED quando solo la BACKUP è andata persa in
  un crash (spreco di nastro, non un errore). Ottimizzabile saltando la copia già VERIFIED.
- Il DR duplica deliberatamente la logica di unwrap dell'escrow di `lib_common` (deve funzionare senza
  alcuna infrastruttura): divergenza da sorvegliare a ogni modifica dell'escrow.
