#!/usr/bin/env python3
"""背景负载锤子（时长模式）：跑满 --dur 秒后干净退出并报速率。"""
import argparse
import socket
import time

ap = argparse.ArgumentParser()
ap.add_argument("--port", type=int, default=8022)
ap.add_argument("--size", type=int, default=512)
ap.add_argument("--dur", type=float, default=6.0)
args = ap.parse_args()

s = socket.create_connection(("127.0.0.1", args.port), timeout=5)
s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
payload = b"H" * args.size
n = 0
t0 = time.time()
try:
    while time.time() - t0 < args.dur:
        s.sendall(payload)
        got = 0
        while got < args.size:
            chunk = s.recv(args.size - got)
            if not chunk:
                raise ConnectionResetError
            got += len(chunk)
        n += 1
except (BrokenPipeError, ConnectionResetError, socket.timeout):
    pass
finally:
    dur = time.time() - t0
    print(f"$$$ HAMMER rounds={n} dur={dur:.2f}s rate={n/dur:.0f}/s")
    s.close()
