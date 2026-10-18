# Runbook — prova di read-back su cartuccia SCRATCH (passo 3 del pre-flight)

Obiettivo: dimostrare, **a mano e su una sola cartuccia scratch**, che i parametri reali del drive/changer
(block size, filemark, posizionamento, append, fedeltà della lunghezza) combaciano con quelli che il
daemon userà. Finché questi gate non sono tutti verdi, **non** affidare dati veri a BRIC.

> ⚠️ **PERICOLO — questo runbook SCRIVE sul nastro.** Usa una cartuccia **scratch** (vuota o sacrificabile):
> la prova la sovrascrive. Non procedere se non sei certo che la cartuccia non contenga dati utili.
> Tutte le operazioni usano il device **non-riavvolgente** `/dev/nst0` (il posizionamento si conserva tra
> i comandi). Mai `/dev/st0` (riavvolge ad ogni close).

I comandi assumono i default del backend reale di BRIC:
`mt setblk 0` (block variabile), `dd bs=262144` (256 KiB), un filemark di flush scritto automaticamente
dal driver Linux quando `dd` chiude il device non-rewind dopo la scrittura, lettura del file N con
`rewind` + `fsf (N-1)`. **Non aggiungere `mt weof` dopo `dd`**: produrrebbe un secondo filemark e un file
vuoto. Se al tuo sito i device sono diversi, esporta prima:

```bash
CHANGER=/dev/sch0        # medium changer (BRIC_CHANGER)
DRIVE=/dev/nst0          # tape drive non-rewind (BRIC_DRIVE0)
BLK=262144               # block size dd (BRIC_TAPE_BLOCK)
SGDRIVE=/dev/sg0         # device generico del DRIVE, per tapeinfo (NON quello del changer)
```

---

## G0 — Identificazione hardware (nessuna scrittura)

```bash
lsscsi -g                       # elenca changer (mediumx) e tape (tape) con i loro /dev/sg* e /dev/nst*
mtx -f "$CHANGER" status        # stato libreria: Data Transfer Elements (drive) + Storage Elements (slot)
mt  -f "$DRIVE" status          # stato drive: deve rispondere (ONLINE quando c'è un nastro)
```

In `mtx status` individua:
- il **drive** (`Data Transfer Element 0`) e se è `Empty` o `Full`;
- lo **slot** della cartuccia scratch dal suo `VolumeTag` (l'etichetta a barre fisica).

> 🛈 **LTO-9 vergine**: al **primo** caricamento di una cartuccia mai usata il drive esegue
> l'ottimizzazione del supporto (calibrazione), che può durare **fino a ~1 ora** durante la quale il drive
> sembra "appeso". È normale: NON interrompere, NON resettare. Le cartucce già inizializzate caricano in secondi.

Esegui anche `tape/bin/bric-library-preflight`: deve confermare che `MT_ST_TWO_FM` e
`MT_ST_FAST_MTEOM` non siano abilitati per il drive.

**GATE G0** → vai avanti solo se: `mtx status` elenca changer + almeno un drive, e hai individuato lo slot
e il VolumeTag della cartuccia scratch. Annota: `SCRATCH_VT=...`, `SCRATCH_SLOT=...`, `DRV_ELEM=0`.

---

## G1 — Carica la scratch nel drive

```bash
SCRATCH_SLOT=<numero slot dalla status>
DRV_ELEM=0
mtx -f "$CHANGER" load "$SCRATCH_SLOT" "$DRV_ELEM"   # carica slot -> drive
mt  -f "$DRIVE" setblk 0                              # block size VARIABILE (preserva la lunghezza esatta)
mt  -f "$DRIVE" rewind
mt  -f "$DRIVE" status                               # atteso: ONLINE, "BOT" (begin of tape), block size 0
```

(Opzionale, consigliato per dati già cifrati/compressi — la compressione hardware è inutile su di essi:)
```bash
mt -f "$DRIVE" defcompression 0 2>/dev/null || true  # se il driver lo supporta
```

**GATE G1** → drive ONLINE, a BOT, block size variabile. Se `load` fallisce: slot/elemento errati, o un nastro
già nel drive (scaricalo con `mtx unload <slot> $DRV_ELEM`).

---

## G2 — Scrivi 3 file di prova con un solo filemark per file (come fa il daemon)

Ogni invocazione di `dd` apre il device non-rewind, scrive il payload e lo chiude. Il driver Linux `st`
scrive in quella `close()` un filemark di flush. Creiamo 3 payload con SHA noto, di cui uno di
**lunghezza dispari** (non multiplo del block) per provare la fedeltà esatta in modalità variabile.

```bash
W=$(mktemp -d)
dd if=/dev/urandom of="$W/f1.bin" bs=1M count=64 status=none        # 64 MiB (multiplo del block)
dd if=/dev/urandom of="$W/f2.bin" bs=1  count=$((37*1024*1024+12345)) status=none  # dispari, NON multiplo
head -c 4096 /dev/urandom > "$W/f3.bin"                              # piccolo (< block)
for f in f1 f2 f3; do sha256sum "$W/$f.bin"; done > "$W/expected.sha"
cat "$W/expected.sha"

# scrittura: rewind una volta, poi una dd per file. La close() di dd produce il filemark.
mt -f "$DRIVE" rewind
for f in f1 f2 f3; do
  dd if="$W/$f.bin" of="$DRIVE" bs="$BLK" status=none \
    || { echo "ERRORE scrittura $f"; break; }
done
mt -f "$DRIVE" status
```

**GATE G2** → tutte e tre le `dd` completano senza errore e `mt status` mostra `File number=3`. Un errore
`dd ... I/O error` qui = nastro
protetto in scrittura, drive da pulire, o supporto difettoso.

---

## G3 — Rileggi col POSIZIONAMENTO DEL DAEMON e confronta gli SHA

Per leggere il file **N** il daemon fa: `rewind` + `fsf (N-1)` + `dd`. Riproduciamolo identico.

```bash
R="$W/readback"; mkdir -p "$R"; pass=1; i=0
for f in f1 f2 f3; do
  i=$((i+1))                                  # N = numero file (1-based)
  mt -f "$DRIVE" rewind
  [ "$i" -gt 1 ] && mt -f "$DRIVE" fsf "$((i-1))"   # salta N-1 filemark
  dd if="$DRIVE" of="$R/$f.bin" bs="$BLK" status=none || { echo "ERRORE lettura $f"; pass=0; }
done
# confronto
( cd "$R" && sha256sum f1.bin f2.bin f3.bin ) > "$W/got.sha"
echo "--- atteso ---"; cat "$W/expected.sha" | awk '{print $1}'
echo "--- letto  ---"; cat "$W/got.sha"      | awk '{print $1}'
if [ "$(awk '{print $1}' "$W/expected.sha")" = "$(awk '{print $1}' "$W/got.sha")" ]; then
  echo "✓ G3 OK: i 3 file riletti hanno SHA identici (block, filemark, posizionamento e lunghezza esatta OK)"
else echo "✗ G3 FALLITO: differenza nei dati riletti"; pass=0; fi
```

**GATE G3** (il più importante) → tutti e tre gli SHA combaciano. In particolare `f2` (lunghezza dispari)
che combacia prova che la **modalità a blocco variabile preserva la lunghezza esatta** — requisito del
modello append-only di BRIC. Se differisce, vedi *Troubleshooting* in fondo.

---

## G4 — Append a fine dati (EOD) e rilettura del 4° file

Il daemon appende sempre a fine dati (`mt eod`) e ricava il numero file dal contatore del drive.

```bash
mt -f "$DRIVE" eod                              # posiziona dopo l'ultimo filemark (punto di append)
mt -f "$DRIVE" status                           # annota "File number" = numero di filemark visti (atteso 3)
head -c $((9*1024*1024)) /dev/urandom > "$W/f4.bin"; sha256sum "$W/f4.bin"
dd if="$W/f4.bin" of="$DRIVE" bs="$BLK" status=none
# rileggi il file 4
mt -f "$DRIVE" rewind; mt -f "$DRIVE" fsf 3
dd if="$DRIVE" of="$R/f4.bin" bs="$BLK" status=none
[ "$(sha256sum < "$W/f4.bin")" = "$(sha256sum < "$R/f4.bin")" ] \
  && echo "✓ G4 OK: append a EOD + rilettura del 4° file corretti" || echo "✗ G4 FALLITO"
# verifica il contatore EOD (quello che usa tape_last_file_number)
mt -f "$DRIVE" eod; mt -f "$DRIVE" status | grep -i "file number"   # atteso: 4
```

**GATE G4** → il 4° file si rilegge identico e il contatore a EOD è 4. Questo valida l'append append-only e
`tape_last_file_number` (che fa esattamente `eod` + lettura contatore).

---

## G5 — Salute del drive/supporto e scarico

```bash
tapeinfo -f "$SGDRIVE" 2>/dev/null || echo "(tapeinfo non disponibile: salta)"   # cerca TapeAlert flags
dmesg | tail -20                                  # nessun errore SCSI/medium recente atteso
mt -f "$DRIVE" rewind
mtx -f "$CHANGER" unload "$SCRATCH_SLOT" "$DRV_ELEM"   # riporta la cartuccia nel suo slot
rm -rf "$W"
```

**GATE G5** → nessun TapeAlert critico (es. *media*, *hardware*, *cleaning required*), nessun errore SCSI in
`dmesg`, unload OK. Se compare "cleaning required": carica la cleaning cartridge e ripeti.

---

## Esito

Se **G0–G5 sono tutti verdi**, i parametri del backend reale combaciano con quelli del daemon → puoi passare
al **passo 4** (un progetto piccolo e già copiato altrove, archivio+close reale), poi al **passo 5**
(restore + DR di verifica) prima di affidare qualunque dato come unica copia.

Dopo la prova manuale su ciascun drive, configura il daemon dual-drive con gli stessi parametri:
```bash
export BRIC_TAPE_BACKEND=real BRIC_CHANGER="$CHANGER" \
       BRIC_DRIVE0=/dev/nst0 BRIC_DRIVE1=/dev/nst1 \
       BRIC_TAPE_BLOCK="$BLK" BRIC_TAPE_DRIVES="0 1" BRIC_PARALLEL_DRIVES=2
```
Ripeti G1–G5 anche sul drive 1 prima del pilot di coppia. Tempi diversi sono ammessi: imposta, se
necessario, `BRIC_DRIVE_READY_TIMEOUT_0/1` e `BRIC_DRIVE_UNLOAD_TIMEOUT_0/1`; lo stato terminale BRIC
resta bloccato finché entrambe le cartucce sono state verificate e riportate negli slot.

---

## Troubleshooting (se G3/G4 falliscono)

| Sintomo | Causa probabile | Rimedio |
|---|---|---|
| SHA diverso ma stessa dimensione | block size non variabile su un lato | `mt setblk 0` PRIMA di ogni dd, in scrittura **e** lettura |
| Dati troncati / lunghezza diversa | block fisso o `bs` diverso tra write e read | usa lo stesso `bs=$BLK` e `setblk 0` ovunque |
| Leggo il file sbagliato | off-by-one nel posizionamento | per il file N: `rewind` + `fsf (N-1)` (non `fsf N`) |
| `dd: I/O error` in scrittura | nastro write-protected / drive da pulire / supporto guasto | leva il write-protect, pulisci, prova altra cartuccia |
| Primo `load` "appeso" a lungo | LTO-9 vergine in ottimizzazione | aspetta (fino a ~1 h), non interrompere |
| `mt: Device or resource busy` | un altro processo tiene il drive (daemon?) | ferma il daemon durante la prova manuale; il lock changer serializza |
| Compressione inattesa nei contatori capacità | compressione hardware on | irrilevante per la fedeltà; opzionale `mt defcompression 0` |
