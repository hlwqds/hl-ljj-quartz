#!/usr/bin/env python3
"""ex02 TCP echo server 并发压测 / digest 校验（宿主机侧运行）。

模型：N 条连接各发 M 条 size 字节消息；服务端逐字节原样回显。
每条消息做 ping-pong（发出后读满同长回包），累积 sha256 于
「本连接全部发出的字节流」与「全部收到的字节流」两个 digest，
两者一致 + 消息内容逐条相等 => PASS。

用法：
    python3 tools/bench.py [--host 127.0.0.1] [--port 8210]
                           [--conns 4] [--msgs 20] [--size 512]

退出码：0 = 全部 digest/内容校验通过；1 = 有不一致或异常。
（注意：服务端是单任务串行 accept——N 条并发连接在 backlog 里排队，
 逐条被服务，总耗时约等于各连接之和，这正是要演示的排队语义。）
"""

import argparse
import hashlib
import socket
import threading
import time


def worker(conn_id: int, host: str, port: int, msgs: int, size: int,
           results: dict) -> None:
    body_len = max(size - 10, 1)  # 消息头 "[cid:seq]" 固定占 10 字节
    payload = bytes([0x41 + (conn_id % 26)]) * size
    sent_digest = hashlib.sha256()
    recv_digest = hashlib.sha256()
    rtts = []
    ok = True
    try:
        t_c0 = time.perf_counter()
        sock = socket.create_connection((host, port), timeout=15)
        connect_s = time.perf_counter() - t_c0
        for i in range(msgs):
            # 每条消息带序号，防止"恰好同样内容的空转发"掩盖真实往返
            msg = f"[{conn_id:03d}:{i:04d}]".encode() + payload[:body_len]
            t0 = time.perf_counter()
            sock.sendall(msg)
            buf = bytearray()
            while len(buf) < len(msg):
                chunk = sock.recv(len(msg) - len(buf))
                if not chunk:
                    raise ConnectionError(f"conn {conn_id}: peer closed at msg {i}")
                buf.extend(chunk)
            rtts.append(time.perf_counter() - t0)
            if bytes(buf) != msg:
                ok = False
            sent_digest.update(msg)
            recv_digest.update(bytes(buf))
        sock.close()
    except OSError as e:
        results[conn_id] = dict(ok=False, err=repr(e), connect=0.0, rtts=[])
        return
    results[conn_id] = dict(
        ok=ok,
        err=None,
        connect=connect_s,
        rtt_min=min(rtts),
        rtt_max=max(rtts),
        rtt_avg=sum(rtts) / len(rtts),
        sent=sent_digest.hexdigest(),
        recv=recv_digest.hexdigest(),
    )


def main() -> int:
    ap = argparse.ArgumentParser(description="ex02 echo server bench")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8210)
    ap.add_argument("--conns", type=int, default=4)
    ap.add_argument("--msgs", type=int, default=20)
    ap.add_argument("--size", type=int, default=512)
    args = ap.parse_args()

    results: dict = {}
    barrier = threading.Barrier(args.conns, timeout=10)

    def guarded(cid):
        try:
            barrier.wait()
        except threading.BrokenBarrierError:
            pass
        worker(cid, args.host, args.port, args.msgs, args.size, results)

    print(
        f"BENCH start: conns={args.conns} msgs={args.msgs} "
        f"size={args.size} target={args.host}:{args.port}"
    )
    threads = [threading.Thread(target=guarded, args=(i,)) for i in range(args.conns)]
    t_all0 = time.perf_counter()
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    wall = time.perf_counter() - t_all0

    total_bytes = 0
    fails = []
    for cid in sorted(results):
        r = results[cid]
        if r.get("err"):
            fails.append(cid)
            print(f"conn {cid:3d}: ERROR {r['err']}")
            continue
        match = r["ok"] and r["sent"] == r["recv"]
        total_bytes += args.msgs * args.size * 2  # 上行 + 下行回显
        status = "PASS" if match else "DIGEST-MISMATCH"
        if not match:
            fails.append(cid)
        print(
            f"conn {cid:3d}: {status} connect={r['connect']:.1f}s "
            f"rtt_avg={r['rtt_avg'] * 1000:.0f}ms rtt_max={r['rtt_max'] * 1000:.0f}ms"
        )

    mbit = total_bytes * 8 / wall / 1e6
    verdict = "PASS" if not fails else "FAIL"
    print("BENCH RESULT "
          f"{verdict} conns={args.conns} msgs_per_conn={args.msgs} "
          f"total_wire_bytes={total_bytes} wall={wall:.1f}s agg={mbit:.2f}Mbit/s")
    return 0 if not fails else 1


if __name__ == "__main__":
    raise SystemExit(main())
