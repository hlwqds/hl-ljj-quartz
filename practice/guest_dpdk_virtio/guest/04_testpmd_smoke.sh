#!/usr/bin/env bash
set -euo pipefail

TESTPMD="${TESTPMD:-dpdk-testpmd}"
LCORES="${LCORES:-0-1}"
MEM_CHANNELS="${MEM_CHANNELS:-2}"
RXQ="${RXQ:-1}"
TXQ="${TXQ:-1}"
NBCORES="${NBCORES:-1}"
FWD_MODE="${FWD_MODE:-io}"
TESTPMD_TIMEOUT="${TESTPMD_TIMEOUT:-20}"
TRAFFIC_WAIT="${TRAFFIC_WAIT:-8}"
PCI_ADDR="${PCI_ADDR:-}"

if [[ $EUID -ne 0 ]]; then
  echo "run as root" >&2
  exit 1
fi

eal_args=(-l "$LCORES" -n "$MEM_CHANNELS")
if [[ -n "$PCI_ADDR" ]]; then
  eal_args+=(-a "$PCI_ADDR")
fi

{
  echo "show port info all"
  echo "set fwd $FWD_MODE"
  echo "start"
  sleep "$TRAFFIC_WAIT"
  echo "show port stats all"
  echo "stop"
  echo "quit"
} | timeout "$TESTPMD_TIMEOUT" "$TESTPMD" \
  "${eal_args[@]}" \
  -- \
  -i \
  --rxq="$RXQ" \
  --txq="$TXQ" \
  --nb-cores="$NBCORES" \
  --forward-mode="$FWD_MODE"
