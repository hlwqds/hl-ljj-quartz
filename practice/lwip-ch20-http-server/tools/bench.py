#!/usr/bin/env python3
"""ch20 实验 A 压测器：keep-alive 开/关两种模式，QPS 与延迟分布。

用法：
  python3 tools/bench.py --mode ka   --path /small --count 300 --workers 4
  python3 tools/bench.py --mode noka --path /big   --count 100 --workers 4

输出一行 JSON 摘要（供成表），延迟单位 ms。
"""
import argparse, json, socket, sys, time


def read_response(sock):
    """读完整 HTTP 响应：解析头拿 Content-Length（缺失则读到对端关闭）。"""
    buf = b""
    hdr_end = -1
    while hdr_end < 0:
        chunk = sock.recv(4096)
        if not chunk:
            raise ConnectionError("closed before headers")
        buf += chunk
        hdr_end = buf.find(b"\r\n\r\n")
    head, rest = buf[:hdr_end], buf[hdr_end + 4:]
    clen = None
    conn_close = False
    for line in head.split(b"\r\n")[1:]:
        k, _, v = line.partition(b":")
        if k.lower() == b"content-length":
            clen = int(v.strip())
        if k.lower() == b"connection" and b"close" in v.lower():
            conn_close = True
    if clen is None:
        while True:
            chunk = sock.recv(4096)
            if not chunk:
                break
            rest += chunk
        return rest
    body = rest
    while len(body) < clen:
        chunk = sock.recv(min(8192, clen - len(body)))
        if not chunk:
            raise ConnectionError(f"closed early {len(body)}/{clen}")
        body += chunk
    extra = len(body) - clen          # ka 模式下可能混入下一条响应头，剥掉存回？简化：禁用 pipeline，不会有 extra
    return body


def worker(mode, host, port, path, nreq, warmup, out_lat, out_conn,
           tid, warmed_ev, start_ev):
    req_tpl = (f"GET {path} HTTP/1.1\r\nHost: bench{tid}\r\n"
               f"User-Agent: ch20-bench\r\nAccept: */*\r\n"
               f"{'' if mode == 'ka' else 'Connection: close\r\n'}\r\n").encode()
    sock = None
    if mode == "ka":
        sock = socket.create_connection((host, port), timeout=10)

    def one(sock_or_new):
        """执行一次请求；noka 模式每次新建连接。"""
        if mode == "noka":
            t_c0 = time.perf_counter()
            s = socket.create_connection((host, port), timeout=10)
            out_conn.append((time.perf_counter() - t_c0) * 1000)
        else:
            s = sock_or_new
        try:
            t0 = time.perf_counter()
            s.sendall(req_tpl)
            body = read_response(s)
            dt = (time.perf_counter() - t0) * 1000
            return dt, len(body)
        finally:
            if mode == "noka":
                s.close()

    # 预热：不计入统计，把 ARP/首次建连/SLIRP 冷路径抖出测量窗
    for _ in range(max(warmup, 0)):
        if mode == "ka" and sock is None:
            break
        try:
            one(sock)
        except Exception:
            pass
    warmed_ev.set()
    start_ev.wait()

    for _ in range(nreq):
        dt, _ = one(sock)
        out_lat.append(dt)


def pct(sorted_vals, p):
    if not sorted_vals:
        return float("nan")
    idx = min(len(sorted_vals) - 1, int(len(sorted_vals) * p / 100))
    return sorted_vals[idx]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8024)
    ap.add_argument("--path", default="/small")
    ap.add_argument("--mode", choices=["ka", "noka"], required=True)
    ap.add_argument("--workers", type=int, default=4)
    ap.add_argument("--count", type=int, default=300)
    args = ap.parse_args()

    import threading
    lat, conn = [], []
    threads = []
    base = args.count // args.workers
    rem = args.count % args.workers
    warmed_evs = [threading.Event() for _ in range(args.workers)]
    start_ev = threading.Event()

    for w in range(args.workers):
        n = base + (1 if w < rem else 0)
        th = threading.Thread(target=lambda n=n, w=w, ev=warmed_evs[w]:
                              worker(args.mode, args.host, args.port, args.path,
                                     n, 10, lat, conn, w, ev, start_ev))
        th.start()
        threads.append(th)

    # 所有 worker 完成预热（建连/ARP/冷路径）后统一开表，保证 ka 与
    # noka 的测量窗口径一致；计时覆盖全部正式请求直到最后一个线程退出
    for ev in warmed_evs:
        ev.wait(timeout=30)
    t0 = time.perf_counter()
    start_ev.set()
    for th in threads:
        th.join()
    elapsed = time.perf_counter() - t0

    ls = sorted(lat)
    cs = sorted(conn)
    ok = len(lat)
    summary = {
        "mode": args.mode, "path": args.path, "workers": args.workers,
        "ok": ok, "fail": args.count - ok,
        "elapsed_s": round(elapsed, 3),
        "qps": round(ok / elapsed, 1),
        "avg_ms": round(sum(ls) / ok, 3),
        "p50_ms": round(pct(ls, 50), 3),
        "p90_ms": round(pct(ls, 90), 3),
        "p99_ms": round(pct(ls, 99), 3),
        "max_ms": round(ls[-1], 3) if ls else None,
        "conn_avg_ms": round(sum(cs) / len(cs), 3) if cs else None,
    }
    print(json.dumps(summary))
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
