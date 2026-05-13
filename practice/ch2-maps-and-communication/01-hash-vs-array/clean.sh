#!/usr/bin/env bash
cd "$(dirname "$0")"
rm -f *.o
sudo rm -f /sys/fs/bpf/hash_null_bad 2>/dev/null
sudo rm -f /sys/fs/bpf/array_no_null_good 2>/dev/null
echo "Cleaned."
