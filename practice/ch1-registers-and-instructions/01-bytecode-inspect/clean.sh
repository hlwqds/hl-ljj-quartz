#!/usr/bin/env bash
cd "$(dirname "$0")"
rm -f *.o
rm -f /tmp/bpf_verify.log 2>/dev/null
sudo rm -f /sys/fs/bpf/*_loop /sys/fs/bpf/jit_debug_example /sys/fs/bpf/percpu_vstack 2>/dev/null
echo "Cleaned."
