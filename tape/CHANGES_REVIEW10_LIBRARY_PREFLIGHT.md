# CHANGES — Review-10 (ri-verifica completa + preflight dei dispositivi della library)

Suite: **26/26** (25 + il nuovo `run_library_preflight.sh`).

## 1. Ri-verifica completa (nessuna nuova regressione trovata)

- **shellcheck** (livello warning, esclusi gli stilistici SC2086/SC2034/SC1091) su tutti i file
  toccati nelle Review 6–9: pulito. Unico rilievo un SC2155 preesistente e cosmetico nel daemon
  (`local seg=` con command substitution: printf non ha return value significativo da mascherare).
- **Rilettura critica a tavolino** dei quattro edit più intricati, con esito:
  - *partial-pair resume*: verificati i tre edge case (entrambe le copie con sha divergente → full
    rewrite; una sola divergente → l'altra riusata e la divergente REPLACE-ata; partner FULL ma con
    spazio per il chunk specifico → scrittura permessa, deliberato: mantiene la coppia intatta).
  - *handle_restore*: heredoc annidati corretti, subshell di lettura corrette, ERROR marker solo a
    esaurimento copie. Una `local crow` inutilizzata (cosmetica, lasciata).
  - *guardia di quiescenza*: `$LIST` sempre definita nei rami che la usano; degradazione con grazia
    su run pianificati senza colonna mtime (salta il confronto mtime, mantiene size).
  - *loop DR per chunk_no*: ordine e troncamento verificati anche contro i test.
- **Suite integrale rieseguita**: 26/26.

## 2. Nuovo tool: `tape/bin/bric-library-preflight`

Health-check **non distruttivo** di changer e drive, da eseguire prima del primo run di produzione,
dopo ogni intervento hardware, o a fronte di comportamenti anomali. Non scrive su nastro, non muove
media, non tocca firmware. Otto controlli:

1. Presenza dei device node (`BRIC_CHANGER`, `BRIC_DRIVE<n>` per ogni elemento in `BRIC_TAPE_DRIVES`).
2. **SCSI inquiry** (`sg_inq`): vendor/product/**revisione firmware** di changer e drive, con
   **WARN esplicito se due drive hanno firmware diversi** (il classico post-sostituzione: S2S1 vs S2SD).
3. **Test Unit Ready** (`sg_turs`): il messaggio "bad pass-through setup" di alcune build di
   sg3_utils è riconosciuto come artefatto del tool, **WARN e non FAIL**.
4. **Sense data del changer** (`sg_requests`): rileva la condizione bloccante
   sense 0x02 / ASC 0x04 / ASCQ 0x03 "**manual intervention required**" e fallisce con istruzione
   esplicita all'operatore ("non avviare il daemon; power-cycle / caso hardware").
5. **Inventario mtx**: parse dello status, visibilità di ogni drive element configurato, lettura barcode.
6. **mt status** per ogni drive (con degradazione a WARN se il drive vuoto rifiuta lo status).
7. **Convenzione barcode**: formato NNNNNNL9, nessun duplicato, e **completezza delle coppie**
   (ogni nastro pari deve avere il partner +1 in library — FAIL, perché le reservation fallirebbero).
8. Cross-check opzionale col tape catalog (nastri nel DB ma non in library e viceversa; l'assenza
   di BACKUP offsite è riconosciuta come normale).

Exit code: 0 = pronto (eventuali warning elencati), 2 = almeno un FAIL. Su backend sim è un no-op
pulito con messaggio.

Uso sul MSL3040 (mappa dispositivi di produzione):
```
BRIC_TAPE_BACKEND=real BRIC_CHANGER=/dev/sg4 \
BRIC_DRIVE0=/dev/nst0 BRIC_DRIVE1=/dev/nst1 BRIC_TAPE_DRIVES="0 1" \
tape/bin/bric-library-preflight
```

## 3. Nuovo test: `test/run_library_preflight.sh`

Esercita il preflight contro **mock** di `mtx`/`mt`/`sg_inq`/`sg_turs`/`sg_requests`, coprendo in CI
i guasti reali osservabili su hardware classe MSL3040 senza l'hardware: (A) library sana → exit 0;
(B) changer bloccato in "manual intervention required" → exit 2 con diagnosi esplicita; (C) firmware
misto S2SD/S2S1 → WARN, non FAIL; (D) coppia incompleta (000002L9 senza 000003L9) → exit 2 col
partner mancante nominato; (E) artefatto sg_turs tollerato; (F) backend sim no-op. Su una macchina
con dispositivi reali e `BRIC_TAPE_BACKEND=real` preimpostato, lo scenario G esegue in aggiunta il
preflight read-only sull'hardware vero.
