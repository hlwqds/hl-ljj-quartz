#!/usr/bin/env bash
# Tier 1 test: Verify traffic through VPP userspace forwarding (container)
set -euo pipefail

APP_NS="${APP_NS:-app}"
VPP_CTR="${VPP_CTR:-cnf-vpp}"
VPP_SOCK="${VPP_SOCK:-/tmp/cnf_vpp.sock}"

log() { printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }

[[ $EUID -ne 0 ]] && { echo "run as root: sudo $0" >&2; exit 1; }

if ! podman ps --filter "name=$VPP_CTR" --format '{{.Names}}' | grep -q "$VPP_CTR"; then
    echo "ERROR: VPP container '$VPP_CTR' not running. Run sudo ./03_setup_vpp.sh first" >&2
    exit 1
fi

log "VPP container status:"
podman ps --filter "name=$VPP_CTR"

vpp_cmd() { echo "$1" | podman exec -i "$VPP_CTR" vppctl -s "$VPP_SOCK" || true; }

log "VPP interface status:"
vpp_cmd "show interface"

log "VPP FIB (forwarding table):"
vpp_cmd "show ip fib"

log "VPP ARP table:"
vpp_cmd "show ip neighbor"

log "Ping app → VPP (verify VPP receives and responds):"
ip netns exec "$APP_NS" ping -c 1 -W 1 10.10.1.1

log "Ping app → wan (through VPP forwarding):"
ip netns exec "$APP_NS" ping -c 5 -W 1 10.10.2.2

log "VPP interface counters (verify packets went through):"
vpp_cmd "show interface"

log "VPP node graph stats (see which nodes processed packets):"
vpp_cmd "show runtime"

cat <<EOF

=====================================
  Tier 1 result: VPP userspace forwarding (container)
=====================================

  VPP processed packets through its node graph:
    ethernet-input → ip4-input → ip4-lookup → ip4-rewrite →
    adjacency-midchain → interface-output

  Compare with Tier 0:
    Linux: kernel receives → ip_forward → kernel sends (syscall per hop)
    VPP:   AF_PACKET recv → node graph → AF_PACKET send (userspace only)

  In production, AF_PACKET is replaced by:
    - DPDK PMD (vfio-pci) for direct NIC access
    - AF_XDP for zero-copy from kernel XDP
    - vhost-user for VM/container data path

  Next (memif zero-copy):
    sudo ./05_setup_memif.sh
EOF
