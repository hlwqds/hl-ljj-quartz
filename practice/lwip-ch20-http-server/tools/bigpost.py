#!/usr/bin/env python3
"""ch20 实验 C：大 POST 压力注入。

模式：
  cl-lie   Content-Length 骗大：声称 claim 字节，实际只以 rate B/s 滴流
           （或不发 body 静默挂住），观察 handler/finish-purge 卡在哪、
           recv_wait_timeout 到点后服务端如何收尾（FIN 时刻）。
  chunked  Transfer-Encoding: chunked 持续上传小 chunk，观察解析器边界行为。

用法：
  python3 tools/bigpost.py cl-lie --claim 104857600 --rate 1024 --seconds 12
  python3 tools/bigpost.py chunked --chunks-per-sec 5 --chunk-size 16 --seconds 10

期间可另开终端用 ch20ctl.py st 观察服务端堆与 busy_post。
"""
import argparse, socket, sys, time


def send_headers(s, hdrs):
    s.sendall(("\r\n".join(hdrs) + "\r\n\r\n").encode())


def read_some(s, wait_s):
    s.settimeout(wait_s)
    try:
        return s.recv(256)
    except socket.timeout:
        return None


def mode_cl_lie(args):
    t0 = time.perf_counter()
    s = socket.create_connection((args.host, args.port), timeout=15)
    send_headers(s, [
        f"POST {args.uri} HTTP/1.1",
        f"Host: ch20-post",
        f"Content-Type: application/octet-stream",
        f"Content-Length: {args.claim}",
    ])
    print(f"[{time.perf_counter()-t0:6.2f}s] headers sent "
          f"(POST {args.uri} Content-Length: {args.claim}, "
          f"real rate {args.rate}B/s)", flush=True)

    sent = 0
    next_beat = time.perf_counter()
    ended = None
    while time.perf_counter() - t0 < args.seconds:
        if args.rate > 0:
            if time.perf_counter() >= next_beat:
                try:
                    s.sendall(b"P" * args.rate)
                    sent += args.rate
                    next_beat += 1.0
                except OSError as e:
                    print(f"[{time.perf_counter()-t0:6.2f}s] send fail: {e}",
                          flush=True)
                    break
        else:
            pass  # 纯静默：一个字节都不发
    stop_s = time.perf_counter() - t0

    # 收尾阶段：停止发送，保持连接，等服务端动作（408/FIN/...）
    print(f"[{stop_s:6.2f}s] stopped sending (total body sent={sent}B); "
          f"waiting for server reaction ...", flush=True)
    while True:
        data = read_some(s, 1.0)
        now = time.perf_counter() - t0
        if data == b"":
            print(f"[{now:6.2f}s] FIN from server (session closed)", flush=True)
            break
        if data:
            print(f"[{now:6.2f}s] server says: {data[:80]!r}", flush=True)
            continue
        if now - stop_s > args.grace + 8:      # 超过宽限还没动静就收摊
            print(f"[{now:6.2f}s] still no answer after {args.grace+8:.0f}s, giving up",
                  flush=True)
            break
    s.close()


def mode_chunked(args):
    t0 = time.perf_counter()
    s = socket.create_connection((args.host, args.port), timeout=15)
    send_headers(s, [
        "POST /echo HTTP/1.1",
        "Host: ch20-chunked",
        "Transfer-Encoding: chunked",
    ])
    print("headers sent (Transfer-Encoding: chunked)", flush=True)
    interval = 1.0 / max(args.chunks_per_sec, 0.001)
    n = 0
    while time.perf_counter() - t0 < args.seconds:
        time.sleep(interval)
        body = b"C" * args.chunk_size
        try:
            s.sendall(f"{args.chunk_size:x}\r\n".encode() + body + b"\r\n")
            n += 1
        except OSError as e:
            print(f"[{time.perf_counter()-t0:6.2f}s] send fail: {e}", flush=True)
            break
    print(f"[{time.perf_counter()-t0:6.2f}s] sent {n} chunks; waiting ...",
          flush=True)
    deadline = time.perf_counter() + args.grace
    while time.perf_counter() < deadline:
        data = read_some(s, 1.0)
        now = time.perf_counter() - t0
        if data == b"":
            print(f"[{now:6.2f}s] FIN from server", flush=True)
            break
        if data:
            print(f"[{now:6.2f}s] server says: {data[:100]!r}", flush=True)
    s.close()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8024)
    ap.add_argument("--grace", type=float, default=4.0)
    sub = ap.add_subparsers(dest="mode", required=True)

    p1 = sub.add_parser("cl-lie")
    p1.add_argument("--claim", type=int, default=104857600)
    p1.add_argument("--rate", type=int, default=1024,
                    help="B/s；0 = 发完头就静默挂住")
    p1.add_argument("--seconds", type=float, default=12)
    p1.add_argument("--uri", default="/echo",
                    help="/echo=handler 消费路径；/small=无 POST handler，"
                         "触发组件对未消费 body 的 purge 路径")

    p2 = sub.add_parser("chunked")
    p2.add_argument("--chunks-per-sec", type=float, default=5)
    p2.add_argument("--chunk-size", type=int, default=16)
    p2.add_argument("--seconds", type=float, default=10)

    args = ap.parse_args()
    if args.mode == "cl-lie":
        mode_cl_lie(args)
    else:
        mode_chunked(args)


if __name__ == "__main__":
    main()
