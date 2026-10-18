# CHANGES — Review-8 (resume idempotente della coppia parziale)

Batch minimo e deliberatamente ultimo di questa serie. Suite: **23/23** (22 + il nuovo
`run_partial_pair_resume.sh`).

## Il fix

Un crash del daemon **tra** la scrittura PRIMARY (già VERIFIED) e la BACKUP lasciava, al reclaim del
chunk, una riscrittura **completa** di entrambe le copie: la copia sopravvissuta veniva sostituita
(`INSERT OR REPLACE` sullo stesso `seg_id`) e la vecchia diventava un orfano da ~1 TB sul nastro
append-only — spazio perso a ogni occorrenza, per una copia già perfettamente verificata.

`handle_chunk` ora distingue tre casi:

1. **Entrambe VERIFIED** → ripubblica il DONE (comportamento invariato).
2. **Esattamente una VERIFIED** → la **riusa**, ma solo se il suo `payload_sha256` registrato
   coincide con lo sha del meta firmato del blob (nel caso di crash coincidono per costruzione: il
   reclaim rinomina il marker, il blob sul bus non viene toccato). Scrive **solo** la copia mancante,
   obbligatoriamente sul **partner della stessa coppia** della copia sopravvissuta (previa verifica
   di salute e spazio del partner; se inutilizzabile → marker ERROR, problema da operatore).
   Su **qualunque** mismatch di sha → fallback alla riscrittura completa: sicurezza prima del nastro.
3. **Nessuna** → percorso pieno invariato.

## Fault injection

Nuovo hook `BRIC_FAULT_DIE_BETWEEN_COPIES` (stesso patto di `BRIC_FAULT_CLOSE_AFTER`: solo test,
inerte in produzione): il daemon muore deterministicamente tra le due copie, esattamente nella
finestra che il crash-test esistente colpiva solo per fortuna di timing.

## Test

`run_partial_pair_resume.sh`: fault → una sola PRIMARY VERIFIED e nessuna BACKUP → backdate del
`.CLAIMED` oltre il TTL → daemon pulito → asserzioni: riga PRIMARY **immutata** (stesso
volumetag#file_number, payload presente una sola volta sul nastro), BACKUP scritta sul partner della
stessa coppia, nessuna riga duplicata, run CLOSED, DR dai soli nastri bit-identico alla sorgente.

## Cosa NON è stato implementato, e perché (candidati al taglio dichiarati)

- **Deduplicazione hard link**: richiederebbe gestione dei link attraverso chunk diversi (i membri
  sono spartiti fra tar indipendenti) — complessità strutturale contro un costo solo di spazio, già
  documentato nel README. Non si aggancia a un fallimento osservato.
- **Trailer di integrità del TOC**: modifica di formato → BRIC-FORMAT-V2, come già deciso.
- **Property-based testing sistematico**: investimento giusto ma successivo al primo run di
  produzione; i fault hook esistenti (`CLOSE_AFTER`, `DIE_BETWEEN_COPIES`) sono i punti d'appoggio
  su cui costruirlo.
- **Unificazione dell'unwrap escrow tra DR e lib_common**: la duplicazione nel DR è deliberata (deve
  funzionare senza alcuna infrastruttura); resta l'obbligo di toccarle in coppia.
