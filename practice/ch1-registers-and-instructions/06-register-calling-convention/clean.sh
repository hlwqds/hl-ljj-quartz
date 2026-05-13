#!/usr/bin/env bash
cd "$(dirname "$0")"
rm -f *.o
sudo rm -f /sys/fs/bpf/param_limit_good 2>/dev/null
echo "Cleaned."
