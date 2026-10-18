#!/bin/bash
# Enable direct supekgate execution in the installed role config.
set -euo pipefail
CFG="${BRIC_CONFIG:-/etc/bric/bric.conf}"
[ "$(id -u)" -eq 0 ] || { echo "ERROR: run as root" >&2; exit 1; }
[ -f "$CFG" ] || { echo "ERROR: config not found: $CFG" >&2; exit 1; }
cp -a "$CFG" "$CFG.before-local-mode-$(date +%Y%m%d-%H%M%S)"
sed -i '/^BRIC_RUN_MODE=/d' "$CFG"
printf '\n# Direct execution on supekgate; temporary until archive compute nodes have required NFS mounts.\nBRIC_RUN_MODE=local\n' >> "$CFG"
printf 'BRIC local execution enabled in %s\n' "$CFG"
printf 'Users can run: bric backup PROJECT SOURCE\n'
