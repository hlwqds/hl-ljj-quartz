#!/usr/bin/env python3
"""ex14 TX 腿宿主接收器（gym_sink）—— guest raw 泵的外部对端。

用法：
  python3 tools/gym_sink.py [--port 8311] [--conns N] [--quiet]

guest 的 TX 腿会主动外连 10.0.2.2:8311（SLIRP 落到宿主机 loopback 同端口，
无需 hostfwd 配合），把确定性图样灌进来后关连接。本工具读到底即打印摘要：
字节数、耗时、吞吐、Fletcher-16 校验值。

digest 算法与固件逐位一致：Fletcher-16（mod 255）+ 64 KiB xorshift32 图样
（seed=0x11c0ffee，同 ex11 口径），两端各自实现同一递推式，digest 对上即内容对上。
计时用 time.monotonic()（宿主墙钟口径），与固件 esp_timer 双口径互证。

ex14 特化：TX 腿在"涓流"坏场景下会被固件中途 abort（截断早停收档），本连接以
RST/EOF 收场——serve_one 对中途断流做了兼容，SINK-TIMEOUT / ConnectionResetError
都是合法的记账终点而非崩溃。输出行以 GYMSINK- 开头便于 grep 归档。
"""

import argparse
import socket
import sys
import time

PAT_SEED = 0x11C0FFEE
TILE_LEN = 64 * 1024


def build_tile():
    """与固件 fill_tile() 同一 xorshift32 递推（校验用，本工具自身不产生图样）。"""
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
    """读一条连接到底（或到断流）；返回 (bytes, mbit, digest)。"""
    conn.settimeout(60)
    total = 0
    s1 = s2 = 0
    t0 = None
    last_prog = time.monotonic()
    while True:
        try:
            chunk = conn.recv(262144)
        except socket.timeout:
            print(f"GYMSINK-TIMEOUT conn#{idx} partial_bytes={total}", flush=True)
            break
        except OSError as e:  # 涓流场景固件 abort 会以 RST 收场，属预期终点
            print(f"GYMSINK-BROKEN conn#{idx} partial_bytes={total} err={e}",
                  flush=True)
            break
        if not chunk:
            break  # guest 关闭：正常 EOF
        if t0 is None:
            t0 = time.monotonic()
        total += len(chunk)
        s1, s2 = fletcher16(chunk, s1, s2)
        now = time.monotonic()
        if not quiet and t0 is not None and now - last_prog >= 2.0:
            el = now - t0
            mbit = total * 8 / el / 1e6 if el > 0 else 0.0
            print(f"GYMSINK-PROG conn#{idx} t={el:.3f}s bytes={total} "
                  f"mbit={mbit:.3f}", flush=True)
            last_prog = now
    try:
        conn.sendall(b"K")  # 完成应答位；涓流 abort 时发不出也不影响本端记账
        ack = "K"
    except OSError:
        ack = "lost"
    conn.close()

    digest = (s2 << 8) | s1
    if t0 is None or total == 0:
        print(f"GYMSINK-DONE conn#{idx} EMPTY bytes=0 ack={ack}", flush=True)
        return 0, 0.0, digest
    dur = time.monotonic() - t0
    mbit = total * 8 / dur / 1e6
    print(f"GYMSINK-DONE conn#{idx} peer={addr[0]}:{addr[1]} bytes={total} "
          f"dur={dur:.3f}s mbit={mbit:.3f} digest={digest:04x} ack={ack}",
          flush=True)
    return total, mbit, digest


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8311)
    ap.add_argument("--conns", type=int, default=-1, help="接受几个连接，<=0 无限")
    ap.add_argument("--quiet", action="store_true", help="不打进度行")
    args = ap.parse_args()

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("0.0.0.0", args.port))
    srv.listen(4)
    print(f"GYMSINK-LISTEN port={args.port} conns="
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
        head = (f"GYMSINK-SUMMARY conns={n} with_data={ok_n} "
                f"avg_mbit={mbit_acc / ok_n:.3f}")
    else:
        head = f"GYMSINK-SUMMARY conns={n} with_data=0"
    print(head, flush=True)
    dg_str = ",".join(f"{d:04x}" for d in digests)
    print(f"GYMSINK-SUMMARY2 digests={dg_str} unique={unique_dg}", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
