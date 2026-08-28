#!/usr/bin/env python3
"""ex03 宿主端回显服务器（单文件、纯 stdlib）。

guest 通过 SLIRP 外连宿主机 loopback：guest 侧 10.0.2.2:P 等价于宿主机的
127.0.0.1:P（SLIRP 边界事实，CONVENTIONS C-12），因此本脚本不需要任何 hostfwd。

三种模式对应 ex03 固件的三个教学场景：

  echo   (8220) 正常回显。逐条消息原样返回；双端 Fletcher-16 digest 对账。
  silent (8221) accept 之后一言不发也不读——供固件演示 SO_RCVTIMEO -> EAGAIN。
  reset  (8222) 读完第一条消息（256B）后用 SO_LINGER(1,0)+close 发 RST 掐线
                ——供固件演示中途断开 -> ECONNRESET。

用法：
  python3 tools/listener.py --all                 # 一口气起全三模式（推荐）
  python3 tools/listener.py --mode echo --port 8220
  python3 tools/listener.py --mode silent --port 8221
  python3 tools/listener.py --mode reset --port 8222

日志行以 LST- 前缀打出（与 guest 侧 EX03- 标记呼应），全部 flush 方便 tee。
"""

import argparse
import socket
import struct
import sys
import threading
import time

MODE_PORTS = {"echo": 8220, "silent": 8221, "reset": 8222}
FIRST_MSG_LEN = 256  # 与固件 MSG_LEN 保持一致


def fletcher16(data: bytes, s1: int, s2: int):
    """与 guest 端 struct fletcher 同一算法（mod 255）。"""
    for b in data:
        s1 = (s1 + b) % 255
        s2 = (s2 + s1) % 255
    return s1, s2


def log(msg: str):
    print(f"{msg}", flush=True)


# ----------------------------------------------------------------------
# 三种模式的服务循环
# ----------------------------------------------------------------------


def serve_echo(conn: socket.socket, addr, idx: int):
    """正常路径：收多少回多少，记账 rx/tx 两套 digest 供跨边界对账。"""
    conn.settimeout(30)
    rx = tx = 0
    s1r = s2r = s1t = s2t = 0
    try:
        while True:
            chunk = conn.recv(4096)
            if not chunk:
                break
            rx += len(chunk)
            s1r, s2r = fletcher16(chunk, s1r, s2r)
            conn.sendall(chunk)
            tx += len(chunk)
            s1t, s2t = fletcher16(chunk, s1t, s2t)
    except socket.timeout:
        log(f"LST-ECHO conn#{idx} timeout-idle rx={rx}")
    finally:
        conn.close()
    match = rx == tx and (s1r, s2r) == (s1t, s2t)
    log(f"LST-ECHO-DONE conn#{idx} addr={addr[0]}:{addr[1]} rx_bytes={rx} "
        f"tx_bytes={tx} digest_rx={(s2r << 8) | s1r:04x} "
        f"digest_tx={(s2t << 8) | s1t:04x} match={'YES' if match else 'NO'}")


def serve_silent(conn: socket.socket, addr, idx: int):
    """超时演示对端：accept 后保持沉默；数据到达只吞不回。

    连接保持到对端主动关闭（收到 FIN 后 recv 返回 b''）或空闲超时。客户端随后
    的 recv 会一直阻塞到 SO_RCVTIMEO 到期拿到 EAGAIN——这正是场景 B 想要的。
    """
    conn.settimeout(20)
    silent_for = 0
    while True:
        try:
            chunk = conn.recv(4096)
        except socket.timeout:
            break
        if not chunk:
            break
        silent_for += len(chunk)  # 只吞不回
    conn.close()
    log(f"LST-SILENT-DONE conn#{idx} addr={addr[0]}:{addr[1]} "
        f"swallowed_bytes={silent_for} (never replied)")


def serve_reset(conn: socket.socket, addr, idx: int):
    """RST 演示对端：把第一条消息读完证明应用层收到过数据，然后 RST 掐线。

    SO_LINGER {on,0} + close() 是 Linux 上制造 RST 的标准姿势：丢弃未发数据、
    直接发 RST 而不是 FIN，guest 的阻塞 recv 将得到 ECONNRESET。
    """
    conn.settimeout(5)
    total = 0
    s1 = s2 = 0
    why = "timeout"
    while total < FIRST_MSG_LEN:
        try:
            chunk = conn.recv(4096)
        except socket.timeout:
            break
        if not chunk:
            why = "peer-closed"
            break
        total += len(chunk)
        s1, s2 = fletcher16(chunk, s1, s2)
        if total >= FIRST_MSG_LEN:
            why = "first-message-consumed"
            break
    conn.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER,
                    struct.pack("ii", 1, 0))  # on=1, linger=0 -> RST
    conn.close()
    log(f"LST-RESET-DONE conn#{idx} addr={addr[0]}:{addr[1]} read_bytes={total} "
        f"digest_rx={(s2 << 8) | s1:04x} drop_reason={why} drop_mode=RST")


SERVERS = {"echo": serve_echo, "silent": serve_silent, "reset": serve_reset}


def listen_loop(mode: str, port: int):
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        srv.bind(("0.0.0.0", port))
        srv.listen(4)
    except OSError as e:
        log(f"LST-LISTEN mode={mode} port={port} FAILED errno={e.errno} ({e})")
        return
    log(f"$$$ LSTREADY mode={mode} port={port}")
    handler = SERVERS[mode]
    idx = 0
    while True:
        try:
            conn, addr = srv.accept()
        except KeyboardInterrupt:
            break
        idx += 1
        log(f"LST-{mode.upper()} conn#{idx} accepted from {addr[0]}:{addr[1]}")
        threading.Thread(target=handler, args=(conn, addr, idx),
                         daemon=True).start()
    srv.close()


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--mode", choices=list(MODE_PORTS), help="监听模式")
    ap.add_argument("--port", type=int, default=None,
                    help="覆盖该模式的默认端口")
    ap.add_argument("--all", action="store_true",
                    help=f"同时启动全三模式（默认端口 {MODE_PORTS}）")
    args = ap.parse_args()

    if not args.all and not args.mode:
        ap.error("需要 --mode <m> 或 --all")

    if args.all:
        for m, p in MODE_PORTS.items():
            threading.Thread(target=listen_loop, args=(m, p),
                             daemon=True).start()
        log("LST-ALL modes=echo:8220,silent:8221,reset:8222 waiting ...")
        try:
            while True:
                time.sleep(3600)
        except KeyboardInterrupt:
            log("LST-BYE interrupted; exiting")
            return 0
    listen_loop(args.mode, args.port or MODE_PORTS[args.mode])
    return 0


if __name__ == "__main__":
    sys.exit(main())
