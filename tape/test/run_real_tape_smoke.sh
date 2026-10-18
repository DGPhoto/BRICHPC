#!/bin/bash
# Smoke-test del backend a nastro usando le STESSE funzioni del daemon (tape_append_file/tape_read_file/
# tape_last_file_number). Appende 3 payload (uno di lunghezza dispari) su una cartuccia, li rilegge col
# posizionamento di produzione e confronta gli SHA. Complementare al runbook manuale docs/RUNBOOK_scratch_tape.md.
#
#   # in SIM (auto-test, nessun hardware):
#   BRIC_TAPE_BACKEND=sim BRIC_TAPELIB=/tmp/lib ./test/run_real_tape_smoke.sh --vt TEST000001
#   # su HARDWARE reale (SCRIVE sulla cartuccia indicata: richiede conferma esplicita):
#   BRIC_TAPE_BACKEND=real BRIC_CHANGER=/dev/sch0 BRIC_DRIVE0=/dev/nst0 BRIC_TAPE_DRIVES=0 \
#       ./test/run_real_tape_smoke.sh --vt 000099L9 --yes-write 000099L9
set -euo pipefail
export BRIC_CONFIG=none   # hermetic: never read /etc/bric/bric.conf inside tests
REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
. "$REPO/tape/scripts/lib_common.sh"
. "$REPO/tape/scripts/lib_tape_io.sh"

VT=""; CONFIRM=""
while [ "$#" -gt 0 ]; do case "$1" in
    --vt) VT="${2:-}"; shift 2;;
    --yes-write) CONFIRM="${2:-}"; shift 2;;
    --yes-overwrite) CONFIRM="${2:-}"; echo "WARN: --yes-overwrite is deprecated; the test appends and does not erase. Use --yes-write." >&2; shift 2;;
    -h|--help) sed -n '2,12p' "$0"; exit 0;;
    *) echo "opzione sconosciuta: $1" >&2; exit 2;; esac; done
[ -n "$VT" ] || { echo "ERRORE: --vt VOLUMETAG obbligatorio" >&2; exit 2; }

# Guard-rail anti-incidente: su hardware reale serve la conferma esplicita del VolumeTag su cui appendere.
if [ "${BRIC_TAPE_BACKEND:-sim}" = real ]; then
    [ "$CONFIRM" = "$VT" ] || { echo "RIFIUTO: su backend reale serve  --yes-write $VT  (la prova APPENDE dati alla cartuccia)"; exit 3; }
    echo "ATTENZIONE: appendo dati di prova sulla cartuccia reale $VT (changer=$BRIC_CHANGER drive=$BRIC_DRIVE0 blk=$BRIC_TAPE_BLOCK)"
fi
T="$(mktemp -d)"; trap '[ -n "${KEEP:-}" ]||rm -rf "$T"' EXIT
fail=0; ok(){ echo "  ok: $1"; }; bad(){ echo "  FAIL: $1"; fail=1; }
echo "backend=${BRIC_TAPE_BACKEND:-sim} vt=$VT"

# baseline: quanti file ci sono già (una scratch vera è 0; non assumiamo nulla)
BASE="$(tape_last_file_number "$VT")"; BASE="${BASE:-0}"
echo "file già presenti sul nastro (baseline): $BASE"

# 3 payload con SHA noto: f1 multiplo del block, f2 DISPARI (fedeltà lunghezza), f3 piccolo
dd if=/dev/urandom of="$T/f1" bs=1M count=8 status=none
dd if=/dev/urandom of="$T/f2" bs=1 count=$((3*1024*1024 + 4097)) status=none
head -c 1000 /dev/urandom > "$T/f3"
declare -A FN
for f in f1 f2 f3; do
    n="$(tape_append_file "$VT" "$T/$f")" || { bad "scrittura $f fallita"; break; }
    FN[$f]="$n"; echo "  scritto $f -> file #$n"
done
for spec in "f1:$((BASE+1))" "f2:$((BASE+2))" "f3:$((BASE+3))"; do
    f="${spec%%:*}"; exp="${spec#*:}"
    [ "${FN[$f]:-}" = "$exp" ] && ok "$f numerato progressivamente come file #$exp" || bad "$f numerazione inattesa: ${FN[$f]:-?} (atteso $exp)"
done

# rilettura col percorso di produzione + confronto SHA
for f in f1 f2 f3; do
    [ -n "${FN[$f]:-}" ] || continue
    tape_read_file "$VT" "${FN[$f]}" "$T/r_$f" || { bad "lettura $f (#${FN[$f]}) fallita"; continue; }
    a="$(sha256sum "$T/$f"   | awk '{print $1}')"
    b="$(sha256sum "$T/r_$f" | awk '{print $1}')"
    if [ "$a" = "$b" ]; then ok "$f riletto identico (#${FN[$f]}, $(stat -c%s "$T/$f") byte)"; else bad "$f DIFFERISCE (write=$a read=$b)"; fi
done
# il payload dispari prova la fedeltà della lunghezza esatta
[ "$(stat -c%s "$T/f2")" = "$(stat -c%s "$T/r_f2" 2>/dev/null || echo -1)" ] && ok "lunghezza esatta preservata sul payload dispari (block variabile OK)" || bad "lunghezza non preservata"

# il contatore EOD deve riflettere i 3 append
LAST="$(tape_last_file_number "$VT")"
[ "$LAST" = "$((BASE+3))" ] && ok "tape_last_file_number = $LAST (baseline+3): EOD e contatore coerenti" || bad "contatore EOD inatteso: $LAST (atteso $((BASE+3)))"

echo
if [ "$fail" -eq 0 ]; then
    echo "✓ SMOKE NASTRO OK — le funzioni di I/O del daemon scrivono e rileggono fedelmente su '$VT'"
    if [ "${BRIC_TAPE_BACKEND:-sim}" = real ]; then
        echo "  (ricorda di scaricare la cartuccia: mtx -f \$BRIC_CHANGER unload <slot> 0)"
    fi
    exit 0
else echo "✗ SMOKE NASTRO FALLITO — NON usare questo backend per dati veri finché non è verde"; exit 1; fi
