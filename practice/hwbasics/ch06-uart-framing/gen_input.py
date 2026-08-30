#!/usr/bin/env python3
"""生成 ch06 注入流：一组好帧 + 五类坏帧/噪声，喂给 QEMU UART0 RX。

用法：
    python3 gen_input.py > in.bin        # 原始字节流写 stdout
    python3 gen_input.py --explain       # 人类可读的注入计划（含正确校验值）

注入计划（seq 用 2 位 hex，校验 = '$' 与 '*' 之间字节的异或）：
  00..02  好帧                  -> OK x3
  03      校验位故意写错        -> BADCS
  04,05   不发送（跳号）        -> 06 到达时 GAP（推断丢 2 帧）
  07      payload 70 字节       -> OLONG，尾部沦为帧间垃圾 -> STRAY
  08      只有 '\\n' 没有 '*xx' -> UNTERM
  --      帧间垃圾 "junk!"      -> STRAY（成段汇报）
  09      好帧                  -> OK（09 相对 want=07 会再报一次 GAP）
  0A      payload=STATS         -> OK + 打印汇总统计
"""

import sys


def xor_checksum(body: str) -> int:
    c = 0
    for b in body.encode("ascii"):
        c ^= b
    return c


def frame(seq: int, payload: str, csum=None) -> bytes:
    body = f"{seq:02X},{payload}"
    c = xor_checksum(body) if csum is None else csum
    return f"${body}*{c:02X}\n".encode("ascii")


def build() -> list[bytes]:
    return [
        frame(0x00, "PING"),
        frame(0x01, "LED=1"),
        frame(0x02, "TEMP=22.5"),
        frame(0x03, "BADCS", csum=xor_checksum("03,BADCS") ^ 0x5A),  # 必错
        # 0x04 / 0x05 故意不发送：制造序号空洞
        frame(0x06, "GAP2"),
        frame(0x07, "A" * 70),  # payload 上限 64 -> OLONG
        b"$08,ABC\n",  # 无 '*' 校验段 -> UNTERM
        b"junk!",  # 帧间垃圾 -> STRAY
        frame(0x09, "RESYNC"),
        frame(0x0A, "STATS"),
    ]


if __name__ == "__main__":
    if "--explain" in sys.argv:
        for chunk in build():
            print(repr(chunk))
    else:
        sys.stdout.buffer.write(b"".join(build()))
