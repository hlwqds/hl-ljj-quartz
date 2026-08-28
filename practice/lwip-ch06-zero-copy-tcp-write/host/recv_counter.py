#!/usr/bin/env python3
"""
第六章实验主机端接收器。

用法：
  python3 recv_counter.py [--port 8006] [--conns N] [--rate-mbps R]
                          [--read-size N] [--quiet]

行为：
  监听 TCP 端口，顺序接受 N 个连接（N<=0 表示无限），每个连接读到底（EOF），
  边读边统计字节数与 Fletcher-16 校验和（与 guest 端同一算法），结束时打印
  一行摘要：字节数、耗时、吞吐、校验值。

  --rate-mbps R：把读取速率限制在约 R Mbit/s —— 反压故障注入用。
    实现：按「本连接已收字节 / 目标速率」计算应消耗的时间预算，
    读取超出预算就 sleep 补差（按字节记账，不按单次 recv 记账）。
    正常吞吐测试不要加该参数；反压轮建议 --rate-mbps 2 左右。
"""

import argparse
import socket
import sys
import time


def fletcher16(data, s1, s2):
    for b in data:
        s1 = (s1 + b) % 255
        s2 = (s2 + s1) % 255
    return s1, s2


def serve_one(conn, addr, rate_mbps, read_size, quiet, idx):
    conn.settimeout(120)
    total = 0
    s1 = s2 = 0
    t0 = time.monotonic()
    first_ts = None
    last_log = t0
    while True:
        chunk = conn.recv(read_size)
        if not chunk:
            break
        if first_ts is None:
            first_ts = time.monotonic()
        total += len(chunk)
        s1, s2 = fletcher16(chunk, s1, s2)
        # 按字节记账的速率桶：应耗时间 = 已收字节 / 速率，超支即补睡
        if rate_mbps > 0 and first_ts is not None:
            budget = total * 8.0 / (rate_mbps * 1e6)
            debt = (t0 + budget) - time.monotonic()
            if debt > 0:
                time.sleep(debt)
        now = time.monotonic()
        if not quiet and now - last_log >= 1.0:
            el = now - t0
            mbit = total * 8 / el / 1e6 if el > 0 else 0.0
            print(f"HOST-RX conn#{idx} t={el:7.3f}s got={total} mbit={mbit:.2f}",
                  flush=True)
            last_log = now
    dur = time.monotonic() - t0
    useful_dur = time.monotonic() - first_ts if first_ts else dur
    mbit = total * 8 / useful_dur / 1e6 if useful_dur > 0 else 0.0
    print(f"HOST-DONE conn#{idx} addr={addr[0]}:{addr[1]} bytes={total} "
          f"dur={useful_dur:.3f}s mbit={mbit:.2f} digest={(s2 << 8) | s1:04x}",
          flush=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8006)
    ap.add_argument("--conns", type=int, default=-1,
                    help="最多接受几个连接，<=0 表示无限")
    ap.add_argument("--rate-mbps", dest="rate_mbps", type=float, default=0,
                    help="限速读取（Mbit/s），0 不限速")
    ap.add_argument("--read-size", dest="read_size", type=int, default=65536)
    ap.add_argument("--quiet", action="store_true", help="不打印逐秒进度行")
    global quiet
    args = ap.parse_args()
    quiet = args.quiet

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("0.0.0.0", args.port))
    srv.listen(4)
    print(f"listening on :{args.port} conns={'inf' if args.conns <= 0 else args.conns} "
          f"rate_mbps={args.rate_mbps}", flush=True)

    n = 0
    while args.conns <= 0 or n < args.conns:
        try:
            conn, addr = srv.accept()
        except KeyboardInterrupt:
            break
        n += 1
        with conn:
            serve_one(conn, addr, args.rate_mbps, args.read_size, quiet, n)
    print("receiver exiting", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
