#!/usr/bin/env bash
set -euo pipefail

LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PCI_ADDR="${1:-${PCI_ADDR:-}}"
DRIVER="${DRIVER:-uio_pci_generic}"
TESTPMD="${TESTPMD:-dpdk-testpmd}"
LCORES="${LCORES:-0-1}"
MEM_CHANNELS="${MEM_CHANNELS:-2}"
RXQ="${RXQ:-1}"
TXQ="${TXQ:-1}"
NBCORES="${NBCORES:-1}"
FWD_MODE="${FWD_MODE:-io}"
AUTO_TESTPMD="${AUTO_TESTPMD:-0}"
TESTPMD_TIMEOUT="${TESTPMD_TIMEOUT:-20}"
TRAFFIC_WAIT="${TRAFFIC_WAIT:-8}"

log_step() {
  printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"
}

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "run as root: sudo $0 <virtio-net-pci-address>" >&2
    exit 1
  fi
}

detect_virtio_net() {
  if ! command -v dpdk-devbind.py >/dev/null; then
    return 1
  fi

  dpdk-devbind.py -s |
    awk 'tolower($0) ~ /virtio/ && tolower($0) ~ /network|ethernet/ {print $1}'
}

require_root

log_step "Guest lab configuration"
cat <<EOF
  lab dir:       $LAB_DIR
  pci address:   ${PCI_ADDR:-auto-detect}
  bind driver:   $DRIVER
  testpmd:       $TESTPMD
  lcores:        $LCORES
  mem channels:  $MEM_CHANNELS
  rxq/txq:       $RXQ/$TXQ
  nb cores:      $NBCORES
  forward mode:  $FWD_MODE
  auto testpmd:   $AUTO_TESTPMD
EOF

log_step "Step 1/4: prepare guest hugepages"
"$LAB_DIR/guest/01_setup_hugepages.sh"

if [[ -z "$PCI_ADDR" ]]; then
  log_step "Step 2/4: auto-detect virtio-net PCI device"
  mapfile -t candidates < <(detect_virtio_net || true)

  if [[ ${#candidates[@]} -eq 1 ]]; then
    PCI_ADDR="${candidates[0]}"
    echo "detected virtio-net PCI device: $PCI_ADDR"
  else
    echo "could not auto-detect exactly one virtio-net PCI device" >&2
    echo "current DPDK device list:" >&2
    dpdk-devbind.py -s >&2 || true
    echo "run again with: sudo $0 <virtio-net-pci-address>" >&2
    exit 1
  fi
else
  log_step "Step 2/4: use virtio-net PCI device from argument"
  echo "using PCI device: $PCI_ADDR"
fi

log_step "Step 3/4: bind virtio-net device to DPDK driver"
DRIVER="$DRIVER" "$LAB_DIR/guest/02_bind_virtio_to_vfio.sh" "$PCI_ADDR"

log_step "Step 4/4: start dpdk-testpmd"
if [[ "$AUTO_TESTPMD" == "1" ]]; then
  cat <<EOF
testpmd will run a short non-interactive smoke test:
  show port info all
  set fwd $FWD_MODE
  start
  show port stats all
  stop
  quit
EOF

  TESTPMD="$TESTPMD" \
  LCORES="$LCORES" \
  MEM_CHANNELS="$MEM_CHANNELS" \
  RXQ="$RXQ" \
  TXQ="$TXQ" \
  NBCORES="$NBCORES" \
  FWD_MODE="$FWD_MODE" \
  TESTPMD_TIMEOUT="$TESTPMD_TIMEOUT" \
  TRAFFIC_WAIT="$TRAFFIC_WAIT" \
  PCI_ADDR="$PCI_ADDR" \
    "$LAB_DIR/guest/04_testpmd_smoke.sh"
  exit 0
fi

cat <<EOF
testpmd will start in interactive mode.
Useful commands:
  show port info all
  set fwd io
  start
  show port stats all
EOF

TESTPMD="$TESTPMD" \
LCORES="$LCORES" \
MEM_CHANNELS="$MEM_CHANNELS" \
RXQ="$RXQ" \
TXQ="$TXQ" \
NBCORES="$NBCORES" \
FWD_MODE="$FWD_MODE" \
  "$LAB_DIR/guest/03_run_testpmd.sh"
