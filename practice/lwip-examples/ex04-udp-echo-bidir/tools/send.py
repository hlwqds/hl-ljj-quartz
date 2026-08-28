#!/usr/bin/env python3
"""ex04 入向验证器：宿主 -> guest 的 UDP echo 往返证据采集。

与固件 practice/lwip-examples/ex04-udp-echo-bidir/main/main.c 配合：
guest 在 :8230 bind 固定端口做 UDP echo server，QEMU 以
hostfwd=udp::8230-:8230 把宿主 127.0.0.1:8230 投递进 guest。

本工具对每个包：
    1. 构造 payload：magic "EX04" + tag 'H' + seq(u32 大端) + 确定性填充体；
    2. sendto 后等回显（--timeout-ms），超时记为丢包——这正是 UDP 下应用层
       感知丢包的唯一方式：协议栈不会告诉你任何事，只有你自己的定时器知道；
    3. 回显必须逐字节一致（强 digest 校验），错一字节即判 CORRUPT；
    4. 缺失序号可补发（--retries 轮）。

用法示例：
    python3 tools/send.py                          # 20 包默认验证
    python3 tools/send.py --count 300 --size 512 --interval-ms 0   # 突发（观测 SLIRP 尾巴丢包）

输出末行为机器可读汇总行（EX04-HOST-INBOUND ...），可直接 grep 断言。
"""

import argparse
import socket
import sys
import time

MAGIC = b"EX04"
TAG_HOST = b"H"


def make_payload(seq: int, size: int) -> bytes:
    """确定性填充体：同一 (seq,size) 恒定，回显差异即可定位。"""
    body = bytes((j * 13 + seq * 7 + 11) % 251 for j in range(max(size - 9, 0)))
    return MAGIC + TAG_HOST + seq.to_bytes(4, "big") + body


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--host", default="127.0.0.1", help="宿主侧目标地址（hostfwd 入口）")
    ap.add_argument("--port", type=int, default=8230)
    ap.add_argument("--count", type=int, default=20, help="发送的数据报个数")
    ap.add_argument("--size", type=int, default=64, help="payload 总长（含 9B 头）")
    ap.add_argument("--interval-ms", type=float, default=25.0, help="发包间隔；0 = 尽快连发")
    ap.add_argument("--timeout-ms", type=float, default=2000.0, help="单包等待回显超时")
    ap.add_argument("--retries", type=int, default=1, help="缺失序号的补发轮数")
    args = ap.parse_args()

    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4 << 20)

    ok: set[int] = set()
    rtt_ms: dict[int, float] = {}
    corrupt: list[int] = []
    retried = 0
    attempts = 0
    dst = (args.host, args.port)

    def attempt(seq: int) -> bool:
        nonlocal attempts
        data = make_payload(seq, args.size)
        t0 = time.monotonic_ns()
        s.sendto(data, dst)
        attempts += 1
        try:
            s.settimeout(args.timeout_ms / 1000.0)
            rx, src = s.recvfrom(65535)
            el = (time.monotonic_ns() - t0) / 1e6
            if rx == data:
                rtt_ms[seq] = el
                print(f"EX04-IN seq={seq} len={len(rx)} from={src[0]}:{src[1]} "
                      f"rtt_ms={el:.2f} digest=OK", flush=True)
                return True
            corrupt.append(seq)
            print(f"EX04-IN seq={seq} digest=CORRUPT rx_len={len(rx)} want={len(data)}",
                  flush=True)
            return False
        except socket.timeout:
            print(f"EX04-IN seq={seq} TIMEOUT after {args.timeout_ms:.0f}ms "
                  f"(应用层感知：无回复即视为丢失)", flush=True)
            return False

    for rnd in range(args.retries + 1):
        if rnd > 0:
            missing = [i for i in range(args.count) if i not in ok]
            if not missing:
                break
            print(f"# 补发轮 {rnd}: missing={missing}", flush=True)
            retried += len(missing)
            for i in missing:
                if attempt(i):
                    ok.add(i)
            continue
        for i in range(args.count):
            if attempt(i):
                ok.add(i)
            if args.interval_ms > 0:
                time.sleep(args.interval_ms / 1000.0)

    missing = [i for i in range(args.count) if i not in ok]
    sent_pkts = args.count
    lost = len(missing)
    pct = 100.0 * lost / sent_pkts if sent_pkts else 0.0
    vals = sorted(rtt_ms.values())
    avg = sum(vals) / len(vals) if vals else float("nan")
    p95 = vals[int(len(vals) * 0.95)] if vals else float("nan")
    print(f"# 汇总 sent={sent_pkts} ok={len(ok)} retried={retried} "
          f"missing={missing} loss_pct={pct:.2f}", flush=True)
    print(f"EX04-HOST-INBOUND dst={args.host}:{args.port} size={args.size} "
          f"sent={sent_pkts} ok={len(ok)} missing={lost} corrupt={len(corrupt)} "
          f"attempts={attempts} loss_pct={pct:.2f} "
          f"rtt_avg_ms={avg:.2f} rtt_p95_ms={p95:.2f}", flush=True)
    return 0 if lost == 0 and not corrupt else 1


if __name__ == "__main__":
    sys.exit(main())
