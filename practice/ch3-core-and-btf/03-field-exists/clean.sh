#!/usr/bin/env bash
cd "$(dirname "$0")"
rm -f *.o vmlinux.h
sudo rm -f /sys/fs/bpf/field_bad /sys/fs/bpf/field_good 2>/dev/null
echo "Cleaned."
