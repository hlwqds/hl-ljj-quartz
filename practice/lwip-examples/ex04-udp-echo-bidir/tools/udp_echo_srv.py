#!/usr/bin/env python3
"""ex04 宿主侧 UDP 回声器（出向路径 B 的对端）。

guest 主动 sendto 10.0.2.2:8231（SLIRP 把它落到宿主 loopback 同端口 8231），
本工具原样回显，从而给 guest 出向路径一个「真实对端往返证据」。
与出向路径 A（guest → 10.0.2.2:8230 打 QEMU 自己的 hostfwd 折返回环）互补：
路径 B 走的是一台独立的宿主进程，证明 guest 的出向 UDP 能到达宿主任意监听者。

用法：
    python3 tools/udp_echo_srv.py --port 8231
Ctrl-C 停止时打印会话汇总。payload 不做修改、逐字节回显；
若头 9 字节恰好是 EX04 协议头则顺带解析 seq/tag 便于日志对账。
"""

import argparse
import signal
import socket
import sys


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--bind", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8231)
    args = ap.parse_args()

    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind((args.bind, args.port))
    print(f"EX04-SRV listening on udp://{args.bind}:{args.port}", flush=True)

    echoed = 0
    running = [True]

    def stop(_sig, _frm):
        running[0] = False

    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)

    s.settimeout(0.5)
    while running[0]:
        try:
            data, src = s.recvfrom(65535)
        except socket.timeout:
            continue
        s.sendto(data, src)
        echoed += 1
        note = ""
        if len(data) >= 9 and data[:4] == b"EX04":
            tag = chr(data[4])
            seq = int.from_bytes(data[5:9], "big")
            note = f" magic=EX04 tag={tag} seq={seq}"
        print(f"EX04-SRV echo #{echoed} from={src[0]}:{src[1]} len={len(data)}{note}",
              flush=True)

    print(f"EX04-SRV bye echoed={echoed}", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
