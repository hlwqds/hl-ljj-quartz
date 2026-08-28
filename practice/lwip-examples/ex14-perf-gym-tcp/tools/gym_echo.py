#!/usr/bin/env python3
"""ex14 LB 腿宿主反射器（gym_echo）—— guest 镜像回声的外部对端。

用法：
  python3 tools/gym_echo.py [--port 8312]

背景（设计裁决，证据链见 README「排障」节）：本环境 QEMU 下「目的地=自身IP」的
TCP 流量会进 lwIP 内建回环队列（netif_loop_output），持续吞吐会把 tcpip 线程
咬死（gdb 现场取证两次）。所以健身房的自环基准改为镜像回声：guest 连到宿主机
10.0.2.2:8312（SLIRP 落 loopback 同端口），把图样灌出去、收同样的字节数回来，
两端 digest 校验。全部流量走实测稳定的 openeth+SLIRP 外部路径。

行为：每条连接线程内 recv→sendall 原样回显，直到对端关闭；连接之间并发独立
（sc4 探针需要同时持有若干条空闲连接占位）。每条连接结束时打一行摘要。
输出行以 GYMECHO- 开头便于 grep 归档。
"""

import argparse
import socket
import sys
import threading
import time


def serve_conn(conn: socket.socket, addr, idx: int):
    total_in = 0
    t0 = None
    try:
        conn.settimeout(300)
        while True:
            chunk = conn.recv(262144)
            if not chunk:
                break
            if t0 is None:
                t0 = time.monotonic()
            total_in += len(chunk)
            conn.sendall(chunk)
    except OSError as e:
        print(f"GYMECHO-ERR conn#{idx} peer={addr[0]}:{addr[1]} err={e} "
              f"bytes_before_err={total_in}", flush=True)
    finally:
        try:
            conn.close()
        except OSError:
            pass
    dur = time.monotonic() - t0 if t0 else 0.0
    mbit = total_in * 8 / dur / 1e6 if dur > 0 else 0.0
    print(f"GYMECHO-DONE conn#{idx} peer={addr[0]}:{addr[1]} bytes={total_in} "
          f"dur={dur:.3f}s mbit={mbit:.2f}", flush=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8312)
    args = ap.parse_args()

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("0.0.0.0", args.port))
    srv.listen(16)
    print(f"GYMECHO-LISTEN port={args.port} mode=duplex-reflector", flush=True)

    idx = 0
    try:
        while True:
            try:
                conn, addr = srv.accept()
            except KeyboardInterrupt:
                break
            idx += 1
            threading.Thread(target=serve_conn, args=(conn, addr, idx),
                             daemon=True).start()
    finally:
        srv.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
