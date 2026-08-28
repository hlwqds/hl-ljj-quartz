#!/usr/bin/env python3
"""
第十二章实验主机端接收器。

用法：
  python3 recv_ch12.py bulk --port 8012 --conns 1     # 实验 a/c：读到底，报吞吐
  python3 recv_ch12.py msg  --port 8013 --conns 2     # 实验 b：16B 定长消息对分析

msg 模式解析 guest 发来的 16B 定长帧（小端）：
  [0:4)  seq u32      全局递增编号
  [4:8)  t_us u32     guest esp_timer 低 32 位（不做跨机换算，仅参考）
  [8:12) magic u32    = 0xC112BEEF
  [12:16) meta u32    高16位=pair 序号，低16位=对内序号(0/1)

统计两连接各自的：
  - 对内到达间隔 sep = arr(pair 第2条) - arr(pair 第1条)（主机时钟，
    受 recv 批量影响，是下界），输出中位数 / P95 / 最大值；
  - 组内所有消息的到达间隔分布。
"""

import argparse
import socket
import statistics
import sys
import time

MAGIC = 0xC112BEEF


def serve_bulk(conn, addr, idx):
    conn.settimeout(150)
    total = 0
    t0 = None
    while True:
        chunk = conn.recv(65536)
        if not chunk:
            break
        if t0 is None:
            t0 = time.monotonic()
            t_start = t0
        total += len(chunk)
    dur = time.monotonic() - t_start if t0 else 0.0
    mbit = total * 8 / dur / 1e6 if dur > 0 else 0.0
    print(f"HOST-DONE conn#{idx} addr={addr[0]}:{addr[1]} bytes={total} "
          f"dur={dur:.3f}s mbit={mbit:.2f}", flush=True)


def serve_msg(conn, addr, idx):
    conn.settimeout(60)
    buf = b""
    msgs = {}           # seq -> arrival monotonic
    pair_meta = {}      # seq -> (pair_idx, in_pair)
    t_first = None
    while True:
        try:
            chunk = conn.recv(65536)
        except socket.timeout:
            break
        if not chunk:
            break
        now = time.monotonic()
        if t_first is None:
            t_first = now
        buf += chunk
        while len(buf) >= 16:
            m = buf[:16]
            buf = buf[16:]
            seq, t_us, magic, meta = int.from_bytes(m[0:4], "little"), \
                int.from_bytes(m[4:8], "little"), \
                int.from_bytes(m[8:12], "little"), \
                int.from_bytes(m[12:16], "little")
            if magic != MAGIC:
                print(f"HOST-MSG-ERR bad magic {magic:#x} at seq {seq}", flush=True)
                continue
            msgs[seq] = now
            pair_meta[seq] = (meta >> 16, meta & 0xFFFF)
            # 打点行供离线核对：主机时钟相对时刻(秒) 与 guest t_us
            print(f"HOST-M conn#{idx} seq={seq} t_rel={now - t_first:9.6f}s "
                  f"gust_tus={t_us}", flush=True)

    n_pairs = max((p[0] for p in pair_meta.values()), default=-1) + 1
    seps, gaps = [], []
    last_arr = None
    for k in range(n_pairs):
        s1 = [s for s, p in pair_meta.items() if p == (k, 0)]
        s2 = [s for s, p in pair_meta.items() if p == (k, 1)]
        if not s1 or not s2:
            print(f"HOST-PAIR-MISSING pair#{k} first={bool(s1)} second={bool(s2)}",
                  flush=True)
            continue
        a1, a2 = msgs[s1[0]], msgs[s2[0]]
        seps.append((a2 - a1) * 1e6)          # us
        if last_arr is not None:
            gaps.append((a1 - last_arr) * 1e3)  # ms
        last_arr = a1

    def summ(v, unit, scale=1.0):
        if not v:
            return "n/a"
        v_sorted = sorted(v)
        med = statistics.median(v_sorted)
        p95 = v_sorted[min(len(v_sorted) - 1, int(round(0.95 * len(v_sorted))))]
        return (f"med={med * scale:.3f}{unit} p95={p95 * scale:.3f}{unit} "
                f"max={max(v) * scale:.3f}{unit} min={min(v) * scale:.3f}{unit}")

    print(f"HOST-SUMMARY conn#{idx} msgs={len(msgs)} pairs={n_pairs}")
    print(f"HOST-SEP   conn#{idx} intra-pair separation(us): {summ(seps, 'us')}")
    print(f"HOST-GAP   conn#{idx} inter-pair arrival gap(ms): {summ(gaps, 'ms')}",
          flush=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["bulk", "msg"])
    ap.add_argument("--port", type=int, default=8012)
    ap.add_argument("--conns", type=int, default=1)
    args = ap.parse_args()

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("0.0.0.0", args.port))
    srv.listen(4)
    print(f"listening on :{args.port} mode={args.mode} conns={args.conns}",
          flush=True)

    for i in range(args.conns):
        conn, addr = srv.accept()
        with conn:
            if args.mode == "bulk":
                serve_bulk(conn, addr, i + 1)
            else:
                serve_msg(conn, addr, i + 1)
    print("receiver exiting", flush=True)


if __name__ == "__main__":
    sys.exit(main())
