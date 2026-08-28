#!/usr/bin/env python3
"""ex11 TX 模式宿主接收器（sink）。

用法：
  python3 sink.py [--port 8290] [--conns N] [--quiet]

监听 TCP 端口，顺序接受 N 个连接（N<=0 表示无限）。每个连接读到底（guest 半关后
见 EOF），回一个字节 'K' 作为「已完整消费」应答位，然后打印一行摘要：
字节数、耗时、吞吐、Fletcher-16 校验值。多轮跑分时 conns 设为固件 ROUNDS 数，
全部收完后自动退出并打总账。

digest 算法与 guest 固件逐位一致：
  Fletcher-16（mod 255，同 ch6）；内容为 64 KiB 周期的 xorshift32 图样
  （seed=0x11c0ffee，每字节推进一次取高 8 位）——两端各自实现同一递推式，
  digest 对上即字节流对上。

输出行以 SINK- 开头，便于 grep 归档；计时用 time.monotonic()（宿主墙钟口径，
与 guest 的 esp_timer 口径互不共用时钟，结果互相印证）。
"""

import argparse
import socket
import sys
import time

PAT_SEED = 0x11C0FFEE
TILE_LEN = 64 * 1024


def build_tile():
    """与固件 fill_tile() 同一 xorshift32 递推，生成 64 KiB 图样周期。"""
    st = PAT_SEED
    buf = bytearray(TILE_LEN)
    for i in range(TILE_LEN):
        st ^= (st << 13) & 0xFFFFFFFF
        st ^= st >> 17
        st ^= (st << 5) & 0xFFFFFFFF
        buf[i] = (st >> 24) & 0xFF
    return bytes(buf)


def fletcher16(data, s1=0, s2=0):
    """与固件 fl_update() 同法：mod 255 累加。"""
    for b in data:
        s1 = (s1 + b) % 255
        s2 = (s2 + s1) % 255
    return s1, s2


def serve_one(conn, addr, idx, quiet):
    """读一条连接到底；返回 (bytes, mbit, digest)。"""
    conn.settimeout(60)
    total = 0
    s1 = s2 = 0
    t0 = None  # 首个字节到达时刻（净传输口径）
    last_prog = time.monotonic()
    while True:
        try:
            chunk = conn.recv(262144)
        except socket.timeout:
            print(f"SINK-TIMEOUT conn#{idx} partial_bytes={total}", flush=True)
            break
        if not chunk:
            break  # guest 半关：EOF
        if t0 is None:
            t0 = time.monotonic()
        total += len(chunk)
        s1, s2 = fletcher16(chunk, s1, s2)
        now = time.monotonic()
        if not quiet and t0 is not None and now - last_prog >= 2.0:
            el = now - t0
            mbit = total * 8 / el / 1e6 if el > 0 else 0.0
            print(f"SINK-PROG conn#{idx} t={el:.3f}s bytes={total} mbit={mbit:.1f}",
                  flush=True)
            last_prog = now
    # 完成应答位：guest 以此对齐 full_ms 计时终点
    try:
        conn.sendall(b"K")
        ack = "K"
    except OSError:
        ack = "lost"
    conn.close()

    digest = (s2 << 8) | s1
    if t0 is None or total == 0:
        print(f"SINK-DONE conn#{idx} EMPTY bytes=0 ack={ack}", flush=True)
        return 0, 0.0, digest
    dur = time.monotonic() - t0
    mbit = total * 8 / dur / 1e6
    print(f"SINK-DONE conn#{idx} peer={addr[0]}:{addr[1]} bytes={total} dur={dur:.3f}s "
          f"mbit={mbit:.2f} digest={digest:04x} ack={ack}", flush=True)
    return total, mbit, digest


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8290)
    ap.add_argument("--conns", type=int, default=-1, help="接受几个连接，<=0 无限")
    ap.add_argument("--quiet", action="store_true", help="不打进度行")
    args = ap.parse_args()

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("0.0.0.0", args.port))
    srv.listen(4)
    print(f"SINK-LISTEN port={args.port} conns="
          f"{'inf' if args.conns <= 0 else args.conns}", flush=True)

    n = 0
    ok_n = 0
    mbit_acc = 0.0
    digests = []
    while args.conns <= 0 or n < args.conns:
        try:
            conn, addr = srv.accept()
        except KeyboardInterrupt:
            break
        n += 1
        total, mbit, dg = serve_one(conn, addr, n, args.quiet)
        digests.append(dg)
        if total > 0:
            ok_n += 1
            mbit_acc += mbit

    srv.close()
    unique_dg = len(set(digests))
    if ok_n:
        head = (f"SINK-SUMMARY conns={n} with_data={ok_n} "
                f"avg_mbit={mbit_acc / ok_n:.2f}")
    else:
        head = f"SINK-SUMMARY conns={n} with_data=0"
    print(head, flush=True)
    dg_str = ",".join(f"{d:04x}" for d in digests)
    print(f"SINK-SUMMARY2 digests={dg_str} unique={unique_dg}", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
