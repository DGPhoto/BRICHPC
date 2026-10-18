# BRIC Archive 2.0 — il modello mentale in una pagina

Questo file esiste per una ragione sola: tenere visibile il **nucleo concettuale** mentre il sistema
cresce. Se una review futura deve partire da un punto, parte da qui — non dai dodici `CHANGES_*.md`.

## La tesi

**È un archivio, non un backup.** La promessa è: i dati genomici devono essere recuperabili fra 10–15
anni dai **soli nastri + la chiave utente**, senza il cluster, senza il catalogo centrale, senza il
daemon, senza la QNAP, senza che BRIC o l'istituzione esistano ancora. Tutto il resto del sistema è il
*costo intrinseco* di questa promessa. Una funzionalità che non serve la tesi o un fallimento operativo
concreto non è "in più": è peso.

## Gli invarianti portanti

Tutta la correttezza poggia su questi. Sono pochi apposta. Se ne rompi uno, il sistema è rotto a
prescindere dal resto.

1. **Claim = rename atomico.** Prendere un chunk dal bus è un `rename` `.READY → .CLAIMED`: un solo
   vincitore, niente lock distribuiti. (Dipende dalle proprietà POSIX del filesystem condiviso —
   rename atomico, visibilità coerente, niente cache incoerenti; documentate nel README.)
2. **Un solo run attivo per progetto.** Imposto con un INSERT condizionale transazionale in `bric-plan`:
   due backup concorrenti dello stesso progetto non possono coesistere.
3. **Segmento indipendentemente verificabile e decifrabile.** Ogni chunk porta con sé ciphertext +
   `sha256(ct)` + `HMAC(ct)` + la ricetta di derivazione della chiave. Si apre e si verifica da solo,
   coi soli nastri e la chiave — è ciò che rende vera la tesi.
4. **Nastro append-only e assegnato a un progetto.** Una coppia contiene segmenti di più run dello stesso
   progetto; non viene condivisa tra progetti. L'indice non si riscrive: a ogni close si appende un nuovo
   `TAPE_TOC` cumulativo (costruito dalle sole righe VERIFIED). In disaster recovery vince l'**ultimo TOC valido** trovato scandendo il nastro
   a ritroso dall'EOD.
5. **Doppia copia PRIMARY + BACKUP.** Ogni chunk è scritto sui due supporti della coppia esplicitamente
   registrata nel catalogo (PRIMARY onsite + BACKUP destinato all'offsite quando pieno). Con due drive
   le copie scorrono in parallelo e in modo asincrono: ciascun drive ha readiness, I/O e unload
   indipendenti e può terminare molto prima dell'altro. Non esiste un requisito lockstep né un timeout
   basato sul primo drive che finisce. `DONE/CLOSED` restano però dietro una barriera: append, filemark,
   read-back **streaming** (conteggio byte esatto + SHA, senza staging locale del chunk) deve terminare
   su entrambi i lati e le cartucce devono tornare negli slot. Un readback incompleto/host-side non
   degrada la salute del media; solo un flusso di dimensione esatta con hash errato è corruzione media. Restore
   e DR provano PRIMARY e poi ripiegano su BACKUP: auto-healing trasparente.
6. **Encrypt-then-MAC: verifica prima di decifrare.** L'HMAC sul ciphertext è verificato *prima* di darlo
   a openssl/tar — niente decrypt cieco. Protegge da blob manomessi e da path-traversal in un colpo solo.
7. **Singleton + generation fence + recover.** Un solo daemon alla volta. Il daemon mantiene insieme il
   namespace singleton canonico e quelli storici noti; prima di `recover()` acquisisce anche tutti i
   work-fence di generazione, così un worker sopravvissuto a un crash/upgrade deve terminare prima che la
   nuova generazione tocchi catalogo o hardware. `recover()` abbandona poi i segmenti lasciati in `WRITING`,
   che verranno riclaimati e riscritti. Nessuna perdita.
8. **Il catalogo centrale non è l'unica verità.** Ogni nastro porta il proprio kit di recovery + il
   catalogo di progetto cifrato. Il tape catalog è **ricostruibile** dai nastri (`bric-tape-rebuild-catalog`,
   equivalenza asserita in CI) e i dati sono **recuperabili** senza alcun DB (`bric-dr-from-tapes`).
9. **Formato fissato e versionato.** `BRIC-FORMAT-V1`; parametri crypto pinnati e registrati (per-chunk +
   nel kit) così un V2 può evolvere senza rendere illeggibili i nastri V1; marker firmati con binding al path.
10. **Nessuna transizione senza traccia durevole.** Ogni processo e fase hardware produce eventi
   `BRICLOGv1` e raw stdout/stderr centralizzati: system/root sotto `/var/log/bric`, utenti reali sotto
   `/var/log/bric/users/<utente>` con ACL di sola lettura per gli amministratori e isolamento reciproco.
   `~/.bric/log` è soltanto fallback utente. Con `BRIC_REQUIRE_LOGGING=1` il sistema rifiuta di partire
   se primary e fallback sono indisponibili: un backup non può essere accettato senza traccia ricostruibile.

## I componenti (una riga ciascuno, e a quale invariante servono)

| Componente | Ruolo | Invarianti |
|---|---|---|
| `bric-stream-plan` | crea il run e riserva una prima capacità senza scansione per-file (local mode) | I2 |
| `bric-tar-stream` | riceve lo stream GNU tar, crea chunk tar indipendenti, cifra e cataloga ciò che è realmente archiviato | I2, I3, I6 |
| `bric-plan` | planner per-file legacy, mantenuto per la modalità Slurm finché non viene migrata allo streaming | I2 |
| `bric-chunk` | produce blob cifrati+autenticati, pubblica `.READY` firmati, finestra scorrevole (flow control) | I3, I6 |
| `bric-tape-daemon` | 3 pass: prenotazioni → drain → close | I1, I4, I5, I7 |
| `bric-finalize` | attende il drain, chiude il run, rilascia la prenotazione | I7 |
| `bric-close` | appende catalogo progetto cifrato + escrow già master-wrapped + kit; non legge la master | I3, I8, I9 |
| `bric-restore` | restore normale col catalogo: verify-before-decrypt, fallback PRIMARY→BACKUP | I5, I6 |
| `bric-dr-from-tapes` | DR dai soli nastri+chiave (intero progetto o `--file`); break-glass admin via escrow | I3, I5, I8 |
| `bric-tape-rebuild-catalog` | ricostruisce il tape catalog dai nastri | I8 |
| `bric-setup-user` / `bric-register-user` | onboarding root, chiave in home utente, escrow master autenticato e fail-closed | I3, I9 |
| `lib_common` | derivazione chiavi, marker firmati, wrap/unwrap escrow, logging durevole/failover | I3, I6, I9, I10 |
| `bric-bus-keygen` | chiavi ECDSA P-256 del bus — firma marker (**opzionale**, default off) | hardening |

## Le due macchine a stati

```
run     PLANNING → RESERVED → PRODUCING → DRAINING → CLOSING → CLOSED
                    └→ DENIED            (no prenotazione)
                       FAILED / CANCELLED / *_ABORTED  (firmato)

chunk   (bus, marker)   PRODUCED → READY → CLAIMED → DONE        (ERROR su fallimento)
        (tape segment)  WRITING → VERIFIED                       (ABANDONED su recover)
```

## La regola di estensione (il vero controllo di complessità)

Il rischio ormai non è il codice: è la complessità. Per tenerla sotto controllo, **ogni nuova
funzionalità deve giustificare il proprio costo cognitivo** agganciandosi a una di queste due cose:

- **(a)** un invariante qui sopra che rende esplicito o robusto, oppure
- **(b)** un fallimento operativo concreto e osservato.

Se non si aggancia né a (a) né a (b), per costruzione è un **candidato al taglio**, non un'aggiunta.

Due corollari, pagati già col sangue:

- **Mai una seconda implementazione della stessa cosa.** La duplicazione è costo cognitivo puro: due
  cose quasi-uguali divergono e il bug nasce nel punto in cui divergono (vedi l'incidente
  `restore_project_from_tapes.sh` parallelo a `bric-dr-from-tapes.sh`, poi rimosso). Estendi il canonico.
- **L'opzionale resta opzionale.** Bus signing / replay protection sono hardening contro un peer ostile
  sulla condivisione: esistono ma sono `require_bus_signing=0` di default, così non tassano il modello
  mentale di chi non ha quel threat model. Qualunque hardening futuro segua lo stesso patto.

## Project-scoped tape availability (Review 30E)

The library may contain unrelated, offsite, or temporarily incomplete pairs. A backup reservation
checks only the media required by its project: all pairs already assigned to that project plus the
minimum number of complete onsite EMPTY pairs needed to cover the requested bytes. With 18 TB LTO-9
and 0.30 TB headroom, a new 20 TB project reserves two pairs. Global library pair completeness is
not a production invariant.

## Root onboarding and key separation (Review 30F)

The institution master key is an administrative recovery secret, not a runtime dependency. Root
provisions a real NSS/AD user with `bric-setup-user`: one personal key is installed in that user's
home, the same key is stored only as authenticated escrow in the cluster catalog, and mismatch or
concurrent provisioning fails closed. User jobs propagate only the exact personal-key path.

Project close copies the already master-wrapped escrow ciphertext to tape as `user_key_escrow.v1`;
it never reads the master. Admin disaster recovery verifies the artifact and unwraps it with the
offline master. The user identity is the real OS/NSS account, so an unprivileged `BRIC_USER` override
cannot impersonate another archive owner.


## Review 30M — tar-driven one-pass local pipeline

In `BRIC_RUN_MODE=local` non esiste più una fase di planning per-file separata. `bric-stream-plan.sh` crea il run e riserva inizialmente una capacità minima; GNU tar attraversa il sorgente una sola volta e invia lo stream a `cluster/libexec/bric-tar-stream`. Il chunker statico:

- ricrea archivi `TAR_PART` indipendenti, chiusi sempre a un confine di membro tar;
- spezza soltanto un singolo file più grande del target in `LARGE_FILE_CHUNK` raw;
- calcola lo SHA-256 del plaintext mentre il file viene letto;
- cifra in streaming in formato compatibile con `openssl enc -aes-256-cbc -pbkdf2 -iter 10000`;
- aggiorna catalogo e marker soltanto dopo che il blob cifrato è completo;
- estende la prenotazione per coppie di nastri quando lo stream sta per superare la capacità già riservata;
- dereferenzia gli hard link in file regolari indipendenti; i file GNU sparse materialmente significativi sono preservati e raggruppati in TAR_PART GNU-sparse multi-member compatibili con BRIC-FORMAT-V1.

Il catalogo descrive quindi ciò che tar ha realmente letto, non una fotografia metadata raccolta molto tempo prima. La modalità Slurm conserva temporaneamente il planner precedente finché QNAP e catalog-controller non saranno disponibili sui compute node.

## Review 31B — source sparse/consistency semantics

The cluster producer does not infer sparse topology from `st_blocks`: remote/data-reduced filesystems can
report physical accounting that is not a hole map, while NFSv3 cannot expose server extents through
`SEEK_HOLE`. The tar-driven producer instead consumes GNU PAX 0.1 `GNU.sparse.map` records from its own
authoritative outer stream. Material sparse representations are batched by mapped data bytes; lightly
sparse representations rejoin the normal TAR_PART stream. The encrypted catalog records that byte content
is authoritative while source allocation topology is not guaranteed.

A sparse batch is re-read once by GNU tar. Its exact output stream is parsed and hashed while the same raw
bytes are simultaneously encrypted, so member hashes must match the first outer walk and no third source
read is needed. Source mutation is orthogonal: default `source_change_policy=strict` aborts; explicit
`record` accepts only GNU tar rc=1 consisting exclusively of `file changed as we read it` diagnostics and
catalogs every warning. rc>=2 or mixed/unclassified rc=1 remains fail-closed.

## Review 31 — source-scope integrity before append-only media

Before the tar-stream planner creates a reservation, the caller's exact included source scope is
traversed read-only. Regular files must be readable; directories must be listable and traversable.
Intentional omissions are explicit relative subtrees (`--exclude`) and are copied into the encrypted
project catalog together with the source-scan size denominator. A later tar read failure remains fatal:
BRIC never turns permission loss into silent data loss. The tape format remains V1.

After observable tape-daemon progress the bus is rescanned immediately rather than sleeping a whole
poll interval, so newly published READY work can start without a manufactured idle gap. When a pass
makes no progress, normal polling remains in force to avoid busy-looping on blocked work.


Review 31B1 records the direction of this uncertainty as `restore_allocation_effect=zero-ranges-may-restore-as-holes`. A dense/preallocated source range containing zeros can therefore be represented by GNU tar as a hole and restore sparsely; byte content remains identical, but original allocation intent is not guaranteed.

## Review 32B4 campaign-safety invariants

- `CLOSED` is irreversible: stale later abort/failure markers cannot de-terminalize a run or orphan
  already VERIFIED segments.
- Chunk-allocation correctness locks live in the dedicated host-local `BRIC_LOCAL_LOCK_DIR`, never in
  shared runstate or logging storage.
- Source scope has three distinct outcomes: an explicit `--exclude` is operator-declared scope; an
  unreadable included path is a warning followed by preflight failure; explicit `--force` converts
  only precisely identified unreadable paths into audited `force-unreadable` omissions and archives
  the rest. Unknown traversal/I/O failures remain fatal.
