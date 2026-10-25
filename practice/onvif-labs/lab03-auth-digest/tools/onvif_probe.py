#!/usr/bin/env python3
"""WS-Discovery 探测器（lab01 验收工具，纯 stdlib）。

向 239.255.255.250:3702 组播一条 Probe（Types=dn:NetworkVideoTransmitter），
收集窗口内的全部 ProbeMatch 应答，逐条打印来源与关键字段（Types/XAddrs/
EndpointReference），便于与板端日志、tcpdump 三方对账。

用法：python3 tools/onvif_probe.py [--timeout 3] [--types dn:NetworkVideoTransmitter]
"""

import argparse
import socket
import time
import uuid

PROBE = (
    '<?xml version="1.0" encoding="UTF-8"?>'
    '<e:Envelope xmlns:e="http://www.w3.org/2003/05/soap-envelope"'
    ' xmlns:w="http://schemas.xmlsoap.org/ws/2004/08/addressing"'
    ' xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery"'
    ' xmlns:dn="http://www.onvif.org/ver10/network/wsdl">'
    "<e:Header>"
    "<w:MessageID>urn:uuid:{mid}</w:MessageID>"
    "<w:To>e:urn:schemas-xmlsoap-org:ws:2005:04:discovery</w:To>"
    "<w:Action>e:http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</w:Action>"
    "</e:Header>"
    "<e:Body>"
    "<d:Probe>"
    "<d:Types>{types}</d:Types>"
    "</d:Probe>"
    "</e:Body>"
    "</e:Envelope>"
)


def text_of(xml: str, tag: str) -> str:
    """取 <任意前缀:tag>value</...> 的 value；找不到返回空串。"""
    needle = f"{tag}>"
    start = xml.find(needle)
    if start < 0:
        return ""
    start += len(needle)
    end = xml.find("<", start)
    return xml[start:end] if end >= 0 else ""


def main() -> int:
    ap = argparse.ArgumentParser(description="WS-Discovery Probe sender / ProbeMatch collector")
    ap.add_argument("--timeout", type=float, default=3.0, help="收集窗口秒数（默认 3）")
    ap.add_argument("--types", default="dn:NetworkVideoTransmitter", help="Probe Types 过滤值")
    ap.add_argument("--unicast", metavar="IP", help="直发单播 Probe 到 IP:3702（AP 过滤组播时的兜底）")
    ap.add_argument("--repeat", type=int, default=1, help="Probe 发送次数（间隔 1s，抗组播丢包假阴性）")
    args = ap.parse_args()

    probe = PROBE.format(mid=uuid.uuid4(), types=args.types).encode()
    dest = (args.unicast, 3702) if args.unicast else ("239.255.255.250", 3702)
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.settimeout(0.5)
        print(f"probe target {dest[0]}:{dest[1]} (types={args.types}, repeat={args.repeat}),"
              f" collecting for {args.timeout}s ...")
        print("--- Probe (sent, raw) ---")
        print(probe.decode())

        deadline = time.time() + args.timeout
        sent = 0
        next_send = 0.0
        seen = 0
        while time.time() < deadline:
            if sent < args.repeat and time.time() >= next_send:
                sock.sendto(probe, dest)
                sent += 1
                next_send = time.time() + 1.0
                print(f"probe #{sent} -> {dest[0]}:{dest[1]}")
            try:
                data, src = sock.recvfrom(4096)
            except socket.timeout:
                continue
            xml = data.decode("utf-8", "replace")
            seen += 1
            print(f"\n--- ProbeMatch #{seen} from {src[0]}:{src[1]} ({len(data)} bytes) ---")
            print(xml)
            print("hex:", data.hex())
            print(
                f"$$$ HOST PROBEMATCH from={src[0]}"
                f" ep={text_of(xml, 'Address')}"
                f" types={text_of(xml, 'Types')}"
                f" xaddrs={text_of(xml, 'XAddrs')}"
            )
    print(f"\ntotal ProbeMatch: {seen}")
    return 0 if seen else 1


if __name__ == "__main__":
    raise SystemExit(main())
