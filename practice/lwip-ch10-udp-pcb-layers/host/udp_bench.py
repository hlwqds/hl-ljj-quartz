#!/usr/bin/env python3
"""
lwIP 深度解析（十）主机端压测器。

与 guest 端 practice/lwip-ch10-udp-pcb-layers/lab_main.c 的三个 echo 口配合：
    8010 raw / 8011 netconn / 8012 socket，控制口 8019。

子命令：
    lat    时延：顺序 ping-pong，每个包等回显后测 RTT。
    tpt    吞吐：窗口受限连发 + 缺失序号补发，报告好吞吐与应用层重试率。
    flood  定速灌包：不补发，测量回显比例（丢包观察）。
    slow   向控制口下发 slow:<ms>，把 netconn/socket 消费者调成慢消费模式。

payload 布局：magic 'C10!' + seq(u32 LE) + 填充字节。回显必须逐字节一致。
"""

import argparse
import socket
import struct
import sys
import time

MAGIC = b"C10!"


def make_payload(seq: int, size: int) -> bytes:
    return MAGIC + struct.pack("<I", seq) + b"x" * max(size - 8, 0)


def parse_payload(data: bytes):
    if len(data) < 8 or data[:4] != MAGIC:
        return None
    return struct.unpack("<I", data[4:8])[0]


def open_sock(port: int) -> socket.socket:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4 << 20)
    s.bind(("127.0.0.1", 0))
    dst = ("127.0.0.1", port)
    return s, dst


# --------------------------------------------------------------------------
def cmd_latency(args):
    s, dst = open_sock(args.port)
    payload = make_payload(0, args.size)
    for rnd in range(1, args.rounds + 1):
        rtts = []
        losses = 0
        for i in range(args.n):
            data = make_payload(i, args.size)
            t0 = time.monotonic_ns()
            s.sendto(data, dst)
            try:
                s.settimeout(2.0)
                rx, _ = s.recvfrom(4096)
                rtt = (time.monotonic_ns() - t0) / 1e3
                if rx == data:
                    rtts.append(rtt)
                else:
                    losses += 1
            except socket.timeout:
                losses += 1
        rtts.sort()
        avg = sum(rtts) / len(rtts) if rtts else float("nan")
        med = rtts[len(rtts) // 2] if rtts else float("nan")
        p95 = rtts[int(len(rtts) * 0.95)] if rtts else float("nan")
        mn = rtts[0] if rtts else float("nan")
        mx = rtts[-1] if rtts else float("nan")
        print(f"LAT label={args.label} port={args.port} size={args.size} "
              f"n={args.n} ok={len(rtts)} loss={losses} "
              f"avg_us={avg:.1f} med_us={med:.1f} min_us={mn:.1f} "
              f"max_us={mx:.1f} p95_us={p95:.1f}", flush=True)


# --------------------------------------------------------------------------
def cmd_throughput(args):
    s, dst = open_sock(args.port)
    deadline = time.monotonic() + args.deadline
    acked = set()
    retried = 0
    attempts = 0
    first_send = None
    window = []
    next_seq = 0
    last_recv = None

    def try_send():
        nonlocal next_seq, first_send, attempts
        while len(window) < args.window and next_seq < args.k:
            t = time.monotonic()
            if first_send is None:
                first_send = t
            s.sendto(make_payload(next_seq, args.size), dst)
            attempts += 1
            window.append((next_seq, t))
            next_seq += 1

    # 阶段一：窗口推进直到全部回显或超时
    while len(acked) < args.k and time.monotonic() < deadline:
        try_send()
        try:
            s.settimeout(0.05)
            data, _ = s.recvfrom(65535)
            q = parse_payload(data)
            if q is not None and q not in acked:
                acked.add(q)
                last_recv = time.monotonic()
                window = [(sq, t) for sq, t in window if sq != q]
        except socket.timeout:
            pass
        now = time.monotonic()
        stale = [e for e in window if now - e[1] > 0.5]
        if stale:
            # 任何滞留 >0.5s 的条目都值得补发（不必等满窗——尾部损失时窗会变浅）
            oldest = min(window, key=lambda e: e[1])
            s.sendto(make_payload(oldest[0], args.size), dst)
            attempts += 1
            retried += 1
            window.remove(oldest)
            window.append((oldest[0], now))

    # 阶段二：缺失序号集中补发（最多 N 轮），给 deadline 后留一小段宽限
    grace_end = deadline + 2.0
    for rnd_pass in range(args.retries):
        missing = [i for i in range(args.k) if i not in acked]
        if not missing or time.monotonic() > grace_end:
            break
        for i in missing:
            s.sendto(make_payload(i, args.size), dst)
            attempts += 1
            retried += 1
        s.settimeout(min(2.0, max(0.2, args.deadline - (time.monotonic() - deadline))))
        endwait = time.monotonic() + 1.0
        while time.monotonic() < endwait and len(acked) < args.k:
            try:
                data, _ = s.recvfrom(65535)
                q = parse_payload(data)
                if q is not None and q not in acked:
                    acked.add(q)
                    last_recv = time.monotonic()
            except socket.timeout:
                break

    total_ms = ((last_recv or first_send) - first_send) * 1e3 if first_send else 0
    mbit = args.k * args.size * 8 / (total_ms / 1e3) / 1e6 if total_ms > 0 else 0
    print(f"TPT label={args.label} port={args.port} size={args.size} k={args.k} "
          f"rx={len(acked)} missing={args.k - len(acked)} attempts={attempts} "
          f"resends={retried} ms={total_ms:.0f} mbit={mbit:.2f}", flush=True)


# --------------------------------------------------------------------------
def cmd_flood(args):
    s, dst = open_sock(args.port)
    interval = 1.0 / args.pps
    sent = 0
    t_end = time.monotonic() + args.dur
    while time.monotonic() < t_end:
        t_next = time.monotonic() + interval
        s.sendto(make_payload(sent, args.size), dst)
        sent += 1
        sleep_for = t_next - time.monotonic()
        if sleep_for > 0:
            time.sleep(sleep_for)

    # 排干在途回显
    rcvd = set()
    s.settimeout(1.0)
    endwait = time.monotonic() + 1.5
    while time.monotonic() < endwait:
        try:
            data, _ = s.recvfrom(65535)
            q = parse_payload(data)
            if q is not None:
                rcvd.add(q)
        except socket.timeout:
            pass
    lost = sent - len(rcvd)
    pct = 100.0 * lost / sent if sent else 0
    print(f"FLOOD label={args.label} port={args.port} size={args.size} pps={args.pps} "
          f"dur={args.dur} sent={sent} echoed_unique={len(rcvd)} "
          f"lost_or_pending={lost} loss_pct={pct:.2f}", flush=True)


# --------------------------------------------------------------------------
def cmd_slow(args):
    s, dst = open_sock(args.ctrl_port)
    msg = f"slow:{args.ms}".encode()
    s.sendto(msg, dst)
    s.settimeout(2.0)
    try:
        data, _ = s.recvfrom(1024)
        print(f"SLOW ctrl ms={args.ms} reply={data!r}", flush=True)
    except socket.timeout:
        print(f"SLOW ctrl ms={args.ms} NO-ACK", flush=True)


# --------------------------------------------------------------------------
def main():
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("lat")
    p.add_argument("--port", type=int, required=True)
    p.add_argument("--size", type=int, default=64)
    p.add_argument("--n", type=int, default=500)
    p.add_argument("--rounds", type=int, default=3)
    p.add_argument("--label", default="api")
    p.set_defaults(fn=cmd_latency)

    p = sub.add_parser("tpt")
    p.add_argument("--port", type=int, required=True)
    p.add_argument("--size", type=int, default=1200)
    p.add_argument("--k", type=int, default=2000)
    p.add_argument("--window", type=int, default=16)
    p.add_argument("--retries", type=int, default=3)
    p.add_argument("--deadline", type=float, default=60.0)
    p.add_argument("--label", default="api")
    p.set_defaults(fn=cmd_throughput)

    p = sub.add_parser("flood")
    p.add_argument("--port", type=int, required=True)
    p.add_argument("--pps", type=int, default=1000)
    p.add_argument("--dur", type=float, default=3.0)
    p.add_argument("--size", type=int, default=64)
    p.add_argument("--label", default="api")
    p.set_defaults(fn=cmd_flood)

    p = sub.add_parser("slow")
    p.add_argument("--ctrl-port", type=int, default=8019)
    p.add_argument("--ms", type=int, required=True)
    p.set_defaults(fn=cmd_slow)

    args = ap.parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()
