#!/usr/bin/env python3
"""ex13 宿主端命令客户端（单文件、纯 stdlib）。

经 SLIRP hostfwd 连接 guest 8300 的入向命令面：宿主机连 localhost:8300 即可。

协议（每条命令一行，响应一行，以 \\n 分帧）：
    PING          -> PONG
    ECHO <data>   -> <data> 原样返回
    STATS         -> 单行 JSON（lwip_stats TCP 段 + heap + uptime）
    TIME          -> up_ms=... up_s=...
    其他          -> ERR unknown

用法：
  python3 tools/hostlink.py                       # 交互式 REPL
  python3 tools/hostlink.py -c PING -c "ECHO hi" -c STATS -c TIME -c FOO
  echo -e 'PING\\nTIME' | python3 tools/hostlink.py   # 管道批量模式
  python3 tools/hostlink.py --oversize 700            # 命令超长截断保护演示
  python3 tools/hostlink.py --rst-after-ping          # 中途 RST 掐线演示

所有输入输出行都带墙钟时间戳，与 guest run.log 的 EX13- 标记对齐，可以拼出
"出向心跳 ACK 的同一时间窗内命令仍即时应答"的双向并发时间线。
"""

import argparse
import socket
import sys
import time


def stamp() -> str:
    t = time.time()
    return f"{time.strftime('%H:%M:%S')}.{int(t * 1000) % 1000:03d}"


def out(msg: str) -> None:
    print(f"[{stamp()}] {msg}", flush=True)


class HostLink:
    def __init__(self, host: str, port: int, connect_timeout: float,
                 reply_timeout: float):
        self.sock = socket.create_connection((host, port),
                                             timeout=connect_timeout)
        self.reply_timeout = reply_timeout
        self.sock.settimeout(reply_timeout)
        self.rxbuf = b""
        self.sent = self.replied = self.lost = 0

    def exchange(self, cmd: str) -> bool:
        """发送一行并等待一行完整响应；返回是否收到。"""
        wire = cmd.rstrip("\n") + "\n"
        self.sent += 1
        out(f">> {cmd}")
        t0 = time.perf_counter()
        try:
            self.sock.sendall(wire.encode())
        except OSError as e:
            self.lost += 1
            out(f"<x send failed errno={e.errno} ({e})")
            return False
        # 按 \n 取一行；STATS JSON 很长也不怕
        while b"\n" not in self.rxbuf:
            try:
                chunk = self.sock.recv(4096)
            except socket.timeout:
                self.lost += 1
                out(f"<x reply timeout after {self.reply_timeout}s "
                    f"(sent {cmd!r})")
                return False
            except OSError as e:
                self.lost += 1
                out(f"<x recv failed errno={e.errno} ({e}) -- peer reset?")
                return False
            if not chunk:
                self.lost += 1
                out("<| connection closed by peer (FIN), no reply pending")
                return False
            self.rxbuf += chunk
        line, self.rxbuf = self.rxbuf.split(b"\n", 1)
        dt = (time.perf_counter() - t0) * 1000
        text = line.decode(errors="replace").rstrip("\r")
        show = text if len(text) <= 160 else text[:160] + f"...({len(text)}B)"
        out(f"<< {show}   ({dt:.1f} ms)")
        self.replied += 1
        return True

    def close(self) -> None:
        try:
            self.sock.close()
        except OSError:
            pass


def run_oversize(hl: HostLink, size: int) -> None:
    payload = "X" * size
    note = f"ECHO {payload}"
    exp = min(size, 255)  # CMD_LINE_MAX-1：guest 侧行缓冲上限（固件常量）
    out(f"# oversize probe: sending ECHO with {size}B data, "
        f"expect truncated echo of ~{exp}B + EX13TRUNC marker in run.log")
    hl.exchange(note)


def run_rst_after_ping(hl: HostLink) -> None:
    import struct
    out("# rst scenario: PING/PONG then SO_LINGER(1,0)+close to force RST")
    ok = hl.exchange("PING")
    if not ok:
        return
    hl.sock.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER,
                       struct.pack("ii", 1, 0))  # on=1, linger=0 -> RST
    hl.close()
    out("# RST sent; expect EX13CLOSE reason=ERR errno=104 in run.log")


def main() -> int:
    ap = argparse.ArgumentParser(description="ex13 host-side command client")
    ap.add_argument("--host", default="127.0.0.1",
                    help="guest 的 hostfwd 入口（默认 127.0.0.1）")
    ap.add_argument("--port", type=int, default=8300)
    ap.add_argument("--connect-timeout", type=float, default=3.0)
    ap.add_argument("--reply-timeout", type=float, default=5.0)
    ap.add_argument("-c", "--cmd", action="append", default=[],
                    help="批量执行一条命令（可重复）；不给则进入交互/管道模式")
    ap.add_argument("--oversize", type=int, metavar="N",
                    help="发送超长 ECHO 行演示截断保护后退出")
    ap.add_argument("--rst-after-ping", action="store_true",
                    help="PING 一发后用 SO_LINGER(1,0)+close 发 RST 掐线")
    args = ap.parse_args()

    try:
        hl = HostLink(args.host, args.port, args.connect_timeout,
                      args.reply_timeout)
    except OSError as e:
        out(f"!! connect {args.host}:{args.port} failed errno={e.errno} ({e})")
        out("   检查 QEMU 是否带 hostfwd=tcp::8300-:8300 且已打出 $$$ EX13READY")
        return 2
    out(f"## connected guest:{args.port} reply_timeout={args.reply_timeout}s")

    # 场景开关：只跑演示场景就不进 REPL（stdin 非 tty 或显式给了 -c 除外）
    commands = list(args.cmd)  # 此前误写为裸引用未定义变量 commands，批量(-c)/管道模式一进来就 NameError
    did_scenario = args.oversize is not None or args.rst_after_ping
    if args.oversize is not None:
        run_oversize(hl, args.oversize)
    if args.rst_after_ping:
        run_rst_after_ping(hl)

    interactive_stdin = sys.stdin.isatty()
    if not commands and not interactive_stdin:
        commands = [ln.strip() for ln in sys.stdin if ln.strip()]

    if commands:
        for c in commands:
            hl.exchange(c)
    elif not did_scenario:
        out("REPL ready -- type a command line, '.quit' to exit, "
            "'.help' for the protocol")
        while True:
            try:
                line = input("hlk> ").strip()
            except (EOFError, KeyboardInterrupt):
                break
            if line in (".quit", ".q", "exit"):
                break
            if line == ".help":
                print("protocol: PING | ECHO <data> | STATS | TIME | other->"
                      "ERR unknown ; local: .help .quit", flush=True)
                continue
            if line:
                hl.exchange(line)

    wall_ok = hl.lost == 0 and hl.replied == hl.sent
    print(f"HLK-SUMMARY sent={hl.sent} replied={hl.replied} lost={hl.lost} "
          f"result={'OK' if wall_ok or hl.sent == 0 else 'PARTIAL'}",
          flush=True)
    hl.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
