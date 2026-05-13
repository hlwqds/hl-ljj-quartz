#!/usr/bin/env bash
cd "$(dirname "$0")"
rm -f *.o
sudo rm -rf /sys/fs/bpf/tail_call_demo 2>/dev/null
echo "Cleaned."
