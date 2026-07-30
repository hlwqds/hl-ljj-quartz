#!/usr/bin/env bash
# Tier 2: VPP + memif zero-copy data path (podman containers)
#
# Replaces veth with memif (shared memory ring buffer) for inter-process
# communication. This is the same mechanism used in production CNFs for
# container-to-container data paths on the same node.
#
# Topology:
#   VPP-app-agent ←memif→ VPP-cnf ←memif→ VPP-wan-agent
#   (shared memory, no syscall, no copy)
set -euo pipefail

APP_NS="${APP_NS:-app}"
CNF_NS="${CNF_NS:-cnf}"
WAN_NS="${WAN_NS:-wan}"

VPP_IMAGE="${VPP_IMAGE:-docker.io/calicovpp/vpp:latest}"

VPP_APP_CTR="vpp-app"
VPP_CNF_CTR="vpp-cnf"
VPP_WAN_CTR="vpp-wan"

MEMIF_DIR="/tmp/memif"

log() { printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }

[[ $EUID -ne 0 ]] && { echo "run as root: sudo $0" >&2; exit 1; }

if ! command -v podman &>/dev/null; then
    echo "ERROR: podman not found. Install: sudo dnf install -y podman" >&2
    exit 1
fi

# Verify Tier 0 topology exists
for ns in "$APP_NS" "$CNF_NS" "$WAN_NS"; do
    if ! ip netns list | awk '{print $1}' | grep -qx "$ns"; then
        echo "ERROR: namespace '$ns' not found. Run sudo ./01_setup_ns.sh first" >&2
        exit 1
    fi
done

# Stop Tier 1 VPP container if running
podman rm -f "cnf-vpp" 2>/dev/null || true

log "Disabling Linux forwarding in all namespaces"
for ns in "$APP_NS" "$CNF_NS" "$WAN_NS"; do
    ip netns exec "$ns" sysctl -w net.ipv4.ip_forward=0
done

log "Bringing down veth interfaces (memif replaces them)"
ip netns exec "$APP_NS"  ip link set app-net1 down 2>/dev/null || true
ip netns exec "$CNF_NS"  ip link set cnf-in down 2>/dev/null || true
ip netns exec "$CNF_NS"  ip link set cnf-out down 2>/dev/null || true
ip netns exec "$WAN_NS"  ip link set wan-net1 down 2>/dev/null || true

# Shared memif socket directory — all containers mount this
mkdir -p "$MEMIF_DIR"

# Remove old containers
for ctr in "$VPP_APP_CTR" "$VPP_CNF_CTR" "$VPP_WAN_CTR"; do
    podman rm -f "$ctr" 2>/dev/null || true
done

# Write VPP configs BEFORE starting containers
log "Writing VPP startup configs for 3 containers"

for name in app cnf wan; do
    cat > /tmp/vpp_${name}.conf <<EOF
unix {
  nodaemon
  cli-listen /tmp/vpp_${name}.sock
}
api-trace { on }
plugins {
  plugin default { enable }
  plugin dpdk_plugin.so { disable }
}
EOF
done

log "Starting 3 VPP containers (app-agent, cnf, wan-agent)"

for name in app cnf wan; do
    podman run -d \
        --name vpp-${name} \
        --privileged \
        --entrypoint "" \
        --network "ns:/var/run/netns/${name}" \
        -v /tmp:/tmp \
        "$VPP_IMAGE" \
        /usr/bin/vpp -c /tmp/vpp_${name}.conf
done

sleep 3

# Verify all containers running
for ctr in "$VPP_APP_CTR" "$VPP_CNF_CTR" "$VPP_WAN_CTR"; do
    if ! podman ps --filter "name=$ctr" --format '{{.Names}}' | grep -q "$ctr"; then
        echo "ERROR: container '$ctr' failed to start. Check: podman logs $ctr" >&2
        exit 1
    fi
done

log "Creating memif interfaces (shared memory rings)"

# Helper: send one command at a time via pipe
vpp_app() { echo "$1" | podman exec -i "$VPP_APP_CTR" vppctl -s /tmp/vpp_app.sock || true; }
vpp_cnf() { echo "$1" | podman exec -i "$VPP_CNF_CTR" vppctl -s /tmp/vpp_cnf.sock || true; }
vpp_wan() { echo "$1" | podman exec -i "$VPP_WAN_CTR" vppctl -s /tmp/vpp_wan.sock || true; }

# App ↔ CNF memif
# Step 1: Create memif sockets (master creates Unix socket, slave connects)
# Step 2: Create interfaces referencing the socket-id
vpp_app "create memif socket id 1 filename ${MEMIF_DIR}/app_cnf.sock"
vpp_app "create interface memif id 1 master socket-id 1"
vpp_cnf "create memif socket id 1 filename ${MEMIF_DIR}/app_cnf.sock"
vpp_cnf "create interface memif id 1 slave socket-id 1"

# CNF ↔ WAN memif
vpp_cnf "create memif socket id 2 filename ${MEMIF_DIR}/cnf_wan.sock"
vpp_cnf "create interface memif id 2 master socket-id 2"
vpp_wan "create memif socket id 2 filename ${MEMIF_DIR}/cnf_wan.sock"
vpp_wan "create interface memif id 2 slave socket-id 2"

sleep 1

log "Configuring IP addresses and routes"

# App VPP: memif1/1 ↔ CNF
vpp_app "set interface state memif1/1 up"
vpp_app "set interface ip address memif1/1 10.10.1.2/24"
vpp_app "ip route add 10.10.2.0/24 via 10.10.1.1"

# CNF VPP: memif1/1 ↔ App, memif2/2 ↔ WAN
vpp_cnf "set interface state memif1/1 up"
vpp_cnf "set interface ip address memif1/1 10.10.1.1/24"
vpp_cnf "set interface state memif2/2 up"
vpp_cnf "set interface ip address memif2/2 10.10.2.1/24"

# WAN VPP: memif2/2 ↔ CNF
vpp_wan "set interface state memif2/2 up"
vpp_wan "set interface ip address memif2/2 10.10.2.2/24"
vpp_wan "ip route add 10.10.1.0/24 via 10.10.2.1"

sleep 1

log "VPP CNF interface status:"
vpp_cnf "show interface"

log "VPP CNF FIB:"
vpp_cnf "show ip fib"

log "VPP CNF memif details:"
vpp_cnf "show memif"

cat <<EOF

=====================================
  Tier 2 ready: VPP + memif zero-copy (containers)
=====================================

  Containers:
    $VPP_APP_CTR  (namespace: $APP_NS) — app VPP agent
    $VPP_CNF_CTR  (namespace: $CNF_NS) — CNF forwarding engine
    $VPP_WAN_CTR  (namespace: $WAN_NS) — wan VPP agent

  Memif sockets:
    app ↔ cnf: ${MEMIF_DIR}/app_cnf.sock
    cnf ↔ wan: ${MEMIF_DIR}/cnf_wan.sock

  Data path (zero-copy shared memory):
    VPP-app → memif ring → VPP-CNF (node graph) → memif ring → VPP-wan

  memif uses shared memory ring buffers:
    - Producer writes to ring head (no copy)
    - Consumer reads from ring tail (no copy)
    - Same cache-line-isolated design as DPDK rte_ring

  Useful commands:
    podman exec $VPP_CNF_CTR vppctl -s /tmp/vpp_cnf.sock    # CNF VPP CLI
    podman logs $VPP_CNF_CTR                                  # CNF VPP logs

  Next:
    sudo ./06_test_memif.sh
EOF
