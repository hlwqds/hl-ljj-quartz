#!/usr/bin/env python3
"""ch19 开环 TCP 回显压测：按固定节奏发请求（不等回复才发下一个），
记录每个请求的 RTT，输出分位数。用于优先级矩阵 / 故障注入对照。

用法: bench_openloop.py [--port 8022] [--count 400] [--pace-ms 5] [--size 128]
"""
import argparse
import socket
import time
import statistics
import struct

# 4 字节长度前缀 + payload，回显后按前缀切帧重组


def percentile(sorted_xs, p):
    if not sorted_xs:
        return float("nan")
    k = (len(sorted_xs) - 1) * p / 100.0
    f = int(k)
    c = min(f + 1, len(sorted_xs) - 1)
    return sorted_xs[f] + (sorted_xs[c] - sorted_xs[f]) * (k - f)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8022)
    ap.add_argument("--count", type=int, default=400)
    ap.add_argument("--pace-ms", type=float, default=5.0)
    ap.add_argument("--size", type=int, default=128)
    ap.add_argument("--timeout", type=float, default=3.0)
    ap.add_argument("--label", default="run")
    args = ap.parse_args()

    t_c0 = time.perf_counter()
    sock = None
    try:
        sock = socket.create_connection((args.host, args.port), timeout=args.timeout)
        conn_ms = (time.perf_counter() - t_c0) * 1000.0
    except (socket.timeout, OSError):
        print(f"### BENCH label={args.label} sent={args.count} ok=0 stall={args.count} "
              f"wall_s=0.0 CONNECT_FAIL")
        return
    sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    print(f"### CONN label={args.label} connect_ms={conn_ms:.1f}")

    payload = b"A" * args.size
    frame = struct.pack("<I", args.size) + payload

    rtts = []
    stalls = 0
    t_start = time.perf_counter()
    send_times = []
    for i in range(args.count):
        target = t_start + i * args.pace_ms / 1000.0
        delay = target - time.perf_counter()
        if delay > 0:
            time.sleep(delay)
        t0 = time.perf_counter()
        try:
            sock.sendall(frame)
            got = 0
            while got < args.size + 4:
                chunk = sock.recv(args.size + 4 - got)
                if not chunk:
                    break
                got += len(chunk)
            dt_ms = (time.perf_counter() - t0) * 1000.0
            if got == args.size + 4:
                rtts.append(dt_ms)
                if dt_ms > 1000:
                    stalls += 1
            else:
                stalls += 1
        except (socket.timeout, ConnectionResetError):
            stalls += 1
    elapsed = time.perf_counter() - t_start
    sock.close()

    s = sorted(rtts)
    print(f"### BENCH label={args.label} sent={args.count} ok={len(rtts)} "
          f"stall={stalls} wall_s={elapsed:.2f}")
    if s:
        print(f"### RTTms avg={statistics.mean(s):.2f} p50={percentile(s,50):.2f} "
              f"p90={percentile(s,90):.2f} p99={percentile(s,99):.2f} max={s[-1]:.2f}")


if __name__ == "__main__":
    main()
