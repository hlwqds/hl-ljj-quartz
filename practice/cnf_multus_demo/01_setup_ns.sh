#!/usr/bin/env bash
# Tier 0: Create namespace topology for CNF demo
# Baseline: Linux kernel forwarding (no VPP/DPDK)
set -euo pipefail

APP_NS="${APP_NS:-app}"
CNF_NS="${CNF_NS:-cnf}"
WAN_NS="${WAN_NS:-wan}"

log() { printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }

[[ $EUID -ne 0 ]] && { echo "run as root: sudo $0" >&2; exit 1; }

del_ns() {
    if ip netns list | awk '{print $1}' | grep -qx "$1"; then
        ip netns delete "$1"
    fi
}

log "Clean up any previous run"
del_ns "$APP_NS"
del_ns "$CNF_NS"
del_ns "$WAN_NS"

log "Step 1/6: Create namespaces (model 3 Pods)"
ip netns add "$APP_NS"
ip netns add "$CNF_NS"
ip netns add "$WAN_NS"

log "Step 2/6: Create inside veth pair: app <-> cnf"
ip link add app-net1 type veth peer name cnf-in
ip link set app-net1 netns "$APP_NS"
ip link set cnf-in netns "$CNF_NS"

log "Step 3/6: Create outside veth pair: cnf <-> wan"
ip link add cnf-out type veth peer name wan-net1
ip link set cnf-out netns "$CNF_NS"
ip link set wan-net1 netns "$WAN_NS"

log "Step 4/6: Assign IP addresses"
ip netns exec "$APP_NS"  ip addr add 10.10.1.2/24 dev app-net1
ip netns exec "$CNF_NS"  ip addr add 10.10.1.1/24 dev cnf-in
ip netns exec "$CNF_NS"  ip addr add 10.10.2.1/24 dev cnf-out
ip netns exec "$WAN_NS"  ip addr add 10.10.2.2/24 dev wan-net1

log "Step 5/6: Bring interfaces up + add routes"
for ns in "$APP_NS" "$CNF_NS" "$WAN_NS"; do
    ip netns exec "$ns" ip link set lo up
done
ip netns exec "$APP_NS" ip link set app-net1 up
ip netns exec "$CNF_NS" ip link set cnf-in up
ip netns exec "$CNF_NS" ip link set cnf-out up
ip netns exec "$WAN_NS" ip link set wan-net1 up

ip netns exec "$APP_NS" ip route add default via 10.10.1.1
ip netns exec "$WAN_NS" ip route add 10.10.1.0/24 via 10.10.2.1

log "Step 6/6: Enable forwarding in CNF namespace (Linux kernel baseline)"
ip netns exec "$CNF_NS" sysctl -w net.ipv4.ip_forward=1

cat <<EOF

=====================================
  Tier 0 topology ready (Linux baseline)
=====================================

  $APP_NS: app-net1  10.10.1.2/24 → default via 10.10.1.1
  $CNF_NS: cnf-in    10.10.1.1/24
           cnf-out   10.10.2.1/24
           ip_forward=1
  $WAN_NS: wan-net1  10.10.2.2/24 → 10.10.1.0/24 via 10.10.2.1

  Data path: app → veth → kernel forward → veth → wan
  (3 context switches, kernel copy per hop)

  Next:
    sudo ./02_test_linux.sh
EOF
