#!/usr/bin/env python3
"""ex07 宿主端最小 SNTP v4 应答器（单文件、纯 stdlib）。

guest 通过 SLIRP 外连宿主机：guest 侧 10.0.2.2:P 等价于宿主机的 127.0.0.1:P
（SLIRP 外连转发，正向证据见 README 裁决小节），因此本脚本不需要任何 hostfwd。

两个槽位对应 ex07 固件的两条实验线：

  ntp       (8260) 标准 SNTP v4 服务应答器。收 48 字节请求(LI/VN/Mode=3)后回
                   Mode=4 服务包： originate=请求的 transmit 字段，
                   receive/xmit 用宿主墙钟(UTC)。guest 的 lwIP SNTP 经编译期
                   SNTP_PORT=8260 覆盖与本端口闭环（见根 CMakeLists.txt）。
  reflector (8262) 原样反射器：任意数据报收到后按字节回发。供固件的 UDP 转发
                   裁决探针使用——往返成立即证明「guest 出站 UDP 可达宿主」。

8261 端口故意【不监听】：固件的空端口探针用它观察宿主无服务时的现象。

用法：
  python3 tools/ntpd.py                # 一口气起两槽位（推荐）
  python3 tools/ntpd.py --only ntp     # 只起 8260
  python3 tools/ntpd.py --only reflector

日志行以 NTP- 前缀打出（与 guest 侧 EX07- 标记呼应），全部 flush 方便 tee。
本脚本打印的宿主墙钟时间戳就是「真实时间参照物」，README 摘录用它与 guest
对时结果对账。
"""

import argparse
import socket
import struct
import sys
import threading
import time
from datetime import datetime, timezone

NTP_PORT = 8260
REFLECTOR_PORT = 8262
NTP_DELTA = 2208988800  # 1900 -> 1970 秒差


def log(msg: str):
    print(msg, flush=True)


def ready_line(kind: str, port: int):
    now = datetime.now(timezone.utc)
    log(
        f"$$$ NTPREADY kind={kind} port={port} host_utc={now.strftime('%Y-%m-%dT%H:%M:%S.%f')[:-3]}Z"
    )


def _split_ts(t: float):
    """float 秒 -> (uint32 整秒含 1900 偏移, uint32 小数 x 2^32)。"""
    adj = t + NTP_DELTA
    sec = int(adj)
    frac = int(round((adj - sec) * (1 << 32)))
    if frac >= (1 << 32):
        frac -= (1 << 32)
        sec += 1
    return sec & 0xFFFFFFFF, frac & 0xFFFFFFFF


def serve_ntp(port: int):
    """SNTP v4 应答循环。协议常量参考 RFC 4330；只用 stdlib struct 手组包头。"""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.bind(("127.0.0.1", port))
    except OSError as e:
        log(f"NTP-FATAL kind=ntp port={port} err={e} hint=\"其他实例占用？ss -ulnp | grep {port}\"")
        return
    s.settimeout(None)
    ready_line("ntp", port)
    while True:
        data, peer = s.recvfrom(1024)
        t_recv_wall = time.time()  # 真实时间参照：请求到达宿主的墙钟时刻
        iso = datetime.fromtimestamp(t_recv_wall, timezone.utc)
        if len(data) < 48:
            log(
                f"NTP-BAD port={port} peer={peer[0]}:{peer[1]} len={len(data)} "
                f"head={data[:16].hex()} note=\"不是合法 NTP 包，忽略\""
            )
            continue
        li_vn_mode = data[0]
        li, vn, mode = li_vn_mode >> 6, (li_vn_mode >> 3) & 0b111, li_vn_mode & 0b111
        log(
            f"NTP-REQ ts={iso.strftime('%Y-%m-%dT%H:%M:%S.%f')}Z peer={peer[0]}:{peer[1]} "
            f"li={li} vn={vn} mode={mode} len={len(data)} "
            f"{'OK' if vn == 4 and mode == 3 else 'ANOMALY(vn!=4 or mode!=client)'}"
        )
        # ---- 组装 48 字节应答 ----
        resp = bytearray(48)
        resp[0] = (0 << 6) | (4 << 3) | 4  # LI=0, Version=4, Mode=4(server)
        resp[1] = 2  # stratum 2（secondary reference，上游是宿主系统时钟）
        resp[2] = 6  # poll：建议对时间隔 2^6=64s（信息性字段）
        resp[3] = 0xEC  # precision：2^-20 ≈ 0.95us（声明精度）
        struct.pack_into("!I", resp, 4, 0)  # root delay: 0
        struct.pack_into("!I", resp, 8, round(0.05 * (1 << 16)))  # root dispersion ~50ms
        resp[12:16] = b"HOST"  # reference ID（stratum<2 才是 ASCII 码，此处仅作指纹）
        struct.pack_into("!II", resp, 16, *_split_ts(t_recv_wall - 0.001))  # reference TS
        resp[24:32] = data[24:32]  # originate = 请求的 transmit 字段（SNTP 规范直通）
        struct.pack_into("!II", resp, 32, *_split_ts(t_recv_wall))  # receive TS
        t_xmit_wall = time.time()
        struct.pack_into("!II", resp, 40, *_split_ts(t_xmit_wall))  # transmit TS
        s.sendto(bytes(resp), peer)
        dt_us = int((t_xmit_wall - t_recv_wall) * 1e6)
        log(
            f"NTP-RSP peer={peer[0]}:{peer[1]} bytes={len(resp)} "
            f"xmit_epoch={t_xmit_wall:.6f} srv_processing_us={dt_us}"
        )


def serve_reflector(port: int):
    """原样反射循环：转发裁决探针的对端（收到什么回什么，逐字节保真）。"""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.bind(("127.0.0.1", port))
    except OSError as e:
        log(f"NTP-FATAL kind=reflector port={port} err={e} hint=\"端口占用？\"")
        return
    ready_line("reflector", port)
    rx = tx = 0
    while True:
        data, peer = s.recvfrom(2048)
        rx += len(data)
        ok = data == bytearray(48)  # 不做语义，只记账
        s.sendto(data, peer)
        tx += len(data)
        magic = data[4:14].decode("ascii", errors="replace") if len(data) >= 14 else "?"
        log(
            f"NTP-ECHO peer={peer[0]}:{peer[1]} len={len(data)} head={data[:20].hex()} "
            f"magic=\"{magic.strip(chr(0))}\" rx_bytes={rx} tx_bytes={tx} allzero={ok}"
        )


def main():
    ap = argparse.ArgumentParser(description="ex07 宿主端最小 SNTP v4 应答器 + UDP 反射器")
    ap.add_argument("--only", choices=["ntp", "reflector"], help="只启动单个槽位（默认全启）")
    args = ap.parse_args()

    threads = []
    if args.only in (None, "ntp"):
        threads.append(threading.Thread(target=serve_ntp, args=(NTP_PORT,), daemon=True))
    if args.only in (None, "reflector"):
        threads.append(threading.Thread(target=serve_reflector, args=(REFLECTOR_PORT,), daemon=True))

    for t in threads:
        t.start()
    log(
        f"NTP-ALL slots={'all' if args.only is None else args.only} waiting ..."
        "（Ctrl-C 结束；8261 保持无监听——那是固件空端口探针的对象）"
    )
    try:
        while True:
            time.sleep(3600)
    except KeyboardInterrupt:
        log("NTP-BYE")
        sys.exit(0)


if __name__ == "__main__":
    main()
