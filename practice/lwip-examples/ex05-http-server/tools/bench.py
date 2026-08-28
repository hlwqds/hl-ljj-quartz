#!/usr/bin/env python3
"""ex05 小压测：串行 50 请求 × {keep-alive, 非 keep-alive} 两组对比。

对 ex05-http-server（hostfwd tcp::8240-:80）各发 count 个 GET：
  - ka   组：一条 TCP 连接复用到底，验证 HTTP keep-alive；
  - noka 组：每请求新建连接并带 Connection: close。
全程单线程串行、两组同时段连续测量（避免宿主机负载漂移毁掉可比性），
每组先做 warmup=5 次预热把 ARP 首包税/SLIRP 冷路径抖出测量窗。

用法：
  python3 tools/bench.py                     # 默认 127.0.0.1:8240 /hello 50 次
  python3 tools/bench.py --path /info --count 50

输出每组一行人读摘要 + 一行 JSON（延迟单位 ms）。
"""
import argparse
import json
import socket
import sys
import time

WARMUP = 5


def read_response(sock):
    """读完整 HTTP 响应：头解析 Content-Length；无 CL 则读到对端关闭。"""
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = sock.recv(4096)
        if not chunk:
            raise ConnectionError("closed before headers complete")
        buf += chunk
    head, _, rest = buf.partition(b"\r\n\r\n")
    clen = None
    for line in head.split(b"\r\n")[1:]:
        k, _, v = line.partition(b":")
        if k.lower() == b"content-length":
            clen = int(v.strip())
        if k.lower() == b"connection" and b"close" in v.lower():
            clen = clen if clen is not None else None  # close 语义在无 CL 分支处理
    if clen is None:
        while True:
            chunk = sock.recv(4096)
            if not chunk:
                return rest
            rest += chunk
    body = rest
    while len(body) < clen:
        chunk = sock.recv(min(8192, clen - len(body)))
        if not chunk:
            raise ConnectionError(f"closed early {len(body)}/{clen}")
        body += chunk
    return body


def run_group(mode, host, port, path, count):
    """串行跑一组；返回 (lat_ms 列表, fail 数)。ka 复用连接，noka 每次新建。"""
    req_tpl = (f"GET {path} HTTP/1.1\r\nHost: ex05-bench\r\n"
               f"Accept: */*\r\n").encode()
    if mode == "noka":
        req_tpl += b"Connection: close\r\n"
    req_tpl += b"\r\n"

    ka_sock = socket.create_connection((host, port), timeout=10) if mode == "ka" else None

    def one():
        s = ka_sock if mode == "ka" else \
            socket.create_connection((host, port), timeout=10)
        try:
            t0 = time.perf_counter()
            s.sendall(req_tpl)
            read_response(s)
            return (time.perf_counter() - t0) * 1000.0
        finally:
            if mode == "noka":
                s.close()

    for _ in range(WARMUP):          # 预热：不计入统计
        one()

    lat, fail = [], 0
    for _ in range(count):
        try:
            lat.append(one())
        except (OSError, ConnectionError):
            fail += 1
            if mode == "ka":         # 连接坏了就重修一条继续测完
                ka_sock.close()
                ka_sock = socket.create_connection((host, port), timeout=10)
    if ka_sock:
        ka_sock.close()
    return lat, fail


def summarize(mode, path, count, lat, fail):
    ls = sorted(lat)
    n = len(ls)
    summary = {
        "mode": mode,
        "path": path,
        "sent": count,
        "ok": n,
        "fail": fail,
        "avg_ms": round(sum(ls) / n, 3) if n else None,
        "p50_ms": round(ls[n // 2], 3) if n else None,
        "p90_ms": round(ls[min(n - 1, int(n * 0.9))], 3) if n else None,
        "max_ms": round(ls[-1], 3) if n else None,
    }
    print(f"[{mode:4s}] ok={n}/{count} avg={summary['avg_ms']}ms "
          f"p50={summary['p50_ms']}ms p90={summary['p90_ms']}ms "
          f"max={summary['max_ms']}ms")
    print(json.dumps(summary))
    return summary


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8240)
    ap.add_argument("--path", default="/hello")
    ap.add_argument("--count", type=int, default=50)
    args = ap.parse_args()

    results = []
    for mode in ("ka", "noka"):
        lat, fail = run_group(mode, args.host, args.port, args.path, args.count)
        results.append(summarize(mode, args.path, args.count, lat, fail))

    # 差异结论直接给出：非 keep-alive 的平均延迟中多出的部分 ≈ 每请求
    # 重走 三次握手+SLIRP 转发表查找 的建连成本。
    if all(r["avg_ms"] is not None for r in results):
        d = round(results[1]["avg_ms"] - results[0]["avg_ms"], 3)
        print(f"[diff] noka_avg - ka_avg = +{d}ms per request")

    sys.exit(0 if all(r["fail"] == 0 for r in results) else 1)


if __name__ == "__main__":
    main()
