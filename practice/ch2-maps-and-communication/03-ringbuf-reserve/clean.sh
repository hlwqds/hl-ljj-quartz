#!/usr/bin/env bash
cd "$(dirname "$0")"
rm -f *.o
sudo rm -f /sys/fs/bpf/ringbuf_bad 2>/dev/null
sudo rm -f /sys/fs/bpf/ringbuf_good 2>/dev/null
echo "Cleaned."
