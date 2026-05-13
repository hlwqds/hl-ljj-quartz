#!/usr/bin/env bash
cd "$(dirname "$0")"
rm -f *.o *.o.tmp
sudo rm -f /sys/fs/bpf/explosion_bad 2>/dev/null
sudo rm -f /sys/fs/bpf/explosion_good 2>/dev/null
echo "Cleaned."
