#!/usr/bin/env bash
set -euo pipefail

HUGEPAGES_2M="${HUGEPAGES_2M:-1024}"
HUGEPAGE_MOUNT="${HUGEPAGE_MOUNT:-/dev/hugepages}"
HUGEPAGE_GROUP="${HUGEPAGE_GROUP:-hugetlbfs}"

if [[ $EUID -ne 0 ]]; then
  echo "run as root" >&2
  exit 1
fi

mkdir -p "$HUGEPAGE_MOUNT"

if [[ -w /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages ]]; then
  echo "$HUGEPAGES_2M" > /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages
else
  echo "$HUGEPAGES_2M" > /proc/sys/vm/nr_hugepages
fi

mount_opts="pagesize=2M,mode=1770"
if getent group "$HUGEPAGE_GROUP" >/dev/null; then
  mount_opts="$mount_opts,gid=$(getent group "$HUGEPAGE_GROUP" | cut -d: -f3)"
fi

if mountpoint -q "$HUGEPAGE_MOUNT"; then
  current_opts="$(findmnt -no OPTIONS "$HUGEPAGE_MOUNT" || true)"
  if [[ "$current_opts" != *"pagesize=2M"* ]]; then
    echo "Remount $HUGEPAGE_MOUNT with explicit 2MiB hugepages"
    if ! umount "$HUGEPAGE_MOUNT"; then
      cat >&2 <<EOF
failed to unmount $HUGEPAGE_MOUNT.
Stop processes using hugepages, then retry:
  systemctl stop ovs-vswitchd
  umount $HUGEPAGE_MOUNT
EOF
      exit 1
    fi
    mount -t hugetlbfs -o "$mount_opts" nodev "$HUGEPAGE_MOUNT"
  fi
else
  mount -t hugetlbfs -o "$mount_opts" nodev "$HUGEPAGE_MOUNT"
fi

chmod 1770 "$HUGEPAGE_MOUNT"
if getent group "$HUGEPAGE_GROUP" >/dev/null; then
  chgrp "$HUGEPAGE_GROUP" "$HUGEPAGE_MOUNT"
fi

echo "Hugepages:"
grep -E 'HugePages_Total|HugePages_Free|Hugepagesize' /proc/meminfo
echo "Mounted at: $HUGEPAGE_MOUNT"
findmnt "$HUGEPAGE_MOUNT" || true
