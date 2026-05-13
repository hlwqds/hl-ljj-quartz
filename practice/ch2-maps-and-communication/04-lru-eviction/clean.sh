#!/usr/bin/env bash
cd "$(dirname "$0")"
rm -f *.o
sudo rm -f /sys/fs/bpf/lru_demo 2>/dev/null
echo "Cleaned."
