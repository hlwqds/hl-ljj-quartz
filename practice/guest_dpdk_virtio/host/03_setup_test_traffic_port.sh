#!/usr/bin/env bash
set -euo pipefail

BRIDGE="${BRIDGE:-br-dpdk}"
TRAFFIC_PORT="${TRAFFIC_PORT:-host-traffic0}"
TRAFFIC_IP="${TRAFFIC_IP:-198.18.0.1/24}"
OVS_TIMEOUT="${OVS_TIMEOUT:-15}"

if [[ $EUID -ne 0 ]]; then
  echo "run as root" >&2
  exit 1
fi

echo "+ ovs-vsctl --may-exist add-port $BRIDGE $TRAFFIC_PORT -- set Interface $TRAFFIC_PORT type=internal"
ovs-vsctl --timeout="$OVS_TIMEOUT" --may-exist add-port "$BRIDGE" "$TRAFFIC_PORT" \
  -- set Interface "$TRAFFIC_PORT" type=internal

for _ in {1..20}; do
  if ip link show "$TRAFFIC_PORT" >/dev/null 2>&1; then
    break
  fi
  sleep 0.2
done

if ! ip link show "$TRAFFIC_PORT" >/dev/null 2>&1; then
  echo "traffic port did not appear as a Linux interface: $TRAFFIC_PORT" >&2
  exit 1
fi

ip link set "$TRAFFIC_PORT" up
ip addr replace "$TRAFFIC_IP" dev "$TRAFFIC_PORT"

echo "Host traffic port is ready:"
ip -br addr show "$TRAFFIC_PORT"
