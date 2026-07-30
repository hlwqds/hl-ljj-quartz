#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "run as root" >&2
  exit 1
fi

if [[ ! -r /etc/os-release ]]; then
  echo "cannot detect OS: /etc/os-release not found" >&2
  exit 1
fi

# shellcheck disable=SC1091
. /etc/os-release

if [[ "${ID:-}" != "fedora" ]]; then
  echo "skip Fedora dependency install: detected ID=${ID:-unknown}" >&2
  exit 0
fi

echo "Install Fedora packages for Guest DPDK virtio/vhost-user lab"
dnf --setopt=install_weak_deps=False install -y \
  openvswitch-dpdk \
  dpdk \
  dpdk-tools \
  qemu-kvm \
  qemu-img \
  genisoimage \
  cloud-utils-cloud-localds \
  pciutils

systemctl enable --now openvswitch || true

echo "Fedora dependencies installed"
