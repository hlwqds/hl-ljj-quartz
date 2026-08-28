#!/usr/bin/env python3
"""ch18 以太网对照实验的宿主机测量基准工具。

用法:
  ./bench.py rtt       # 300 次 64B echo 事务，输出 RTT 分布 (p50/p90/p95/p99/max)
  ./bench.py bulk      # 上传 4 MiB（16KB 块回显校验），输出有效吞吐
  ./bench.py lossy-on  # 发控制字让 guest 换上 10% 丢帧 linkoutput
  ./bench.py lossy-off # 摘掉包装器并让 guest 打印 pass/drop 计数

口径说明见文章实验节。
"""
import socket
import statistics
import sys
import time

HOST = "127.0.0.1"
PORT = 8050


def connect(timeout=5.0):
    s = socket.create_connection((HOST, PORT), timeout=timeout)
    s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    return s


def ctl(cmd: bytes):
    s = connect(10.0)
    s.sendall(cmd)
    resp = s.recv(16)
    print(f"ctl {cmd!r} -> {resp!r}")
    s.close()


def transact(s, payload):
    t0 = time.perf_counter_ns()
    s.sendall(payload)
    got = 0
    while got < len(payload):
        b = s.recv(len(payload) - got)
        if not b:
            raise ConnectionError("peer closed")
        got += len(b)
    return (time.perf_counter_ns() - t0) / 1000.0  # us


def rtt_suite(n=300, tx_timeout_s=15.0):
    payload = b"x" * 64
    samples_us = []
    fails = 0
    s = None
    for _ in range(n):
        try:
            if s is None:
                s = connect()
            s.settimeout(tx_timeout_s)
            samples_us.append(transact(s, payload))
        except (socket.timeout, OSError) as e:
            fails += 1
            samples_us.append(None)
            if s is not None:
                s.close()
                s = None
    if s is not None:
        s.close()

    ok_ms = sorted(x / 1000.0 for x in samples_us if x is not None)

    def pct(p):
        return ok_ms[min(len(ok_ms) - 1, int(round(p * (len(ok_ms) - 1))))]

    print("== RTT suite ==")
    print(f"samples_total={n} completed={len(ok_ms)} stalled_failed={fails}")
    if ok_ms:
        print(f"rtt_p50={pct(0.50):.2f}ms rtt_p90={pct(0.90):.2f}ms "
              f"rtt_p95={pct(0.95):.2f}ms rtt_p99={pct(0.99):.2f}ms "
              f"rtt_max={ok_ms[-1]:.2f}ms rtt_mean={statistics.mean(ok_ms):.2f}ms")


def bulk_suite(total=4 * 1024 * 1024, chunk=16384, deadline=60.0, inflight_chunks=8):
    payload = bytes(range(256)) * (chunk // 256)
    s = connect(10.0)
    sent = echoed = 0
    stalled = False
    t0 = time.perf_counter()
    while echoed < total:
        try:
            remain = max(0.5, deadline - (time.perf_counter() - t0))
            s.settimeout(min(20.0, remain))
            # 维持窗口：最多在途 inflight_chunks*chunk 字节
            while sent < total and sent - echoed < inflight_chunks * chunk:
                n = s.send(payload[:min(chunk, total - sent)])
                sent += n
            while echoed < min(sent, total):
                b = s.recv(min(65536, min(sent, total) - echoed))
                if not b:
                    raise ConnectionError("peer closed")
                echoed += len(b)
            if time.perf_counter() - t0 > deadline:
                break
        except (socket.timeout, ConnectionError, OSError):
            stalled = True
            break
    el = time.perf_counter() - t0
    s.close()
    mbit = echoed * 8 / el / 1e6
    print("== BULK suite ==")
    print(f"upload_target={total} sent={sent} verified_echo={echoed} elapsed={el:.2f}s "
          f"goodput_verified={mbit:.2f}Mbit/s partial={echoed < total}")


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "rtt":
        rtt_suite()
    elif cmd == "bulk":
        bulk_suite()
    elif cmd == "lossy-on":
        ctl(b"CTL:LOSSY_ON")
    elif cmd == "lossy-off":
        ctl(b"CTL:LOSSY_OFF")
    else:
        print(__doc__)
        sys.exit(1)
