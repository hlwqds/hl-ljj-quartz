#!/usr/bin/env bash
cd "$(dirname "$0")"
rm -f *.o
sudo rm -f /sys/fs/bpf/basic_alloc /sys/fs/bpf/leak_fail /sys/fs/bpf/conntrack /sys/fs/bpf/list_demo /sys/fs/bpf/rb_demo 2>/dev/null
echo "Cleaned."
