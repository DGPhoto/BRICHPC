# CHANGES — Review-25 (wrapper operativo: modulo OpenSSL, mount da conf, drive; gate min 3.0)

Richiesta di David: modulo OpenSSL 3.5 su entrambi i nodi; wrapper backup/restore che carica il
modulo e verifica in preflight modulo+mount+drive; check del mount sulla variabile del conf;
versione minima OpenSSL 3.

## Nuovo wrapper: `cluster/bin/bric-run`

Layer davanti a `cluster/bin/bric` per l'operatività quotidiana. In testa ha la riga COMMENTATA
`# module load openssl/3.5.7` (da scommentare/adattare al nome del modulo di sito). Poi un
preflight read-only, quindi `exec bric "$@"`. Flag `--skip-preflight` per debug.

Preflight, tre check con verdetto unico (rifiuta con diagnosi se qualcosa non va):
1. **OpenSSL >= 3.0** — gate su un MINIMO, non su `3.*`: una futura 4.x è accettata
   automaticamente (le primitive `dgst -sha256` / `enc -pbkdf2` sono stabili e
   forward-compatible). Sotto 3.0 → rifiuto con hint `module load`. Verificato: 3.5 e 4.0 passano,
   1.1.1 è rifiutata.
2. **Mount NFS del bus** — verifica `BRIC_QNAP_MNT` (variabile GIA' presente nel conf e già usata
   da `cluster/slurm/healthcheck_qnap.sh` con `mountpoint -q` — riuso, non seconda
   implementazione). Se non montato → rifiuto. Se `BRIC_QNAP_MNT` non è impostata, fallback al
   parent di `BRIC_QNAP` con nota. Controlla anche fstype nfs e scrivibilità del bus.
3. **Drive tape ready & vuoti** — in backend `real` delega a `bric-library-preflight` (unica
   fonte per il probing SCSI) e in più esige che ogni drive configurato sia VUOTO (nessuna
   cartuccia caricata: un drive pieno = tape lasciato da un'operazione precedente). In `sim`
   salta pulito.

## Solo OPERATIVO, mai requisito di recupero — reso esplicito ovunque

Il gate ≥3.0 è per l'operatività (la firma del bus usa `dgst`, serve un openssl funzionante). La
RECUPERABILITÀ resta indipendente: formato blob parameter-pinned, apribile da qualunque OpenSSL
1.1.1+. Verificato in entrambi i sensi 1.1.1↔3.x. Scritto nero su bianco:
- nuova sezione nel RECOVERY_HANDBOOK ("Any OpenSSL 1.1.1 or later recovers these tapes — no
  version, no module");
- il test wrapper ha un caso D dedicato: il blob round-trippa sotto 1.1.1 simulato mentre il
  wrapper lo rifiuta — le due cose coesistono per design;
- setup: check versione allineato a ≥3.0, ma WARN (non die) sotto — non blocca chi ha 1.1.1.

## Conf + runbook

- `bric.conf.example`: `BRIC_QNAP_MNT` chiarita come "mount verificato da bric-run all'avvio".
- Runbook: 31 test (era 30); Fase 3 con `module load openssl/3.5.7` su ENTRAMBI i nodi e la nota
  operativo-vs-recupero; Fase 9 usa `bric-run backup/restore` (col preflight) per il primo run
  reale.

## Validazione

Suite 31/31 sotto OpenSSL 3.x. Test wrapper: 11/11 (gate min con 3.x/4.x/1.1.1, mount da conf nei
tre casi, drive sim/loaded, recuperabilità version-agnostica). Codice crypto sotto 1.1.1 SIMULATO:
4/4 (il codice gira su 1.1.1); il wrapper sotto 1.1.1 RIFIUTA con hint modulo — comportamento
voluto. Regressione setup/config/local_e2e verde.

## Nota di design (la scelta sul "minimo 3, retrocompatibile in futuro")

"Minimo 3.0" + accettazione di ogni major >= 3 è la forma giusta di retrocompatibilità in avanti:
non inseguo un pin esatto (che invecchierebbe), ma fisso il pavimento sotto cui so che manca il
percorso CLI per la firma. All'indietro, il recupero non ha pavimento affatto: 1.1.1 basta, ed è
documentato. Così l'operatività può salire (4.x, 5.x...) senza modifiche e il recupero non si
lega mai a una versione.
