#!/usr/bin/env python3
# 实验 d 主机侧洪峰发生器：以固定速率向 QEMU hostfwd UDP 端口灌 datagram
import socket, sys, time

host, port = "127.0.0.1", 8020
duration = float(sys.argv[1]) if len(sys.argv) > 1 else 22.0
pps      = int(sys.argv[2]) if len(sys.argv) > 2 else 800   # packets per second
payload  = b"F" * 1200

s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
n = 0
t_end = time.time() + duration
interval = 1.0 / pps
while time.time() < t_end:
    s.sendto(payload, (host, port))
    n += 1
    time.sleep(interval)
print(f"flood done sent={n} dur={duration}s pps={pps}")
