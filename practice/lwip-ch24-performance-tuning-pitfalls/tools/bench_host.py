#!/usr/bin/env python3
"""ch24 主机端测量驱动。

子命令：
  thrx          主机 -> guest 灌流（经 hostfwd 数据口），guest 为 sink，
                发完 shutdown(WR) 等 guest 回 'K'，计时含流控全程。
  thtx          guest -> 主机 泵流，主机读至 EOF 计字节。
  http          对 HTTP 口（hostfwd）顺序 GET n 次，输出时延分布与失败分类。
  ctrl          向控制口发一条命令并回收应答（idle 0.5s 判定结束）。
输出行以 RESULT/CTRL 开头，便于 grep 归档。
"""
import argparse
import socket
import statistics
import sys
import time


def recv_until_idle(sock, idle_s):
    sock.settimeout(idle_s)
    chunks = []
    t_end = time.time() + idle_s
    try:
        while True:
            b = sock.recv(4096)
            if not b:
                break
            chunks.append(b)
    except socket.timeout:
        pass
    return b"".join(chunks)


def cmd_ctrl(args):
    s = socket.create_connection((args.host, args.ctrl_port), timeout=args.timeout)
    s.sendall(args.cmd.encode() + b"\n")
    out = recv_until_idle(s, 0.5)
    s.close()
    sys.stdout.write(out.decode(errors="replace"))
    if "\n" not in out.decode(errors="replace"):
        print()


def cmd_thrx(args):
    total = args.mb * 1000000
    payload = b"\x54" * 16384
    t0 = time.perf_counter()
    s = socket.create_connection((args.host, args.data_port), timeout=args.timeout)
    sent = 0
    while sent < total:
        n = s.send(payload)
        sent += n
    s.shutdown(socket.SHUT_WR)
    ack = s.recv(1)                      # guest 的 EOF 应答位
    dt = time.perf_counter() - t0
    s.close()
    print(f"RESULT kind=thrx mb={args.mb} ack={ack} secs={dt:.3f} "
          f"mbit={total*8/dt/1e6:.2f}")


def cmd_thtx(args):
    total = args.mb * 1000000
    t0 = time.perf_counter()
    s = socket.create_connection((args.host, args.data_port), timeout=args.timeout)
    got = 0
    eof = False
    try:
        while got < total:
            b = s.recv(262144)
            if not b:
                eof = True
                break
            got += len(b)
    except socket.timeout:
        pass
    dt = time.perf_counter() - t0
    s.close()
    print(f"RESULT kind=thtx want={total} got={got} secs={dt:.3f} "
          f"mbit={got*8/dt/1e6:.2f} clean_eof={'y' if eof else 'n'}")


def cmd_http(args):
    req = b"GET / HTTP/1.0\r\nHost: ch24\r\n\r\n"
    lats = []
    fail_timeout = fail_other = 0
    other_errs = []
    for i in range(args.n):
        t0 = time.perf_counter()
        try:
            s = socket.create_connection((args.host, args.http_port),
                                         timeout=args.timeout)
            s.sendall(req)
            buf = b""
            while True:
                b = s.recv(4096)
                if not b:
                    break
                buf += b
            dt = time.perf_counter() - t0
            ok = buf.startswith(b"HTTP/1.1 200")
            if ok:
                lats.append(dt * 1000)
            else:
                fail_other += 1
                other_errs.append(buf[:60])
            s.close()
        except socket.timeout:
            fail_timeout += 1
        except OSError as e:
            fail_other += 1
            other_errs.append(repr(e).encode())
    xs = sorted(lats)

    def pct(p):
        if not xs:
            return float("nan")
        k = (len(xs) - 1) * p / 100
        f = int(k)
        c = min(f + 1, len(xs) - 1)
        return xs[f] + (xs[c] - xs[f]) * (k - f)

    print(f"RESULT kind=http n={args.n} ok={len(xs)} timeout={fail_timeout} "
          f"other_fail={fail_other}")
    if other_errs[:3]:
        for e in other_errs[:3]:
            print(f"RESULT kind=http err_sample={e!r}")
    if xs:
        print(f"RESULT kind=http lat_ms min={xs[0]:.1f} avg={statistics.mean(xs):.1f} "
              f"p50={pct(50):.1f} p90={pct(90):.1f} p99={pct(99):.1f} max={xs[-1]:.1f}")


COMMON = {"--host": "127.0.0.1", "--data-port": 8028,
          "--ctrl-port": 8029, "--http-port": 8030}


def add_common(sp):
    for k, v in COMMON.items():
        sp.add_argument(k, default=v if not k.startswith("--d")
                        else int(v) if k.endswith("port") and isinstance(v, int) else v)
    sp.add_argument("--mb", type=int, default=4)
    sp.add_argument("--n", type=int, default=30)
    sp.add_argument("--timeout", type=float, default=6.0)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--data-port", type=int, default=8028)
    ap.add_argument("--ctrl-port", type=int, default=8029)
    ap.add_argument("--http-port", type=int, default=8030)
    ap.add_argument("--mb", type=int, default=4)
    ap.add_argument("--n", type=int, default=30)
    ap.add_argument("--timeout", type=float, default=6.0)
    sub = ap.add_subparsers(dest="which", required=True)
    _sp = sub.add_parser("thrx"); add_common(_sp); _sp.set_defaults(func=cmd_thrx)
    _sp = sub.add_parser("thtx"); add_common(_sp); _sp.set_defaults(func=cmd_thtx)
    _sp = sub.add_parser("http"); add_common(_sp); _sp.set_defaults(func=cmd_http)
    sp = sub.add_parser("ctrl")
    sp.add_argument("--cmd", required=True)
    sp.set_defaults(func=cmd_ctrl)
    args = ap.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
