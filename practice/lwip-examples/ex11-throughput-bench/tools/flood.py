#!/usr/bin/env python3
"""ex11 RX 模式宿主灌流器（flood）。

用法：
  python3 flood.py [--host 127.0.0.1] [--port 8291] [--rounds N] [--mb MB]
                   [--retry-sec SEC]

对 guest 的 :8291 数据口做 N 轮灌流：connect → sendall 精确 MB 字节的确定性图样 →
半关(SHUT_WR) → 等 guest 回一个字节 'K'（guest 已收完并记账）→ close。

connect 被拒就退避重试：因为 BOTH 模式下 guest 在两轮 RX 之间穿插 TX 轮，且每轮 RX
监听口是「用完即拆」的（防止半开连接把测量窗口搅浑），flood 必须能礼貌等待下一轮
监听出现。单轮 10s + 总预算 --retry-sec 双层兜底防呆等。

digest 与计时同 sink.py：Fletcher-16 / 64 KiB xorshift32 图样与固件逐位一致；
宿主墙钟 time.monotonic()，与 guest esp_timer 双口径互证。

输出行以 FLOOD- 开头，便于 grep 归档；轮次未跑满以非零码退出（CI 友好）。
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
    """拿一条「guest 已就绪」的真连接。

    SLIRP 的 hostfwd 会立刻接受宿主侧 connect()（哪怕 guest 还没监听），
    所以 connect 成功不代表能灌流——必须等 guest 发来的 'R' 就绪字节。
    幻影连接（'R' 超时/对端重置）一律关掉重连。返回 (sock|None, 尝试次数)。
    """
    attempts = 0
    while time.monotonic() < hard_deadline:
        attempts += 1
        try:
            s = socket.create_connection((host, port), timeout=5)
            s.settimeout(None)  # create_connection 的超时会残留成 IO 超时（首跑踩坑）
            s.settimeout(6)
            b = s.recv(1)  # 等 guest 的发令枪 'R'
            if b == b"R":
                return s, attempts
            print(f"FLOOD-WAIT phantom-conn byte={b!r} attempts={attempts}", flush=True)
            s.close()
        except OSError as e:
            print(f"FLOOD-WAIT conn-not-ready ({e}) attempts={attempts}", flush=True)
        time.sleep(0.3)
    return None, attempts


def round_once(tile, sock, nbytes):
    """在已建立的一条连接上灌满 nbytes 并等 'K'。

    返回 (sent, send_s, full_s, mbit_e2e, digest, acked)。
    send_s   ：首字节写出 → 末字节被 sendall 接受 —— 注意这是「管道口径」：
               SLIRP/回环的套接字缓冲足够大，send 返回 ≠ 数据到了 guest，
               本例实测 4MB 只要 ~0.13s（虚高数倍），只能当灌流速率参考。
    full_s   ：上者 → 收到 'K'（guest 已收满并记账）——这才是端到端口径，
               与 guest 侧 esp_timer 的 xfer_ms 互证。
    """
    sent = 0
    s1 = s2 = 0
    pat_off = 0
    t0 = None
    sock.settimeout(None)  # 就绪等待用过的短超时解除；灌流本身靠对端排空自然推进
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
    sock.settimeout(20)
    acked = False
    try:
        acked = sock.recv(1) == b"K"       # guest 收满后的完成应答位
    except socket.timeout:
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
    ap.add_argument("--port", type=int, default=8291)
    ap.add_argument("--rounds", type=int, default=3)
    ap.add_argument("--mb", type=int, default=4, help="单轮 MB（十进制，与固件一致）")
    ap.add_argument("--retry-sec", dest="retry_sec", type=float, default=120,
                    help="从启动起的 connect 重试总预算")
    args = ap.parse_args()

    tile = build_tile()
    nbytes = args.mb * 1000000
    print(f"FLOOD-LISTEN host={args.host}:{args.port} rounds={args.rounds} "
          f"mb={args.mb} pattern=xorshift32/64K", flush=True)

    deadline = time.monotonic() + args.retry_sec
    ok = 0
    mbit_acc = 0.0
    digests = []
    retries = 0
    for r in range(1, args.rounds + 1):
        now = time.monotonic()
        if now >= deadline:
            print(f"FLOOD-GIVEUP round={r} retry_budget_exhausted", flush=True)
            break
        sock, attempts = connect_ready(args.host, args.port,
                                       min(deadline, now + 10.0))
        if sock is None:
            print(f"FLOOD-GIVEUP round={r} no_listener attempts={attempts}", flush=True)
            break
        try:
            sent, dt_send, dt_full, mbit_e2e, dg, acked = round_once(tile, sock, nbytes)
        except OSError as e:
            # 半途 RST（guest 轮间窗口被撞上等）：整轮重来，预算内最多重试若干次
            print(f"FLOOD-RETRY round={r} {e}", flush=True)
            retries += 1
            if retries > 5:
                print(f"FLOOD-GIVEUP round={r} too_many_retries", flush=True)
                break
            continue
        retries = 0
        digests.append(dg)
        if sent == nbytes and acked:
            ok += 1
            mbit_acc += mbit_e2e
        print(f"FLOOD-DONE round={r} bytes={sent}/{nbytes} send_s={dt_send:.3f} "
              f"full_s={dt_full:.3f} mbit_e2e={mbit_e2e:.2f} digest={dg:04x} "
              f"ack={'K' if acked else 'MISS'} attempts={attempts}", flush=True)

    print("FLOOD-SUMMARY " + (f"rounds={args.rounds} ok={ok} avg_mbit="
                              f"{mbit_acc / ok:.2f}" if ok else f"ok=0"), flush=True)
    print("FLOOD-SUMMARY2 digests=" + ",".join(f"{d:04x}" for d in digests),
          flush=True)
    return 0 if ok == args.rounds else 1


if __name__ == "__main__":
    sys.exit(main())
