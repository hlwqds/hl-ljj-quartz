#!/usr/bin/env bash
set -euo pipefail

HUGEPAGES_2M="${HUGEPAGES_2M:-256}"
HUGEPAGE_MOUNT="${HUGEPAGE_MOUNT:-/mnt/huge}"

if [[ $EUID -ne 0 ]]; then
  echo "run as root" >&2
  exit 1
fi

mkdir -p "$HUGEPAGE_MOUNT"

if ! mountpoint -q "$HUGEPAGE_MOUNT"; then
  mount -t hugetlbfs nodev "$HUGEPAGE_MOUNT"
fi

echo "$HUGEPAGES_2M" > /proc/sys/vm/nr_hugepages

grep -E 'HugePages_Total|HugePages_Free|Hugepagesize' /proc/meminfo
