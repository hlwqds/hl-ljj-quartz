#!/usr/bin/env python3
"""ex14 RX 腿宿主灌流器（gym_flood）—— 经 hostfwd 灌入 guest。

用法：
  python3 tools/gym_flood.py [--host 127.0.0.1] [--port 8310] [--rounds N]
                             [--mb MB] [--retry-sec SEC]

需要 QEMU 启动参数带 hostfwd：tcp::8310-:8310（见 README 运行命令）。
每轮：connect → 等 guest 发令枪 'R'（SLIRP hostfwd 会先于 guest 监听就把宿主侧
connect 放行，幻影连接必须靠 'R' 过滤，ex11 已验证的手法）→ sendall 精确 MB 字节
确定性图样 → 半关(SHUT_WR) → 等 guest 回 'K' → close。

大窗小环坏场景（sc2 broken）下 guest 收得极慢但仍在收——本工具 sendall 只受本端
缓冲限制，真正的瓶颈体现在 guest 侧 xfer_ms 拉长与 'K' 姗姗来迟，两端数字合起来
才是完整证据。digest/计时口径同 gym_sink.py。输出行以 GYMFLOOD- 开头。
"""

import argparse
import socket
import sys
import time

PAT_SEED = 0x11C0FFEE
TILE_LEN = 64 * 1024


def build_tile():
    """与固件 fill_tile() 同一 xorshift32 递推。"""
    st = PAT_SEED
    buf = bytearray(TILE_LEN)
    for i in range(TILE_LEN):
        st ^= (st << 13) & 0xFFFFFFFF
        st ^= st >> 17
        st ^= (st << 5) & 0xFFFFFFFF
        buf[i] = (st >> 24) & 0xFF
    return bytes(buf)


def fletcher16(data, s1=0, s2=0):
    """与固件 fl_update() 同法。"""
    for b in data:
        s1 = (s1 + b) % 255
        s2 = (s2 + s1) % 255
    return s1, s2


def connect_ready(host, port, hard_deadline):
    """拿一条「guest 已就绪」的真连接（幻影连接一律关掉重连）。"""
    attempts = 0
    while time.monotonic() < hard_deadline:
        attempts += 1
        try:
            s = socket.create_connection((host, port), timeout=5)
            s.settimeout(None)  # create_connection 的超时会残留成 IO 超时（ex11 踩坑）
            s.settimeout(6)
            b = s.recv(1)  # 等 guest 的发令枪 'R'
            if b == b"R":
                return s, attempts
            print(f"GYMFLOOD-WAIT phantom-conn byte={b!r} attempts={attempts}",
                  flush=True)
            s.close()
        except OSError as e:
            print(f"GYMFLOOD-WAIT conn-not-ready ({e}) attempts={attempts}",
                  flush=True)
        time.sleep(0.3)
    return None, attempts


def round_once(tile, sock, nbytes):
    """在已建立的一条连接上灌满 nbytes 并等 'K'。

    full_s 是「上端字节 → 收到 'K'」的端到端口径；send_s 只是管道口径参考。
    """
    sent = 0
    s1 = s2 = 0
    pat_off = 0
    t0 = None
    sock.settimeout(None)
    while sent < nbytes:
        want = min(TILE_LEN - pat_off, nbytes - sent)
        chunk = tile[pat_off:pat_off + want]
        if t0 is None:
            t0 = time.monotonic()
        sock.sendall(chunk)
        s1, s2 = fletcher16(chunk, s1, s2)
        sent += want
        pat_off = (pat_off + want) % TILE_LEN
    t_send_end = time.monotonic()

    sock.shutdown(socket.SHUT_WR)          # 半关：图样流终点即 EOF 标记
    sock.settimeout(60)                    # 黑洞场景 'K' 来得慢，给足窗口
    acked = False
    try:
        acked = sock.recv(1) == b"K"
    except (socket.timeout, OSError):
        pass
    t_full_end = time.monotonic()
    sock.close()

    dt_send = t_send_end - t0 if t0 else 0.0
    dt_full = t_full_end - t0 if t0 else 0.0
    mbit_e2e = sent * 8 / dt_full / 1e6 if dt_full > 0 else 0.0
    return sent, dt_send, dt_full, mbit_e2e, (s2 << 8) | s1, acked


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8310)
    ap.add_argument("--rounds", type=int, default=2)
    ap.add_argument("--mb", type=int, default=2, help="单轮 MB（十进制，与固件一致）")
    ap.add_argument("--retry-sec", dest="retry_sec", type=float, default=120,
                    help="从启动起的 connect 重试总预算")
    args = ap.parse_args()

    tile = build_tile()
    nbytes = args.mb * 1000000
    print(f"GYMFLOOD-LISTEN host={args.host}:{args.port} rounds={args.rounds} "
          f"mb={args.mb} pattern=xorshift32/64K", flush=True)

    deadline = time.monotonic() + args.retry_sec
    ok = 0
    mbit_acc = 0.0
    digests = []
    retries = 0
    for r in range(1, args.rounds + 1):
        now = time.monotonic()
        if now >= deadline:
            print(f"GYMFLOOD-GIVEUP round={r} retry_budget_exhausted", flush=True)
            break
        sock, attempts = connect_ready(args.host, args.port,
                                       min(deadline, now + 25.0))
        if sock is None:
            print(f"GYMFLOOD-GIVEUP round={r} no_listener attempts={attempts}",
                  flush=True)
            break
        try:
            sent, dt_send, dt_full, mbit_e2e, dg, acked = round_once(tile, sock,
                                                                     nbytes)
        except OSError as e:
            print(f"GYMFLOOD-RETRY round={r} {e}", flush=True)
            retries += 1
            if retries > 5:
                print(f"GYMFLOOD-GIVEUP round={r} too_many_retries", flush=True)
                break
            continue
        retries = 0
        digests.append(dg)
        if sent == nbytes and acked:
            ok += 1
            mbit_acc += mbit_e2e
        print(f"GYMFLOOD-DONE round={r} bytes={sent}/{nbytes} "
              f"send_s={dt_send:.3f} full_s={dt_full:.3f} "
              f"mbit_e2e={mbit_e2e:.3f} digest={dg:04x} "
              f"ack={'K' if acked else 'MISS'} attempts={attempts}", flush=True)

    print("GYMFLOOD-SUMMARY " + (f"rounds={args.rounds} ok={ok} avg_mbit="
                                 f"{mbit_acc / ok:.3f}" if ok else "ok=0"),
          flush=True)
    print("GYMFLOOD-SUMMARY2 digests=" + ",".join(f"{d:04x}" for d in digests),
          flush=True)
    return 0 if ok == args.rounds else 1


if __name__ == "__main__":
    sys.exit(main())
