#!/usr/bin/env bash
set -euo pipefail

BRIDGE="${BRIDGE:-br-dpdk}"
VHOST_PORT="${VHOST_PORT:-vhost-user0}"
VHOST_SOCKET="${VHOST_SOCKET:-/var/run/openvswitch/vhost-user0.sock}"
SOCKET_MEM="${SOCKET_MEM:-}"
HUGEPAGE_MOUNT="${HUGEPAGE_MOUNT:-/dev/hugepages}"
OVS_TIMEOUT="${OVS_TIMEOUT:-15}"
SYSTEMD_TIMEOUT="${SYSTEMD_TIMEOUT:-30}"

run_cmd() {
  echo "+ $*"
  "$@"
}

show_ovs_failure_logs() {
  echo
  echo "===== ovs-vswitchd status =====" >&2
  systemctl status ovs-vswitchd --no-pager >&2 || true

  echo
  echo "===== ovs-vswitchd journal =====" >&2
  journalctl -u ovs-vswitchd -n 120 --no-pager >&2 || true

  echo
  echo "===== ovsdb-server journal =====" >&2
  journalctl -u ovsdb-server -n 80 --no-pager >&2 || true

  if [[ -r /var/log/openvswitch/ovs-vswitchd.log ]]; then
    echo
    echo "===== /var/log/openvswitch/ovs-vswitchd.log =====" >&2
    tail -n 160 /var/log/openvswitch/ovs-vswitchd.log >&2 || true
  fi
}

detect_socket_mem() {
  local per_socket_mb="${OVS_SOCKET_MEM_PER_NODE:-512}"
  local nodes=()

  if compgen -G "/sys/devices/system/node/node[0-9]*" >/dev/null; then
    local node_dir
    for node_dir in /sys/devices/system/node/node[0-9]*; do
      [[ -d "$node_dir" ]] || continue
      nodes+=("${node_dir##*/node}")
    done
  fi

  if [[ "${#nodes[@]}" -eq 0 ]]; then
    echo "$per_socket_mb"
    return
  fi

  local result="$per_socket_mb"
  local i
  for ((i = 1; i < ${#nodes[@]}; i++)); do
    result+=",$per_socket_mb"
  done
  echo "$result"
}

restart_ovs() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
  fi

  if [[ "${ID:-}" == "fedora" ]]; then
    echo "+ restart Fedora Open vSwitch units"
    timeout "$SYSTEMD_TIMEOUT" systemctl restart ovsdb-server
    if ! timeout "$SYSTEMD_TIMEOUT" systemctl restart ovs-vswitchd; then
      show_ovs_failure_logs
      cat >&2 <<'EOF'
ovs-vswitchd failed to restart.

The logs above should contain the actual DPDK/EAL/hugepage error.
EOF
      return 1
    fi
    timeout "$SYSTEMD_TIMEOUT" systemctl start openvswitch || true
    return 0
  fi

  if systemctl list-unit-files | grep -q '^openvswitch-switch'; then
    timeout "$SYSTEMD_TIMEOUT" systemctl restart openvswitch-switch
  elif systemctl list-unit-files | grep -q '^openvswitch'; then
    timeout "$SYSTEMD_TIMEOUT" systemctl restart openvswitch
  fi
}

if [[ $EUID -ne 0 ]]; then
  echo "run as root" >&2
  exit 1
fi

if ! command -v ovs-vsctl >/dev/null; then
  cat >&2 <<'EOF'
ovs-vsctl not found.

Install an Open vSwitch package with DPDK support first, for example:
  Ubuntu/Debian: apt-get install openvswitch-switch-dpdk
  Fedora/RHEL:   install the distro's Open vSwitch DPDK package, or build OVS with DPDK

This script configures the Host OVS-DPDK backend. Without OVS-DPDK, QEMU can
still create the vhost-user socket, but there is no host backend connected to it.
EOF
  exit 127
fi

if [[ -z "$SOCKET_MEM" ]]; then
  SOCKET_MEM="$(detect_socket_mem)"
fi

run_cmd ovs-vsctl --timeout="$OVS_TIMEOUT" --no-wait set Open_vSwitch . other_config:dpdk-init=true
run_cmd ovs-vsctl --timeout="$OVS_TIMEOUT" --no-wait set Open_vSwitch . other_config:dpdk-socket-mem="$SOCKET_MEM"
run_cmd ovs-vsctl --timeout="$OVS_TIMEOUT" --no-wait set Open_vSwitch . other_config:dpdk-hugepage-dir="$HUGEPAGE_MOUNT"

restart_ovs

run_cmd ovs-vsctl --timeout="$OVS_TIMEOUT" --may-exist add-br "$BRIDGE" -- set bridge "$BRIDGE" datapath_type=netdev
run_cmd ovs-vsctl --timeout="$OVS_TIMEOUT" --may-exist add-port "$BRIDGE" "$VHOST_PORT" \
  -- set Interface "$VHOST_PORT" type=dpdkvhostuserclient \
     options:vhost-server-path="$VHOST_SOCKET" \
     options:vhost-client-reconnect-interval=1000

run_cmd ovs-vsctl --timeout="$OVS_TIMEOUT" show

cat <<EOF

Created OVS-DPDK vhost-user client port:
  bridge: $BRIDGE
  port:   $VHOST_PORT
  socket: $VHOST_SOCKET

QEMU must create this socket with:
  -chardev socket,path=$VHOST_SOCKET,server=on,wait=off,...
EOF
