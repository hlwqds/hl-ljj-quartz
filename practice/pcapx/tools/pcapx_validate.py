#!/usr/bin/env python3
"""校验 pcapx 产物 pcap 文件的合法性与计数断言。

用法（python3.12+，仅标准库）：

    ./pcapx_validate.py capture.pcap
    ./pcapx_validate.py capture.pcap --expect arp=2,udp=10,total=12
    ./pcapx_validate.py capture.pcap --expect rx=120,tx=88

检查项：
  1. 全局头（24B）：魔数 0xa1b2c3d4（µs）、version 2.4、network==1
     （LINKTYPE_ETHERNET）、snaplen 读出后用于逐记录断言。
  2. 逐记录头（16B）：incl_len <= snaplen（snaplen==0 时按 262144 上限）、
     orig_len >= incl_len、ts_usec < 1e6。
  3. 文件不截断：最后一条记录完整，且无尾部多余字节。

计数摘要：总记录数、按以太网 type（ARP/IPv4/IPv6/其他，含单层 VLAN
展开）与 IPv4 协议（ICMP/TCP/UDP/其他）分类、truncated（incl<orig）数。

--expect 口径（断言失败 exit 非 0，全过 exit 0）：
  total/arp/ip/ipv6/icmp/tcp/udp/other/truncated = 对应摘要计数。
  rx/tx：pcap 文件本身不记录方向，rx 与 tx 必须成对给出，断言
  rx+tx == total（分工核对：方向各自的数量请对 pcapx_stats 输出）。
"""

import argparse
import struct
import sys

PCAP_MAGIC_US = 0xa1B2C3D4
PCAP_GHDR = struct.Struct("<IHHiIII")  # magic, vmaj, vmin, tz, sigfigs, snaplen, network
PCAP_RHDR = struct.Struct("<IIII")  # ts_sec, ts_usec, incl_len, orig_len

ETHERTYPE_IPV4 = 0x0800
ETHERTYPE_ARP = 0x0806
ETHERTYPE_IPV6 = 0x86DD
VLAN_TPIDS = (0x8100, 0x88A8, 0x9100)

# snaplen==0（"无上限"）时的兜底断言上限，与 RAM sink 的长度合理性上限一致
FALLBACK_SNAPLEN = 256 * 1024


def parse_record_headers(data: bytes, snaplen_effective: int) -> tuple[list, str | None]:
    """返回 (记录列表, 错误消息)。记录元素为 (hdr_tuple, payload_bytes)。"""
    records = []
    off = PCAP_GHDR.size
    while off < len(data):
        if len(data) - off < PCAP_RHDR.size:
            return records, f"truncated record header at offset {off} (need 16, have {len(data) - off})"
        ts_sec, ts_usec, incl_len, orig_len = PCAP_RHDR.unpack_from(data, off)
        off += PCAP_RHDR.size
        if incl_len > snaplen_effective:
            return records, f"incl_len {incl_len} > snaplen {snaplen_effective} at offset {off - 16}"
        if orig_len < incl_len:
            return records, f"orig_len {orig_len} < incl_len {incl_len} at offset {off - 16}"
        if ts_usec >= 1_000_000:
            return records, f"ts_usec {ts_usec} >= 1e6 at offset {off - 16}"
        if len(data) - off < incl_len:
            return records, f"truncated record payload at offset {off} (need {incl_len}, have {len(data) - off})"
        payload = data[off : off + incl_len]
        records.append(((ts_sec, ts_usec, incl_len, orig_len), payload))
        off += incl_len
    return records, None


def classify(payload: bytes) -> tuple[str, str | None]:
    """按 (链路层类型, IPv4 协议) 分类一条以太网记录。"""
    if len(payload) < 14:
        return "short", None
    et = (payload[12] << 8) | payload[13]
    l3_off = 14
    while et in VLAN_TPIDS and len(payload) >= l3_off + 4:
        et = (payload[l3_off + 2] << 8) | payload[l3_off + 3]
        l3_off += 4
    if et == ETHERTYPE_ARP:
        return "arp", None
    if et == ETHERTYPE_IPV6:
        return "ipv6", None
    if et != ETHERTYPE_IPV4:
        return "other", None
    if len(payload) < l3_off + 10:
        return "ip", "short"
    ihl = (payload[l3_off] & 0x0F) * 4
    if ihl < 20 or len(payload) < l3_off + ihl:
        return "ip", "short"
    proto = payload[l3_off + 9]
    name = {1: "icmp", 6: "tcp", 17: "udp"}.get(proto, "other")
    return "ip", name


def summarize(records: list) -> dict[str, int]:
    c: dict[str, int] = {
        "total": len(records),
        "arp": 0,
        "ip": 0,
        "ipv6": 0,
        "other": 0,
        "icmp": 0,
        "tcp": 0,
        "udp": 0,
        "truncated": 0,
    }
    for (_hdr, payload) in records:
        l2, l4 = classify(payload)
        if l2 == "ip":
            c["ip"] += 1
            if l4 in ("icmp", "tcp", "udp"):
                c[l4] += 1  # type: ignore[index]
        elif l2 == "short":
            # 捕获长度小于以太网头（snaplen<14 的截断记录）无法分类
            c["other"] += 1
        else:
            c[l2] += 1  # arp / ipv6 / other
        _ts, _tu, incl, orig = _hdr
        if incl < orig:
            c["truncated"] += 1
    return c


def parse_expect(spec: str) -> dict[str, int]:
    out: dict[str, int] = {}
    for kv in spec.split(","):
        k, _, v = kv.partition("=")
        k, v = k.strip(), v.strip()
        if not k or not v or not v.lstrip("-").isdigit():
            raise SystemExit(f"--expect 格式错误: {kv!r}（应为 k=v 整数）")
        out[k] = int(v)
    return out


VALID_KEYS = {"total", "arp", "ip", "ipv6", "icmp", "tcp", "udp", "other", "truncated"}


def check_expect(expect: dict[str, int], summary: dict[str, int]) -> list[str]:
    errs: list[str] = []
    rx_tx = {k: v for k, v in expect.items() if k in ("rx", "tx")}
    keys = set(expect) - set(rx_tx)
    bad = keys - VALID_KEYS
    if bad:
        errs.append(f"未知 expect 键: {sorted(bad)}（可用: {sorted(VALID_KEYS)} 外加成对的 rx/tx）")
    if len(rx_tx) == 1:
        errs.append("rx/tx 必须成对给出（pcap 不记录方向，只能断言 rx+tx==total）")
    for k in keys & VALID_KEYS:
        if expect[k] != summary[k]:
            errs.append(f"expect {k}={expect[k]} != 实际 {k}={summary[k]}")
    if len(rx_tx) == 2:
        want = rx_tx["rx"] + rx_tx["tx"]
        if want != summary["total"]:
            errs.append(f"expect rx+tx={want} != 实际 total={summary['total']}")
    return errs


def main() -> int:
    ap = argparse.ArgumentParser(description="pcapx pcap 产物校验（详见文件头 docstring）")
    ap.add_argument("file", help="待校验的 pcap 文件")
    ap.add_argument("--expect", default=None,
                    help="计数断言，如 arp=2,udp=10 或 rx=120,tx=88（rx/tx 须成对，断言其和==total）")
    args = ap.parse_args()

    data = open(args.file, "rb").read()
    errs: list[str] = []

    if len(data) < PCAP_GHDR.size:
        print(f"FAIL: 文件不足 24 字节全局头（{len(data)}）")
        return 1
    magic, vmaj, vmin, _tz, _sig, snaplen, network = PCAP_GHDR.unpack_from(data, 0)
    if magic != PCAP_MAGIC_US:
        errs.append(f"magic=0x{magic:08x} != 0xa1b2c3d4（µs）")
    if (vmaj, vmin) != (2, 4):
        errs.append(f"version={vmaj}.{vmin} != 2.4")
    if network != 1:
        errs.append(f"network={network} != 1 (LINKTYPE_ETHERNET)")
    if errs:
        for e in errs:
            print(f"FAIL: {e}")
        return 1

    snap_eff = snaplen if snaplen > 0 else FALLBACK_SNAPLEN
    records, err = parse_record_headers(data, snap_eff)
    if err:
        print(f"FAIL: {err}")
        return 1

    summary = summarize(records)
    print(f"OK: {args.file} magic=0x{magic:08x} snaplen={snaplen} linktype=Ethernet(1)")
    print("counts: " + " ".join(f"{k}={v}" for k, v in summary.items()))
    if records:
        print(f"first_ts={records[0][0][0]}.{records[0][0][1]:06d} "
              f"last_ts={records[-1][0][0]}.{records[-1][0][1]:06d}")

    if args.expect:
        exp = parse_expect(args.expect)
        eerrs = check_expect(exp, summary)
        if eerrs:
            for e in eerrs:
                print(f"EXPECT-FAIL: {e}")
            return 1
        print(f"expect OK: {args.expect}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
