# CHANGES — Review-26 (il lock: l'orfano era un command-subst ANNIDATO, non tape_append_file)

Ancora daemon_crash a 300s su supekgate dopo review24/25. Il fix precedente era a un livello di
annidamento troppo profondo.

## La catena reale, finalmente mappata

Il daemon, tenendo il flock del singleton su fd 9, esegue per ogni copia:

    handle_chunk (nel processo daemon)
      └─ pfn="$(write_copy ...)"          ← SUBSHELL esterno, eredita fd 9
           ├─ tsql "INSERT ..."           ← sqlite WAL, può BLOCCARSI sul lock DB
           └─ fn="$(tape_append_file ...)" ← subshell interno

Il fix di review22-24 chiudeva fd 9 dentro `tape_append_file` (il subshell INTERNO). Ma sotto un
kill -9 l'orfano che sopravvive tenendo fd 9 è il subshell di **write_copy** (quello ESTERNO):
resta vivo finché il suo contenuto — incluso un tsql che può attendere il lock del DB — non
termina. Un livello sopra quello che avevo corretto.

## Fix

`write_copy` chiude fd 9 come primo atto ( `{ exec 9>&-; } 2>/dev/null || true` ). È il subshell
IO più esterno del percorso di scrittura chunk, ed è SEMPRE invocato in command-substitution
(verificato) → la chiusura tocca la copia del subshell, mai l'fd 9 del daemon. Copre in un colpo
il tsql e il tape_append_file annidati.

Le chiusure precedenti nella lib IO restano: coprono `append_artifact` (TOC/catalogo alla
chiusura), che chiama `tape_append_file` in command-subst ma è essa stessa chiamata DIRETTAMENTE
dal daemon (riga 432) — quindi lì la chiusura va nel subshell di tape_append_file, non
all'ingresso di append_artifact (che chiuderebbe l'fd del daemon). Copertura completa e ogni
chiusura in un contesto verificato-sicuro.

## Prova del meccanismo (bric_verify_lock_fix.sh)

Diagnostico che riproduce l'annidamento reale ( `x=$( y=$( sleep ) )` ) e mostra:
- PRIMA del fix: lock TENUTO da orfano dopo il kill (il bug dei 300s);
- DOPO ( `x=$( exec 9>&-; y=$( sleep ) )` ): lock LIBERO.
Eseguito su bash 5.2/kernel 6.x; da eseguire su supekgate (bash 4.4/el8) per conferma prima di
fidarsi.

## Validazione

Suite 31/31 sotto OpenSSL 3.x. daemon_crash: PASS isolato (160s) sia sotto 3.x sia sotto 1.1.1
SIMULATO, con "recovery daemon acquired the lock (no orphan held fd 9)" e "nessuna contesa".
IO/scrittura (real_e2e, vtl, local_e2e, close_faultinj, partial_pair, restore_fallback,
tape_rebuild, resilience): 8/8 — write_copy è il cuore della scrittura, il fix non lo altera.

## Onestà sul sandbox

I fallimenti intermittenti che vedevo nei miei batch erano troncamenti del timeout del TOOL
(90-100s) mentre daemonB stava ancora drenando i 16 chunk — non il bug del lock (in quei casi
daemonB drenava fino a DONE 16, nessuna "another daemon holds"). Con timeout ampio (160s) e
quiescenza, PASS pulito e ripetibile. Il diagnostico separa i due casi in modo netto: prova il
MECCANISMO del lock, non dipende dal timing della suite completa.
