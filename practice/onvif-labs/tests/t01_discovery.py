#!/usr/bin/env python3
"""t01 发现面：WS-Discovery Probe → ProbeMatch。

环境事实：本机 AP 过滤组播（ch12/ch16 宿主侧边界），故
1) MessageID 用随机 uuid（板端不会因重复 ID 去重沉默）；
2) 组播发 2 次后自动落到单播兜底（对齐 lab01 tools/onvif_probe.py --unicast 语义）；
3) 任一次收到含 device_service 的 ProbeMatch 即判 PASS。
"""

import socket
import uuid

_PROBE = (
    '<?xml version="1.0"?><e:Envelope '
    'xmlns:e="http://www.w3.org/2003/05/soap-envelope" '
    'xmlns:w="http://schemas.xmlsoap.org/ws/2004/08/addressing" '
    'xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery" '
    'xmlns:dn="http://www.onvif.org/ver10/network/wsdl">'
    '<e:Header><w:MessageID>urn:uuid:{mid}</w:MessageID>'
    '<w:To>urn:schemas-xmlsoap-org:ws:2005:04:discovery</w:To>'
    '<w:Action>e:http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</w:Action>'
    '</e:Header><e:Body><d:Probe><d:Types>dn:NetworkVideoTransmitter</d:Types>'
    '</d:Probe></e:Body></e:Envelope>'
)


def _probe_once(host, dest, mid):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(2)
    try:
        sock.sendto(_PROBE.format(mid=mid).encode(), dest)
        data, addr = sock.recvfrom(4096)
        return b"ProbeMatch" in data and b"device_service" in data, addr
    except socket.timeout:
        return False, None
    finally:
        sock.close()


def t01_discovery(c):
    mids = [str(uuid.uuid4()) for _ in range(4)]
    for i in range(2):  # 组播两次
        ok, addr = _probe_once(c["host"], ("239.255.255.250", 3702), mids[i])
        if ok:
            return True, f"组播 ProbeMatch from {addr[0]}"
    for i in range(2, 4):  # 单播兜底（AP 过滤组播时必经）
        ok, addr = _probe_once(c["host"], (c["host"], 3702), mids[i])
        if ok:
            return True, f"单播兜底 ProbeMatch from {addr[0]}"
    return False, "组播+单播共 4 次均超时"


TESTS = [("T01", "WS-Discovery ProbeMatch(组播→单播兜底)", t01_discovery)]
