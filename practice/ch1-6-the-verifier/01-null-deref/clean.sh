#!/usr/bin/env bash
cd "$(dirname "$0")"
rm -f *.o
sudo rm -f /sys/fs/bpf/null_deref_bad 2>/dev/null
sudo rm -f /sys/fs/bpf/null_deref_good 2>/dev/null
echo "Cleaned."
