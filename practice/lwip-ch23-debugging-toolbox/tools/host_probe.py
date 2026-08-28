#!/usr/bin/env python3
# lwIP 深度解析（二十三）：宿主机侧探针 —— 经 QEMU hostfwd 打 guest echo server
import socket, time, sys

n = int(sys.argv[1]) if len(sys.argv) > 1 else 5
for i in range(n):
    t0 = time.perf_counter()
    s = socket.create_connection(("127.0.0.1", 8031), timeout=2)
    connect_ms = (time.perf_counter() - t0) * 1000
    payload = f"host-probe-{i:02d}\n".encode()
    t1 = time.perf_counter()
    s.sendall(payload)
    buf = b""
    while len(buf) < len(payload):
        chunk = s.recv(64)
        if not chunk:
            break
        buf += chunk
    rtt_ms = (time.perf_counter() - t1) * 1000
    s.close()
    print(f"probe {i}: connect={connect_ms:.1f}ms echo_rtt={rtt_ms:.2f}ms "
          f"payload={len(buf)}B match={buf == payload}")
    time.sleep(0.15)
