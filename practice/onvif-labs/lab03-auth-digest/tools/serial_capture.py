#!/usr/bin/env python3
"""抓取板端串口日志 N 秒（lab01 取证工具）。

pyserial 打开端口时默认断言 DTR/RTS，经板上自动复位电路触发一次复位——
因此每次运行都会从头收一遍完整启动日志，适合做 run.log 取证。
需要 pyserial（IDF venv 自带，或宿主 pip 安装）。

用法：python3 tools/serial_capture.py [--port /dev/ttyUSB0] [--seconds 40]
      [--send-at 9:status --send-at 30:status] > run.log
"""

import argparse
import sys
import time

import serial


def main() -> int:
    ap = argparse.ArgumentParser(description="capture N seconds of board serial log (resets board on open)")
    ap.add_argument("--port", default="/dev/ttyUSB0", help="串口节点（按 VID:PID 10c4:ea60 定位）")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--seconds", type=float, default=40.0, help="抓取时长秒数")
    ap.add_argument("--no-reset", action="store_true", help="不复位，只被动收流")
    ap.add_argument(
        "--send-at",
        action="append",
        default=[],
        metavar="SS:TEXT",
        help="启动后第 SS 秒向控制台写一行 TEXT（如 --send-at 9:status，heap/status 打点用），可重复",
    )
    args = ap.parse_args()

    send_at = []
    for spec in args.send_at:
        when, text = spec.split(":", 1)
        send_at.append([float(when), text, False])
    send_at.sort(key=lambda item: item[0])

    end = time.time() + args.seconds
    with serial.Serial(args.port, args.baud, timeout=1) as s:
        if not args.no_reset:
            # esptool 式硬复位：RTS→EN 脉冲（0.1s），保证从头收完整启动日志。
            # 仅打开端口不拉线时板子不会复位（esptool 烧完已把电平留在非复位态）。
            s.dtr = False
            s.rts = True
            time.sleep(0.1)
            s.rts = False
        start = time.time()
        while True:
            now = time.time()
            for item in send_at:
                if not item[2] and now - start >= item[0]:
                    s.write((item[1] + "\r\n").encode())
                    item[2] = True
            if now >= end:
                break
            data = s.read(4096)
            if data:
                sys.stdout.buffer.write(data)
                sys.stdout.flush()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
