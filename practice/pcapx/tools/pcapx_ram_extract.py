#!/usr/bin/env python3
"""从 run.log 提取 pcapx_ram_dump 十六进制行，重组 pcap 文件。

用法（python3.12+，仅标准库）：

    ./pcapx_ram_extract.py run.log -o cap.pcap

目标行格式（与 src/pcapx_sink_ram.c 的 pcapx_sink_ram_dump 对齐）：

    pcapx_ram_dump begin cap=16384 used=8192 parsed=57 stored=57 evicted=0 ...
    pcapx_ram_dump 00000000 d4 c3 b2 a1 02 00 ...（每行 64 字节）
    pcapx_ram_dump end bytes=8216

处理规则：
  - 只取日志中「最后一个完整 begin..end 块」（重复 dump 取最新）。
  - 数据行按偏移必须连续（0 起、逐行衔接）；断档/乱序报错退出非 0，
    不做猜测补齐（RAM sink 记录粒度淘汰保证 dump 本身就是合法 pcap）。
  - 重组后做结构自检：pcap 魔数 + 逐记录头走查到文件尾；并把记录数
    与 begin 行 stored-evicted 对账（不齐时警告但不失败——dump 时点与
    begin 行打印之间可能又有新帧入环，属正常竞态）。

退出码：0 = 提取并校验通过；1 = 无数据/结构损坏/偏移断档。
"""

import argparse
import re
import struct
import sys

DATA_RE = re.compile(r"^pcapx_ram_dump ([0-9a-fA-F]{8})((?:\s+[0-9a-fA-F]{2})+)\s*$")
BEGIN_RE = re.compile(r"^pcapx_ram_dump begin\s+(.*)$")
END_RE = re.compile(r"^pcapx_ram_dump end bytes=(\d+)\s*$")
BEGIN_KV_RE = re.compile(r"(\w+)=(\d+)")

PCAP_MAGIC_BYTES = b"\xd4\xc3\xb2\xa1"
RHDR = struct.Struct("<IIII")  # ts_sec, ts_usec, incl_len, orig_len


def last_block(lines: list[str]) -> tuple[dict[str, int], list[tuple[int, bytes]], int] | None:
    """返回最后一个完整块的 (begin 元数据, [(offset, bytes)], end_bytes)。"""
    begin: dict[str, int] | None = None
    data: list[tuple[int, bytes]] = []
    end_bytes: int | None = None

    def finish() -> tuple[dict[str, int], list[tuple[int, bytes]], int] | None:
        if begin is not None and end_bytes is not None:
            return (begin, list(data), end_bytes)
        return None

    completed = None
    for line in lines:
        m = BEGIN_RE.match(line)
        if m:
            # 新块开始：结算上一个完整块后重置
            completed = finish() or completed
            begin = dict(BEGIN_KV_RE.findall(m.group(1)))
            data = []
            end_bytes = None
            continue
        m = DATA_RE.match(line)
        if m and begin is not None:
            off = int(m.group(1), 16)
            payload = bytes.fromhex(m.group(2).replace(" ", ""))
            data.append((off, payload))
            continue
        m = END_RE.match(line)
        if m and begin is not None:
            end_bytes = int(m.group(1))
            completed = finish()
            begin = None
            data = []
            end_bytes = None
    return completed or finish()


def check_contiguous(data: list[tuple[int, bytes]]) -> bytes:
    out = bytearray()
    expect = 0
    for off, chunk in data:
        if off != expect:
            raise SystemExit(f"FAIL: 数据行偏移断档：期望 {expect:#x} 实际 {off:#x}")
        out += chunk
        expect += len(chunk)
    return bytes(out)


def walk_records(pcap: bytes) -> tuple[int, str | None]:
    """结构自检：返回 (记录数, 错误消息)。"""
    if pcap[:4] != PCAP_MAGIC_BYTES:
        return 0, f"pcap 魔数不符: {pcap[:4].hex()} != d4c3b2a1"
    off = 24
    n = 0
    while off < len(pcap):
        if len(pcap) - off < 16:
            return n, f"记录头不完整 @ {off:#x}"
        _ts, _tu, incl, _orig = RHDR.unpack_from(pcap, off)
        if len(pcap) - off - 16 < incl:
            return n, f"记录载荷不完整 @ {off:#x} incl={incl}"
        off += 16 + incl
        n += 1
    return n, None


def main() -> int:
    ap = argparse.ArgumentParser(description="从 run.log 重组 RAM sink pcap（详见文件头 docstring）")
    ap.add_argument("logfile", help="run.log（或任何含 pcapx_ram_dump 行的文本）")
    ap.add_argument("-o", "--output", default="cap.pcap", help="输出 pcap 路径（默认 cap.pcap）")
    args = ap.parse_args()

    lines = open(args.logfile, "r", encoding="utf-8", errors="replace").read().splitlines()
    block = last_block(lines)
    if block is None:
        print("FAIL: 未找到完整的 pcapx_ram_dump begin..end 块")
        return 1
    meta, data, end_bytes = block

    pcap = check_contiguous(data)
    if len(pcap) != end_bytes:
        print(f"FAIL: 重组 {len(pcap)} 字节 != end 行声明 {end_bytes} 字节（行丢失？）")
        return 1

    n, err = walk_records(pcap)
    if err:
        print(f"FAIL: {err}")
        return 1

    with open(args.output, "wb") as f:
        f.write(pcap)
    meta_str = " ".join(f"{k}={v}" for k, v in meta.items())
    print(f"OK: {args.output} bytes={len(pcap)} records={n} (meta: {meta_str})")
    stored = int(meta.get("stored", 0))
    evicted = int(meta.get("evicted", 0))
    in_ring = stored - evicted
    if n != in_ring:
        print(f"note: 记录数 {n} != begin 行环内 {in_ring}（dump 时点竞态，正常）")
    print("建议接着跑 pcapx_validate.py 做完整校验")
    return 0


if __name__ == "__main__":
    sys.exit(main())
