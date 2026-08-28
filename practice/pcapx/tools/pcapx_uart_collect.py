#!/usr/bin/env python3
"""pcapx UART sink 宿主端收集器：从串口/日志文件提取 PCAX 帧并重组 pcap。

用法（python3.12+，仅标准库；可选 pyserial）：

  实时收串口（真机，推荐先安装 pyserial：pip install pyserial）：
    ./pcapx_uart_collect.py -d /dev/ttyUSB0 -b 921600 -o cap.pcap --seconds 30

  从 run.log 提帧（QEMU 里 UART sink 用 UART0 时，帧以原始字节混在
  日志文本中；字节级魔数扫描 + CRC 校验自动滤掉穿插文本）：
    ./pcapx_uart_collect.py --from-log run.log -o cap.pcap

  从十六进制文本提帧（比如先 xxd 过的流；仅保留十六进制字符后解码）：
    ./pcapx_uart_collect.py --hex-dump raw.hex -o cap.pcap

帧协议（与 src/pcapx_sink_uart.c 文件头对齐，宿主侧对齐基准）：
  "PCAX" + uint16_le len(1..512) + payload[len] + uint16_le crc16
  crc16 = CRC-16/CCITT-FALSE(payload)：多项式 0x1021、初值 0xFFFF、
  不反射、不异或输出（检验向量 crc16("123456789")==0x29B1）。
  各帧 payload 顺序拼接即为 pcap 文件。
  重同步：魔数命中但 len>512 或 CRC 失败 → 前进 1 字节继续扫。

依赖说明：pyserial 未安装且未用 --from-log/--hex-dump 时，回退到
subprocess + stty + os.open/select 方案（仅 POSIX，已在本仓库 Fedora
环境验证思路；Windows 必须装 pyserial）。

退出码：0 = 至少收到 1 帧且写出 pcap；1 = 参数错/无有效帧。
"""

import argparse
import re
import select
import os
import subprocess
import sys
import time

MAGIC = b"PCAX"
FRAME_MAX = 512


def crc16_ccitt_false(data: bytes) -> int:
    crc = 0xFFFF
    for b in data:
        crc ^= b << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) if (crc & 0x8000) else (crc << 1)
            crc &= 0xFFFF
    return crc


def extract_frames(stream: bytes) -> tuple[bytes, int, int]:
    """从任意字节流扫帧。返回 (payload 拼接, 好帧数, 坏帧数)。"""
    out = bytearray()
    good = bad = 0
    i = 0
    while True:
        i = stream.find(MAGIC, i)
        if i < 0:
            break
        ok = False
        if i + 6 <= len(stream):
            ln = stream[i + 4] | (stream[i + 5] << 8)
            if 1 <= ln <= FRAME_MAX and i + 6 + ln + 2 <= len(stream):
                payload = stream[i + 6 : i + 6 + ln]
                crc = stream[i + 6 + ln] | (stream[i + 6 + ln + 1] << 8)
                if crc == crc16_ccitt_false(payload):
                    out += payload
                    good += 1
                    i += 6 + ln + 2
                    ok = True
        if not ok:
            bad += 1
            i += 1  # 假魔数/坏帧：前进 1 字节重同步
    return bytes(out), good, bad


def collect_serial_pyserial(dev: str, baud: int, seconds: float) -> bytes:
    import serial  # pyserial

    buf = bytearray()
    with serial.Serial(dev, baud, timeout=1.0) as ser:
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            n = ser.in_waiting
            if n:
                buf += ser.read(n)
            else:
                time.sleep(0.05)
    return bytes(buf)


def collect_serial_stty(dev: str, baud: int, seconds: float) -> bytes:
    """pyserial 缺席时的 POSIX 兜底：stty 配口 + 非阻塞读 + select 超时。"""
    subprocess.run(
        ["stty", "-F", dev, "raw", "-echo", "-echoe", "-echok", str(baud)],
        check=True,
    )
    fd = os.open(dev, os.O_RDONLY | os.O_NOCTTY | os.O_NONBLOCK)
    try:
        buf = bytearray()
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            r, _w, _e = select.select([fd], [], [], 0.2)
            if r:
                chunk = os.read(fd, 65536)
                if chunk:
                    buf += chunk
        return bytes(buf)
    finally:
        os.close(fd)


HEX_LINE = re.compile(r"[^0-9a-fA-F]")


def decode_hex_text(path: str) -> bytes:
    """十六进制文本 → 字节：逐行剔除非十六进制字符后拼接解码。

    形如 `xxd`、`hexdump -v -e '1/1 "%02x "'`、或自产 hex 行均可；
    奇数长度尾巴（行尾被日志截断）会被丢弃并计数。
    """
    out = bytearray()
    odd_dropped = 0
    for line in open(path, "r", encoding="utf-8", errors="replace"):
        hx = HEX_LINE.sub("", line)
        if len(hx) % 2:
            odd_dropped += 1
            hx = hx[:-1]
        if hx:
            out += bytes.fromhex(hx)
    if odd_dropped:
        print(f"warn: {odd_dropped} 行十六进制长度为奇数（截断），已截尾", file=sys.stderr)
    return bytes(out)


def main() -> int:
    ap = argparse.ArgumentParser(description="pcapx UART 帧收集（详见文件头 docstring）")
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("-d", "--device", help="串口设备（如 /dev/ttyUSB0）")
    src.add_argument("--from-log", metavar="FILE", help="从含原始 UART 字节的文件/run.log 提帧")
    src.add_argument("--hex-dump", metavar="FILE", help="从十六进制文本文件提帧")
    ap.add_argument("-b", "--baud", type=int, default=115200, help="波特率（默认 115200）")
    ap.add_argument("-o", "--output", default="cap.pcap", help="输出 pcap 路径（默认 cap.pcap）")
    ap.add_argument("--seconds", type=float, default=30.0, help="串口采集时长秒（默认 30）")
    args = ap.parse_args()

    if args.device:
        try:
            raw = collect_serial_pyserial(args.device, args.baud, args.seconds)
            how = "pyserial"
        except ImportError:
            raw = collect_serial_stty(args.device, args.baud, args.seconds)
            how = "stty+select（未安装 pyserial 的回退）"
        print(f"read {len(raw)} bytes from {args.device} @ {args.baud} via {how}")
    elif args.from_log:
        raw = open(args.from_log, "rb").read()
        print(f"read {len(raw)} bytes from {args.from_log}")
    else:
        raw = decode_hex_text(args.hex_dump)
        print(f"decoded {len(raw)} bytes from hex text {args.hex_dump}")

    pcap, good, bad = extract_frames(raw)
    print(f"frames ok={good} bad={bad} pcap_bytes={len(pcap)}")
    if not pcap:
        print("FAIL: 未提取到任何有效帧")
        return 1
    with open(args.output, "wb") as f:
        f.write(pcap)
    print(f"wrote {args.output}（建议接着跑 pcapx_validate.py 校验）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
