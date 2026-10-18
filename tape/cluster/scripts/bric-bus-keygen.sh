#!/bin/bash
# bric-bus-keygen: generate the TWO ECDSA P-256 key pairs that authenticate the QNAP marker bus
# (symmetric signing). Each side signs the markers it publishes and verifies the peer's markers.
#
#   cluster_bus_ecdsa_p256.pem / .pub   -> cluster's own key pair
#   tape_bus_ecdsa_p256.pem    / .pub   -> tape server's own key pair
#
# Distribute so that each host holds its own PRIVATE key and the peer's PUBLIC key only:
#   CLUSTER     : BRIC_BUS_SIGN_KEY=cluster_bus_ecdsa_p256.pem   BRIC_BUS_VERIFY_KEY=tape_bus_ecdsa_p256.pub
#   TAPE SERVER : BRIC_BUS_SIGN_KEY=tape_bus_ecdsa_p256.pem      BRIC_BUS_VERIFY_KEY=cluster_bus_ecdsa_p256.pub
#
# A signing key is NOT a data-decryption secret, so the tape server can authenticate its receipts
# (RESERVED/DONE/CLOSED/...) and still never hold a key that decrypts archived data.
set -euo pipefail
IFS=$'\n\t'
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
. "$HERE/lib_common.sh"
bric_log_process_start "bric-bus-keygen" "$@"
require_cmds openssl
DIR="${1:-$BRIC_KEYS}"; mkdir -p "$DIR"

gen() {  # basename
    local priv="$DIR/$1.pem" pub="$DIR/$1.pub"
    if [ -f "$priv" ]; then
        log "private key already exists: $priv (refusing to overwrite)"
    else
        # ECDSA P-256, NOT ECDSA P-256: ECDSA P-256 has no working command-line signing path on
        # OpenSSL 1.1.1 (RHEL 8, supekgate) — `pkeyutl -rawin` only exists from OpenSSL 3.0 and
        # `dgst -sign` rejects the key type on every version. P-256 via `dgst -sha256` behaves
        # identically on 1.1.1 and 3.x, so both sides of the bus speak the same primitive.
        # Bus signatures are transient (they never reach tape), so this choice does not touch
        # long-term recoverability, which stays AES-256-CBC + HMAC-SHA256.
        ( umask 077; openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 \
              -out "$priv.tmp.$$" 2>/dev/null ) && mv -f "$priv.tmp.$$" "$priv"
        [ -s "$priv" ] || die "key generation failed for $priv ($(openssl version 2>/dev/null))"
        chmod 600 "$priv"; log "generated $priv"
    fi
    openssl pkey -in "$priv" -pubout -out "$pub" 2>/dev/null; chmod 644 "$pub"; log "wrote $pub"
    # Self-test: a key that exists but cannot be USED here is the failure mode that cost a whole
    # debugging round (existence was asserted, usability was not). Prove sign+verify now, loudly.
    local probe="$DIR/.probe.$$" sig="$DIR/.probe.sig.$$" err="$DIR/.probe.err.$$"
    printf 'BRIC-BUS-KEY-SELFTEST' > "$probe"
    if openssl dgst -sha256 -sign "$priv" -out "$sig" "$probe" 2>"$err" \
       && openssl dgst -sha256 -verify "$pub" -signature "$sig" "$probe" >/dev/null 2>&1; then
        rm -f "$probe" "$sig" "$err"; log "self-test OK: $1 can sign and verify on this host"
    else
        local why; why="$(tr '\n' ' ' < "$err" 2>/dev/null)"; rm -f "$probe" "$sig" "$err"
        die "key $priv exists but CANNOT be used on this host ($(openssl version 2>/dev/null)): ${why:-no error text}"
    fi
}
gen cluster_bus_ecdsa_p256
gen tape_bus_ecdsa_p256

cat >&2 <<EOF

Bus authentication key pairs ready in: $DIR
  CLUSTER:     export BRIC_BUS_SIGN_KEY="$DIR/cluster_bus_ecdsa_p256.pem"
               export BRIC_BUS_VERIFY_KEY="$DIR/tape_bus_ecdsa_p256.pub"
  TAPE SERVER: export BRIC_BUS_SIGN_KEY="<copy of tape_bus_ecdsa_p256.pem>"
               export BRIC_BUS_VERIFY_KEY="<copy of cluster_bus_ecdsa_p256.pub>"

Copy each host ONLY its own .pem (private) and the peer's .pub (public). With both sides configured,
every bus marker is signed by its producer and verified by its consumer in both directions.
EOF
