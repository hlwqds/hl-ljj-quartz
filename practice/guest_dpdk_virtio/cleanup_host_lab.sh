#!/usr/bin/env bash
set -euo pipefail

LAB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$LAB_DIR/generated/qemu-env.sh}"

VM_NAME="${VM_NAME:-dpdk-guest}"
BRIDGE="${BRIDGE:-br-dpdk}"
VHOST_PORT="${VHOST_PORT:-vhost-user0}"
VHOST_SOCKET="${VHOST_SOCKET:-/var/run/openvswitch/vhost-user0.sock}"
TRAFFIC_PORT="${TRAFFIC_PORT:-host-traffic0}"
TRAFFIC_IP="${TRAFFIC_IP:-198.18.0.1/24}"
HUGEPAGE_MOUNT="${HUGEPAGE_MOUNT:-/dev/hugepages}"
QEMU_PIDFILE="${QEMU_PIDFILE:-$LAB_DIR/generated/qemu.pid}"
OVS_TIMEOUT="${OVS_TIMEOUT:-15}"
REMOVE_HUGEPAGE_MOUNT="${REMOVE_HUGEPAGE_MOUNT:-0}"
REMOVE_GENERATED="${REMOVE_GENERATED:-0}"

log_step() {
  printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"
}

if [[ $EUID -ne 0 ]]; then
  echo "run as root: sudo $0" >&2
  exit 1
fi

if [[ -f "$ENV_FILE" ]]; then
  log_step "Load environment: $ENV_FILE"
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
fi

# --- 1. Stop QEMU ---
log_step "Stop QEMU VM: $VM_NAME"
pids=()

if [[ -r "$QEMU_PIDFILE" ]]; then
  pid="$(tr -dc '0-9' < "$QEMU_PIDFILE" || true)"
  [[ -n "$pid" ]] && pids+=("$pid")
fi

if command -v pgrep >/dev/null; then
  while read -r pid; do
    [[ -n "$pid" ]] && pids+=("$pid")
  done < <(pgrep -f "qemu-system.*-name ${VM_NAME}" || true)
fi

seen=" "
for pid in "${pids[@]}"; do
  [[ "$pid" =~ ^[0-9]+$ ]] || continue
  [[ "$pid" != "$$" ]] || continue
  [[ "$seen" != *" $pid "* ]] || continue
  seen+=" $pid "

  if [[ -d "/proc/$pid" ]]; then
    echo "  kill $pid"
    kill "$pid" 2>/dev/null || true
    for _ in {1..20}; do
      [[ -d "/proc/$pid" ]] || break
      sleep 0.2
    done
    if [[ -d "/proc/$pid" ]]; then
      echo "  force kill $pid"
      kill -9 "$pid" 2>/dev/null || true
    fi
  fi
done

rm -f "$QEMU_PIDFILE"

# --- 2. Clean up OVS ---
if command -v ovs-vsctl >/dev/null; then
  log_step "Remove OVS ports and bridge"
  ovs-vsctl --timeout="$OVS_TIMEOUT" --if-exists del-port "$BRIDGE" "$TRAFFIC_PORT" || true
  echo "  removed port $TRAFFIC_PORT from $BRIDGE"

  ovs-vsctl --timeout="$OVS_TIMEOUT" --if-exists del-port "$BRIDGE" "$VHOST_PORT" || true
  echo "  removed port $VHOST_PORT from $BRIDGE"

  ovs-vsctl --timeout="$OVS_TIMEOUT" --if-exists del-br "$BRIDGE" || true
  echo "  removed bridge $BRIDGE"

  log_step "Clear OVS-DPDK configuration"
  ovs-vsctl --timeout="$OVS_TIMEOUT" --if-exists remove Open_vSwitch . other_config dpdk-init || true
  ovs-vsctl --timeout="$OVS_TIMEOUT" --if-exists remove Open_vSwitch . other_config dpdk-socket-mem || true
  ovs-vsctl --timeout="$OVS_TIMEOUT" --if-exists remove Open_vSwitch . other_config dpdk-hugepage-dir || true
  echo "  cleared dpdk-init, dpdk-socket-mem, dpdk-hugepage-dir"
fi

# --- 3. Remove traffic port IP and vhost socket ---
log_step "Remove network artifacts"
if ip link show "$TRAFFIC_PORT" &>/dev/null; then
  ip addr del "$TRAFFIC_IP" dev "$TRAFFIC_PORT" 2>/dev/null || true
  ip link set "$TRAFFIC_PORT" down 2>/dev/null || true
  echo "  removed IP and downed $TRAFFIC_PORT"
fi

rm -f "$VHOST_SOCKET"
echo "  removed vhost socket: $VHOST_SOCKET"

# --- 4. Release hugepages ---
log_step "Release hugepages"
if [[ -w /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages ]]; then
  echo 0 > /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages
else
  echo 0 > /proc/sys/vm/nr_hugepages
fi
echo "  set hugepages to 0"

if [[ "$REMOVE_HUGEPAGE_MOUNT" == "1" ]] && mountpoint -q "$HUGEPAGE_MOUNT"; then
  umount "$HUGEPAGE_MOUNT" || echo "  warning: could not unmount $HUGEPAGE_MOUNT (still in use?)" >&2
  echo "  unmounted $HUGEPAGE_MOUNT"
fi

echo "  Hugepages:"
grep -E 'HugePages_Total|HugePages_Free|Hugepagesize' /proc/meminfo

# --- 5. Clean up generated files ---
if [[ "$REMOVE_GENERATED" == "1" && -d "$LAB_DIR/generated" ]]; then
  log_step "Remove generated files"
  rm -rf "$LAB_DIR/generated"
  echo "  removed $LAB_DIR/generated"
fi

log_step "Cleanup complete"
