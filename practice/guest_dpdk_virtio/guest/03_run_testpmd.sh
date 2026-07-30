#!/usr/bin/env bash
set -euo pipefail

TESTPMD="${TESTPMD:-dpdk-testpmd}"
LCORES="${LCORES:-0-3}"
MEM_CHANNELS="${MEM_CHANNELS:-4}"
RXQ="${RXQ:-1}"
TXQ="${TXQ:-1}"
NBCORES="${NBCORES:-2}"
FWD_MODE="${FWD_MODE:-io}"

if [[ $EUID -ne 0 ]]; then
  echo "run as root" >&2
  exit 1
fi

exec "$TESTPMD" \
  -l "$LCORES" \
  -n "$MEM_CHANNELS" \
  -- \
  -i \
  --rxq="$RXQ" \
  --txq="$TXQ" \
  --nb-cores="$NBCORES" \
  --forward-mode="$FWD_MODE"
