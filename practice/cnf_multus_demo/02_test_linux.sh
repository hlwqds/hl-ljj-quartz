#!/usr/bin/env bash
# Tier 0 test: Verify Linux kernel forwarding through CNF namespace
set -euo pipefail

APP_NS="${APP_NS:-app}"
CNF_NS="${CNF_NS:-cnf}"
WAN_NS="${WAN_NS:-wan}"

log() { printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }

[[ $EUID -ne 0 ]] && { echo "run as root: sudo $0" >&2; exit 1; }

log "App namespace:"
ip netns exec "$APP_NS" ip -br addr
ip netns exec "$APP_NS" ip route

log "CNF namespace (kernel forwarding):"
ip netns exec "$CNF_NS" ip -br addr
ip netns exec "$CNF_NS" sysctl net.ipv4.ip_forward

log "WAN namespace:"
ip netns exec "$WAN_NS" ip -br addr
ip netns exec "$WAN_NS" ip route

log "Traceroute from app → wan (should show CNF hop):"
ip netns exec "$APP_NS" ip route get 10.10.2.2

log "Ping app → wan through CNF:"
ip netns exec "$APP_NS" ping -c 3 -W 1 10.10.2.2

cat <<EOF

=====================================
  Tier 0 result: Linux kernel forwarding
=====================================

  Packet path:
    app → app-net1 (veth, syscall, copy)
        → cnf-in  (kernel ip_forward, copy)
        → cnf-out (veth, syscall, copy)
        → wan-net1

  Each packet crosses the kernel/userspace boundary ~3 times.
  This is why CNFs use VPP/DPDK: move forwarding to userspace.

  Next (requires vpp package):
    sudo ./03_setup_vpp.sh
EOF
