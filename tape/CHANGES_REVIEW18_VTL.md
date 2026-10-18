# CHANGES — Review-18 (VTL: virtual tape library + bug multi-drive reale)

## Nuovo tool: `tape/bin/bric-vtl` — device fittizi, zero cartucce consumate

Libreria a nastri virtuale su file normali: il backend REALE (`BRIC_TAPE_BACKEND=real` —
orchestrazione mtx/mt/dd, load/unload, posizionamento, numerazione file, preflight, quickcheck)
gira per intero contro device finti. Sono gli stessi mock fedeli già validati dalla suite,
estratti in tool standalone e potenziati: **multi-drive** (il tuo MSL ne ha 2), mock `sg_inq`/
`sg_turs`/`sg_requests` sani così anche `bric-library-preflight` passa sul VTL, comandi di
gestione con marker di sicurezza.

Uso tipico su brictape (l'hardware vero NON viene toccato):

    tape/bin/bric-vtl create /tmp/vtl --tapes 4 --drives 2
    eval "$(tape/bin/bric-vtl env /tmp/vtl)"
    tape/bin/bric-library-preflight          # verde sul VTL sano
    tape/bin/bric-tape-daemon --loop &       # daemon in backend REALE su device finti
    ... bric backup / bric restore / DR ...
    tape/bin/bric-vtl status  /tmp/vtl       # inventario + contenuto scritto
    tape/bin/bric-vtl reset   /tmp/vtl       # svuota i nastri, cartucce di nuovo negli slot
    tape/bin/bric-vtl destroy /tmp/vtl

Cosa NON emula: semantica SCSI reale, errori del nastro, tempi, inizializzazione LTO. Per uno
stack fedele a livello kernel (veri /dev/st*, veri mtx/mt, perfino L&TT) esiste mhvtl — modulo
kernel out-of-tree, più pesante; da valutare solo se servisse testare lo strato SCSI stesso.

## BUG DI PRODUZIONE trovato dal VTL: multi-drive rotto in `_load`

Il test e2e del VTL è il PRIMO in assoluto a esercitare il backend reale con DUE drive — e al
primo write: `ERROR: no usable drive among: 0 1`. Causa: i `for D in $BRIC_TAPE_DRIVES` di
`_load` girano sotto l'`IFS=$'\n\t'` del daemon, che non splitta "0 1" (stessa classe del bug
del quickcheck, Review-11 — corretto allora SOLO nel quickcheck). Sul tuo MSL3040 a 2 drive
sarebbe esploso al primo backup reale. Fix: `local IFS=$' \t\n'` in `_load`; verificato che gli
altri loop analoghi sono già coperti (quickcheck ha il suo IFS locale; il preflight standalone
gira con IFS di default).

## Nuovo test: `test/run_vtl.sh`

(A) create+env: inventario 4 barcode, 2 drive; (B) preflight verde sul VTL sano; (C) IO a
livello lib su ENTRAMBI i drive; (D) e2e completo: daemon real → backup CLOSED → restore →
DR bit-identici, 8 file su nastro PRIMARY (chunk + kit + TOC); (E) reset e riuso.
Nota di stile incorporata: `status | grep -q` sotto pipefail fallisce per SIGPIPE nonostante il
match — si cattura in variabile (commentato nel test).

## Validazione

run_vtl 15/15; regressione sui path tape (real_backend_mock, real_e2e, preflight, local_e2e,
restore_fallback, tape_rebuild, partial_pair, dr_e2e) + setup/security/notifications/faultinj/
lifecycle: tutti PASS. daemon_crash: flake ambientale del sandbox al primo giro, PASS isolato
(terza occorrenza identica, sempre sotto carico da batch).
