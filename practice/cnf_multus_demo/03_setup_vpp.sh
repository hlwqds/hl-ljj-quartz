#!/usr/bin/env bash
# Tier 1: Start VPP as CNF using podman container
# VPP uses AF_PACKET to read/write veth interfaces in userspace
# This replaces Linux kernel forwarding with VPP's node graph pipeline
set -euo pipefail

CNF_NS="${CNF_NS:-cnf}"
VPP_CONF="/tmp/cnf_vpp.conf"
VPP_SOCK="/tmp/cnf_vpp.sock"
VPP_CTR="cnf-vpp"

VPP_IMAGE="${VPP_IMAGE:-docker.io/calicovpp/vpp:latest}"

log() { printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }

[[ $EUID -ne 0 ]] && { echo "run as root: sudo $0" >&2; exit 1; }

if ! command -v podman &>/dev/null; then
    echo "ERROR: podman not found. Install: sudo dnf install -y podman" >&2
    exit 1
fi

# Pull image if not present
if ! podman image inspect "$VPP_IMAGE" &>/dev/null; then
    log "Pulling VPP container image: $VPP_IMAGE"
    podman pull "$VPP_IMAGE"
fi

# Verify Tier 0 topology exists
if ! ip netns list | awk '{print $1}' | grep -qx "$CNF_NS"; then
    echo "ERROR: namespace '$CNF_NS' not found. Run sudo ./01_setup_ns.sh first" >&2
    exit 1
fi

log "Disable Linux forwarding in CNF (VPP will handle it instead)"
ip netns exec "$CNF_NS" sysctl -w net.ipv4.ip_forward=0

# Remove Linux IP addresses from veth interfaces so VPP owns ARP/NDP
log "Flushing Linux IPs from CNF interfaces (VPP will own them)"
ip netns exec "$CNF_NS" ip addr flush dev cnf-in 2>/dev/null || true
ip netns exec "$CNF_NS" ip addr flush dev cnf-out 2>/dev/null || true

# Remove old container if exists
podman rm -f "$VPP_CTR" 2>/dev/null || true

CNF_IN_IF="cnf-in"
CNF_OUT_IF="cnf-out"

# Write VPP config BEFORE starting the container
log "Writing VPP startup config"
cat > "$VPP_CONF" <<EOF
unix {
  nodaemon
  cli-listen ${VPP_SOCK}
}

api-trace {
  on
}

plugins {
  plugin default { enable }
  plugin dpdk_plugin.so { disable }
}
EOF

# Ensure /var/run/netns symlink exists
mkdir -p /var/run/netns
CNF_NS_PATH="/var/run/netns/${CNF_NS}"
if [[ ! -e "$CNF_NS_PATH" ]]; then
    echo "ERROR: netns file $CNF_NS_PATH not found" >&2
    exit 1
fi

log "Starting VPP container in '$CNF_NS' namespace"
podman run -d \
    --name "$VPP_CTR" \
    --privileged \
    --entrypoint "" \
    --network "ns:${CNF_NS_PATH}" \
    -v /tmp:/tmp \
    "$VPP_IMAGE" \
    /usr/bin/vpp -c /tmp/cnf_vpp.conf

sleep 3

if ! podman ps --filter "name=$VPP_CTR" --format '{{.Names}}' | grep -q "$VPP_CTR"; then
    echo "ERROR: VPP container failed to start." >&2
    echo "Logs:" >&2
    podman logs "$VPP_CTR" 2>&1 | tail -20
    exit 1
fi

log "VPP started. Configuring AF_PACKET interfaces"

# Send commands one at a time via pipe
# Exit code 141 (SIGPIPE) is harmless: echo closes before vppctl reads all stdin
vpp_cmd() { echo "$1" | podman exec -i "$VPP_CTR" vppctl -s "${VPP_SOCK}" || true; }

vpp_cmd "create host-interface name ${CNF_IN_IF}"
vpp_cmd "create host-interface name ${CNF_OUT_IF}"
vpp_cmd "set interface state host-${CNF_IN_IF} up"
vpp_cmd "set interface state host-${CNF_OUT_IF} up"
vpp_cmd "set interface ip address host-${CNF_IN_IF} 10.10.1.1/24"
vpp_cmd "set interface ip address host-${CNF_OUT_IF} 10.10.2.1/24"

log "VPP interface status:"
vpp_cmd "show interface"

log "VPP FIB:"
vpp_cmd "show ip fib"

cat <<EOF

=====================================
  Tier 1 ready: VPP + AF_PACKET (container)
=====================================

  Container: $VPP_CTR
  Image:     $VPP_IMAGE
  Namespace: $CNF_NS

  Data path:
    app → app-net1 (veth)
        → cnf-in → AF_PACKET → VPP userspace forwarding
        → AF_PACKET → cnf-out (veth)
        → wan-net1

  VPP runs inside a privileged container — same as a real K8s CNF Pod.
  AF_PACKET reads from the veth without DPDK driver binding.

  Useful commands:
    sudo podman logs $VPP_CTR                        # VPP log output
    sudo podman exec -it $VPP_CTR vppctl -s $VPP_SOCK  # interactive VPP CLI

  Next:
    sudo ./04_test_vpp.sh
EOF
