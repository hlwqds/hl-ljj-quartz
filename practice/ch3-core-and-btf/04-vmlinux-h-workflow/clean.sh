#!/usr/bin/env bash
cd "$(dirname "$0")"
rm -f *.o vmlinux.h
sudo rm -f /sys/fs/bpf/core_workflow 2>/dev/null
echo "Cleaned."
