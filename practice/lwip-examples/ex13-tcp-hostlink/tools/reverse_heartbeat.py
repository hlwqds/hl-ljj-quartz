#!/usr/bin/env python3
"""ex13 出向心跳接收器（单文件、纯 stdlib）。

guest 每 5s 主动连 10.0.2.2:8301 —— 在 SLIRP 下就是本机 loopback:8301
（SLIRP 边界事实：guest 发往网关 10.0.2.2 的 TCP 落到宿主机 loopback 同端口，
因此本脚本不需要任何 QEMU 参数配合，先于固件或中途启动都行）。

每拍心跳一条独立 TCP 会话：收一行 JSON -> 校验关键字段 -> 回 "ACK\\n" ->
立即断开（guest 收到 ACK 即断，与固件约定一致）。

用法：
  python3 tools/reverse_heartbeat.py                 # 正常校验回 ACK
  python3 tools/reverse_heartbeat.py --port 8301     # 默认即 8301
  python3 tools/reverse_heartbeat.py --mode noack    # 故障注入：收下心跳但不回
                                                     # ACK，供固件演示 NO_ACK/
                                                     # EAGAIN 分支（SO_RCVTIMEO）

日志行以 RHB- 前缀打出（与 guest 侧 EX13HB/EX13HBDROP 呼应），全部 flush 方便 tee。
"""

import argparse
import json
import socket
import sys
import threading
import time

REQUIRED_KEYS = ["type", "seq", "ip", "up_s", "heap_free", "conn_total"]


def stamp() -> str:
    t = time.time()
    return f"{time.strftime('%H:%M:%S')}.{int(t * 1000) % 1000:03d}"


def log(msg: str) -> None:
    print(f"[{stamp()}] {msg}", flush=True)


class Ledger:
    """跨线程的累计账本（Python 整数赋值原子，够模板用）。"""

    def __init__(self):
        self.lock = threading.Lock()
        self.seen = 0
        self.valid = 0
        self.invalid = 0

    def bump(self, field: str) -> int:
        with self.lock:
            setattr(self, field, getattr(self, field) + 1)
            return getattr(self, field)


LEDGER = Ledger()


def serve_hb(conn: socket.socket, addr, idx: int, mode: str) -> None:
    raw = b""
    why = "ok"
    conn.settimeout(8)
    try:
        while b"\n" not in raw:
            chunk = conn.recv(1024)
            if not chunk:
                why = "peer-FIN-before-newline"
                break
            raw += chunk
            if len(raw) > 4096:
                why = "oversize-no-newline"
                break
    except socket.timeout:
        why = "read-timeout"
    except OSError as e:
        why = f"recv-errno-{e.errno}"

    text = raw.split(b"\n", 1)[0].decode(errors="replace").strip()
    valid_keys = []
    missing = []
    payload = None
    if text:
        try:
            payload = json.loads(text)
            if isinstance(payload, dict):
                missing = [k for k in REQUIRED_KEYS if k not in payload]
                valid_keys = [k for k in REQUIRED_KEYS if k in payload]
        except json.JSONDecodeError:
            pass

    valid = payload is not None and isinstance(payload, dict) and not missing \
        and payload.get("type") == "hb"

    acked = False
    if mode == "normal" and why == "ok":
        try:
            conn.sendall(b"ACK\n")
            acked = True
        except OSError as e:
            why = f"send-ACK-errno-{e.errno}"

    if mode == "noack":
        # 故障注入：故意握着连接不回话。guest 等 ACK 的 SO_RCVTIMEO 到期后会
        # 判定 NO_ACK(EAGAIN) 断开；这里顺势等它走完再收尾。
        conn.settimeout(15)
        try:
            conn.recv(64)  # 阻塞到 guest 关闭
        except OSError:
            pass

    conn.close()
    n = LEDGER.bump("seen")
    field = "valid" if valid else "invalid"
    LEDGER.bump(field)
    tag = "$$$ RHB-HB" if valid else "RHB-HB-BAD"
    log(f"{tag} conn#{idx} src={addr[0]}:{addr[1]} json={text!r} "
        f"valid={'YES' if valid else f'NO(missing={missing},raw_len={len(raw)})'} "
        f"ack={'YES' if acked else 'NO'} mode={mode} drop_reason={why} "
        f"seq_seen={n}")
    if payload is not None and valid:
        log(f"RHB-PAYLOAD conn#{idx} seq={payload.get('seq')} ip={payload.get('ip')!s} "
            f"up_s={payload.get('up_s')} heap_free={payload.get('heap_free')} "
            f"conn_total={payload.get('conn_total')}")


def listen_loop(bind: str, port: int, mode: str) -> None:
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        srv.bind((bind, port))
        srv.listen(4)
    except OSError as e:
        log(f"$$$ RHBFAIL bind {bind}:{port} errno={e.errno} ({e})")
        sys.exit(1)
    log(f"$$$ RHBREADY bind={bind} port={port} mode={mode} "
        f"expect_json_keys={','.join(REQUIRED_KEYS)}")
    idx = 0
    while True:
        try:
            conn, addr = srv.accept()
        except KeyboardInterrupt:
            break
        idx += 1
        threading.Thread(target=serve_hb, args=(conn, addr, idx, mode),
                         daemon=True).start()
    srv.close()
    log(f"RHBBYE seen={LEDGER.seen} valid={LEDGER.valid} "
        f"invalid={LEDGER.invalid}")


def main() -> int:
    ap = argparse.ArgumentParser(description="ex13 outbound-heartbeat receiver")
    ap.add_argument("--bind", default="127.0.0.1",
                    help="监听地址（默认 loopback；SLIRP 落地在 127.0.0.1）")
    ap.add_argument("--port", type=int, default=8301)
    ap.add_argument("--mode", choices=["normal", "noack"], default="normal",
                    help="noack=故障注入：收心跳但不回 ACK（演示 guest 超时分支）")
    args = ap.parse_args()
    listen_loop(args.bind, args.port, args.mode)
    return 0


if __name__ == "__main__":
    sys.exit(main())
