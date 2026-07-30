#!/usr/bin/env bash
set -euo pipefail

GUEST_IMAGE="${GUEST_IMAGE:-}"
GUEST_IMAGE_FORMAT="${GUEST_IMAGE_FORMAT:-qcow2}"
VM_NAME="${VM_NAME:-dpdk-guest}"
MEM_SIZE="${MEM_SIZE:-1024M}"
SMP="${SMP:-2}"
VHOST_SOCKET="${VHOST_SOCKET:-/var/run/openvswitch/vhost-user0.sock}"
MAC="${MAC:-52:54:00:12:34:56}"
MGMT_MAC="${MGMT_MAC:-52:54:00:12:34:57}"
QUEUES="${QUEUES:-1}"
HUGEPAGE_MOUNT="${HUGEPAGE_MOUNT:-/dev/hugepages}"
QEMU_BIN="${QEMU_BIN:-qemu-system-x86_64}"
CLOUD_INIT_ISO="${CLOUD_INIT_ISO:-}"
MGMT_SSH_PORT="${MGMT_SSH_PORT:-10022}"
ENABLE_MGMT_NET="${ENABLE_MGMT_NET:-1}"
QEMU_DAEMONIZE="${QEMU_DAEMONIZE:-0}"
QEMU_PIDFILE="${QEMU_PIDFILE:-}"

if [[ -z "$GUEST_IMAGE" ]]; then
  echo "set GUEST_IMAGE=/path/to/guest.qcow2" >&2
  exit 1
fi

if [[ $EUID -ne 0 ]]; then
  echo "run as root so QEMU can use hugepages/vhost-user socket" >&2
  exit 1
fi

mkdir -p "$(dirname "$VHOST_SOCKET")"
rm -f "$VHOST_SOCKET"

# QEMU runs as root in this lab, while Fedora's ovs-vswitchd runs as
# openvswitch:hugetlbfs. A permissive socket mode lets the OVS-DPDK client
# connect to the vhost-user socket that QEMU creates.
umask 000

qemu_args=(
  -name "$VM_NAME"
  -enable-kvm
  -cpu host
  -smp "$SMP"
  -m "$MEM_SIZE"
  -object "memory-backend-file,id=mem0,size=$MEM_SIZE,mem-path=$HUGEPAGE_MOUNT,share=on,prealloc=on"
  -numa node,memdev=mem0
  -drive "file=$GUEST_IMAGE,if=virtio,format=$GUEST_IMAGE_FORMAT"
  -chardev "socket,id=char0,path=$VHOST_SOCKET,server=on,wait=off"
  -netdev "type=vhost-user,id=net0,chardev=char0,vhostforce=on,queues=$QUEUES"
  -device "virtio-net-pci,netdev=net0,mac=$MAC,mq=on,vectors=$((2 * QUEUES + 2))"
  -serial mon:stdio
  -display none
)

if [[ "$ENABLE_MGMT_NET" == "1" ]]; then
  qemu_args+=(
    -netdev "user,id=mgmt0,hostfwd=tcp:127.0.0.1:$MGMT_SSH_PORT-:22"
    -device "virtio-net-pci,netdev=mgmt0,mac=$MGMT_MAC"
  )
fi

if [[ -n "$CLOUD_INIT_ISO" ]]; then
  qemu_args+=(-drive "file=$CLOUD_INIT_ISO,if=virtio,media=cdrom,readonly=on")
fi

if [[ "$QEMU_DAEMONIZE" == "1" ]]; then
  qemu_args+=(-daemonize)
  if [[ -n "$QEMU_PIDFILE" ]]; then
    qemu_args+=(-pidfile "$QEMU_PIDFILE")
  fi
fi

exec "$QEMU_BIN" "${qemu_args[@]}"
