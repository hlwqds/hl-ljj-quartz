#!/usr/bin/env bash
# Tier 2 test: Verify traffic through VPP + memif zero-copy path (containers)
set -euo pipefail

VPP_APP_CTR="${VPP_APP_CTR:-vpp-app}"
VPP_CNF_CTR="${VPP_CNF_CTR:-vpp-cnf}"
VPP_WAN_CTR="${VPP_WAN_CTR:-vpp-wan}"

log() { printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }

[[ $EUID -ne 0 ]] && { echo "run as root: sudo $0" >&2; exit 1; }

for ctr in "$VPP_APP_CTR" "$VPP_CNF_CTR" "$VPP_WAN_CTR"; do
    if ! podman ps --filter "name=$ctr" --format '{{.Names}}' | grep -q "$ctr"; then
        echo "ERROR: container '$ctr' not running. Run sudo ./05_setup_memif.sh first" >&2
        exit 1
    fi
done

vpp_app() { echo "$1" | podman exec -i "$VPP_APP_CTR" vppctl -s /tmp/vpp_app.sock || true; }
vpp_cnf() { echo "$1" | podman exec -i "$VPP_CNF_CTR" vppctl -s /tmp/vpp_cnf.sock || true; }
vpp_wan() { echo "$1" | podman exec -i "$VPP_WAN_CTR" vppctl -s /tmp/vpp_wan.sock || true; }

log "VPP app-agent interfaces:"
vpp_app "show interface"

log "VPP CNF interfaces:"
vpp_cnf "show interface"

log "VPP wan-agent interfaces:"
vpp_wan "show interface"

log "Ping from app-agent to CNF (memif hop 1):"
vpp_app "ping 10.10.1.1 repeat 3"

log "Ping from app-agent to wan-agent (through CNF via memif):"
vpp_app "ping 10.10.2.2 repeat 5"

log "VPP CNF node graph runtime (packet processing stats):"
vpp_cnf "show runtime"

log "VPP CNF memif details (verify shared memory ring):"
vpp_cnf "show memif"

cat <<EOF

=====================================
  Tier 2 result: memif zero-copy data path (containers)
=====================================

  Performance comparison:

  Tier 0 (Linux kernel):
    - 3 context switches per packet
    - kernel copy on each hop
    - ~1-5 μs latency
    - ~1-2 Mpps on a modern core

  Tier 1 (VPP + AF_PACKET):
    - 1 userspace forwarding hop
    - AF_PACKET still copies from kernel
    - ~500 ns - 1 μs latency
    - ~2-5 Mpps on a modern core

  Tier 2 (VPP + memif):
    - 0 context switches
    - 0 copies (shared memory ring)
    - ~100-300 ns latency
    - ~10-40 Mpps on a modern core

  Why memif is so fast:
    - Producer/consumer ring in shared memory (like DPDK rte_ring)
    - Cache line isolated: producer writes head, consumer writes tail
    - No syscall, no kernel involvement
    - No copy: VPP processes packets in-place

  In production K8s, this becomes:
    - memif between containers on same node (sidecar pattern)
    - vhost-user between VM and OVS-DPDK/VPP
    - SR-IOV VF with DPDK PMD for physical NIC access
EOF
