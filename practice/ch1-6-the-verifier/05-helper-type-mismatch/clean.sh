#!/usr/bin/env bash
cd "$(dirname "$0")"
rm -f *.o
sudo rm -f /sys/fs/bpf/type_bad 2>/dev/null
sudo rm -f /sys/fs/bpf/type_good 2>/dev/null
echo "Cleaned."
