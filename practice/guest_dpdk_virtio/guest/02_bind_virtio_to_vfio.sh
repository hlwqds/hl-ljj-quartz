#!/usr/bin/env bash
set -euo pipefail

PCI_ADDR="${1:-}"
DRIVER="${DRIVER:-uio_pci_generic}"

if [[ -z "$PCI_ADDR" ]]; then
  echo "usage: $0 <virtio-net-pci-address>" >&2
  echo "example: $0 0000:00:03.0" >&2
  exit 1
fi

if [[ $EUID -ne 0 ]]; then
  echo "run as root" >&2
  exit 1
fi

install_linux_modules_extra() {
  if ! command -v apt-get >/dev/null; then
    return 1
  fi

  echo "Try to install linux-modules-extra-$(uname -r) for $DRIVER..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y "linux-modules-extra-$(uname -r)"
}

load_driver() {
  if [[ "$DRIVER" == "uio_pci_generic" ]]; then
    modprobe uio
  fi

  if modprobe "$DRIVER"; then
    return 0
  fi

  if [[ "$DRIVER" == "uio_pci_generic" ]]; then
    install_linux_modules_extra || true
    modprobe uio
    modprobe "$DRIVER"
    return
  fi

  return 1
}

load_driver

if ! command -v dpdk-devbind.py >/dev/null; then
  echo "dpdk-devbind.py not found in PATH" >&2
  exit 1
fi

dpdk-devbind.py -s
if ! dpdk-devbind.py -b "$DRIVER" "$PCI_ADDR"; then
  cat >&2 <<EOF
Failed to bind $PCI_ADDR to $DRIVER.

Diagnostics:
EOF
  lsmod | grep -E 'uio|vfio' >&2 || true
  echo >&2
  find "/sys/bus/pci/devices/$PCI_ADDR" -maxdepth 2 -type l -name driver -print -exec readlink -f {} \; >&2 || true
  echo >&2
  dmesg | tail -n 50 >&2 || true
  exit 1
fi
dpdk-devbind.py -s
