#!/usr/bin/env bash
# Clean up all demo resources: VPP containers, namespaces, temp files
set -euo pipefail

APP_NS="${APP_NS:-app}"
CNF_NS="${CNF_NS:-cnf}"
WAN_NS="${WAN_NS:-wan}"

log() { printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"; }

[[ $EUID -ne 0 ]] && { echo "run as root: sudo $0" >&2; exit 1; }

log "Stopping VPP containers..."
for ctr in cnf-vpp vpp-app vpp-cnf vpp-wan; do
    podman rm -f "$ctr" 2>/dev/null || true
done

log "Removing network namespaces..."
for ns in "$APP_NS" "$CNF_NS" "$WAN_NS"; do
    if ip netns list | awk '{print $1}' | grep -qx "$ns"; then
        ip netns delete "$ns"
    fi
done

log "Removing temp files..."
rm -f /tmp/cnf_vpp.* /tmp/vpp_app.* /tmp/vpp_cnf.* /tmp/vpp_wan.*
rm -f /tmp/cnf_vpp.conf /tmp/vpp_app.conf /tmp/vpp_cnf.conf /tmp/vpp_wan.conf
rm -rf /tmp/memif /tmp/memif_sockets

log "Cleanup complete"
