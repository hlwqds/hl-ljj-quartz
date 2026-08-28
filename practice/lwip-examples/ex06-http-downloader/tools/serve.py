#!/usr/bin/env python3
# ex06 http-downloader 宿主服务端：确定性伪随机 payload 的教学 HTTP 服务器。
#
# 路径语义（guest 端 main.c 的时刻表一一对应）：
#   /good.bin      满血下载：Content-Length + X-Demo-Fletcher32，流式发满 size 字节
#   /short.bin     错误分支：头里承诺 Content-Length=size，实际只发 size//4 就带
#                  SO_LINGER=0 强断（模拟服务端中途死掉，guest 应报 TRUNCATED）
#   /nolen.bin     错误分支：无 Content-Length 头（EOF 定界），保留校验和头供对账，
#                  guest 应回报 OK_NO_LEN
#   /blackhole.bin 附赠场景：响应头+64KiB 后永久沉默，逼 guest 的 SO_RCVTIMEO 救场
#
# 内容生成：random.Random(seed) 逐块 randbytes；相同 (seed,size) 每次产出字节级
# 相同的流，多轮下载可做 digest 对账。payload 长度恒为 4 的倍数，与 guest 端
# Fletcher-32 流式实现按 little-endian u16 分字保持一致。
#
# 用法：
#   python3 tools/serve.py                    # 默认 127.0.0.1:8250, 5MiB, seed=20260826
#   python3 tools/serve.py --size 1048576     # 自定义大小（必须是 4 的倍数）
#
# 注意：默认不改端口。ex06 号段 8250-8259 中的 8257 特意**不监听**——guest 的
# closed-port 探针需要打到"无人应答"的槽位（README 附录演示 iptables 黑洞注入时
# 也用这个槽位做 connect-timeout）。

import argparse
import random
import socket
import struct
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def gen_bytes(size: int, seed: int) -> bytes:
    """确定性伪随机流：同一 (seed,size) 永远得到同一份字节。"""
    rng = random.Random(seed)
    out = bytearray()
    left = size
    while left:
        n = min(64 * 1024, left)
        out += rng.randbytes(n)
        left -= n
    return bytes(out)


def fletcher32(data: bytes) -> int:
    """与 zlib fletcher32 同算法，按 little-endian u16 分字累加。
    与 guest 端 C 实现同序同批长（359 字防溢出折叠），结果逐位可比。"""
    s1, s2 = 0xFFFF, 0xFFFF
    n = len(data) // 2
    words = struct.unpack_from("<%dH" % n, data, 0)
    i = 0
    while i < n:
        blk = min(359, n - i)
        for k in range(blk):
            s1 += words[i + k]
            s2 += s1
        s1 = (s1 & 0xFFFF) + (s1 >> 16)
        s2 = (s2 & 0xFFFF) + (s2 >> 16)
        i += blk
    s1 = (s1 & 0xFFFF) + (s1 >> 16)
    s2 = (s2 & 0xFFFF) + (s2 >> 16)
    return ((s2 << 16) | s1) & 0xFFFFFFFF


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"  # EOF 定界语义，教学从简
    server_version = "ex06-serve/1.0"

    def log_message(self, fmt, *args):  # 覆盖默认两行式日志，统一单行可 grep
        sys.stderr.write("[srv] %s %s\n" % (self.address_string(), fmt % args))

    def _headers(self, length):
        # 始终带上 X-Demo-Fletcher32：nolen 路径 guest 端就靠它对账
        S = self.server
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("X-Demo-Payload", "size=%d seed=%d ver=1" % (S.size, S.seed))
        self.send_header("X-Demo-Fletcher32", "%08x" % S.f32_full)
        if length is not None:
            self.send_header("Content-Length", str(length))
        else:
            self.send_header("Connection", "close")
        self.end_headers()

    def do_GET(self):
        S = self.server
        t0 = time.time()
        p = self.path.split("?", 1)[0]

        if p == "/good.bin":
            self._headers(S.size)
            self.wfile.write(S.full)
            self._audit("sent full", S.size, t0, S.f32_full)

        elif p == "/short.bin":
            quarter = max(4, S.size // 4)
            self._headers(S.size)  # 承诺全长——谎报正是故障的起点
            try:
                self.connection.setsockopt(
                    socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
            except OSError:
                pass
            self.wfile.write(S.full[:quarter])
            self.wfile.flush()
            self._audit("promised %d sent %d then ABORT(linger=0)" % (S.size, quarter),
                        quarter, t0, fletcher32(S.full[:quarter]))

        elif p == "/nolen.bin":
            self._headers(None)  # 不给 Content-Length（EOF 定界）；校验和头保留供 guest 对账
            self.wfile.write(S.full)
            self._audit("sent full WITHOUT Content-Length", S.size, t0, S.f32_full)

        elif p == "/blackhole.bin":
            self._headers(S.size)
            head = S.full[: 64 * 1024]
            self.wfile.write(head)
            self.wfile.flush()
            sys.stderr.write("[srv] %s /blackhole.bin head=%dB -> SILENT forever\n"
                             % (self.address_string(), len(head)))
            time.sleep(3600)  # daemon 线程，进程退出即销毁

        else:
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            self.log_message("%s -> 404", p)

    def _audit(self, note, sent, t0, f32):
        dur_ms = (time.time() - t0) * 1000
        sys.stderr.write("[srv] %s %s: %s fletch=%08x %.0fms\n"
                         % (self.address_string(), self.path, note, f32, dur_ms))


def main():
    ap = argparse.ArgumentParser(description="ex06 deterministic-content HTTP server")
    ap.add_argument("--host", default="127.0.0.1")  # SLIRP 只会落到宿主 loopback 同端口
    ap.add_argument("--port", type=int, default=8250)
    ap.add_argument("--size", type=int, default=5 * 1024 * 1024,
                    help="payload 字节数，必须是 4 的倍数（Fletcher 分字对齐）")
    ap.add_argument("--seed", type=int, default=20260826)
    args = ap.parse_args()

    assert args.size % 4 == 0 and args.size > 0, "--size 必须是 4 的正倍数"

    httpd = ThreadingHTTPServer((args.host, args.port), Handler)
    httpd.daemon_threads = True
    httpd.size = args.size
    httpd.seed = args.seed
    httpd.full = gen_bytes(args.size, args.seed)
    httpd.f32_full = fletcher32(httpd.full)

    print("ex06-serve listening on %s:%d size=%d seed=%d fletcher32=%08x"
          % (args.host, args.port, args.size, args.seed, httpd.f32_full), flush=True)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nex06-serve bye", flush=True)


if __name__ == "__main__":
    main()
