#!/usr/bin/env bash
cd "$(dirname "$0")"
rm -f *.o
sudo rm -f /sys/fs/bpf/var_offset_bad 2>/dev/null
sudo rm -f /sys/fs/bpf/var_offset_good 2>/dev/null
echo "Cleaned."
