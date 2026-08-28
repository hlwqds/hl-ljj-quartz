#!/usr/bin/env python3
"""
ch21 实验宿主机桥：最小 MQTT 3.1.1 客户端（仅 stdlib）。

职责：
  1. 以 qos1 订阅 '#'，把 guest 发来的每一条 PUBLISH 落一行 JSONL：
     {ts_ns, topic, plen, seq, tag, qos, dup} —— 到达数/重复数统计的权威数据源；
  2. RTT 回声：收到 ch21/rtt/req 立即以 qos0 回发 ch21/rtt/rsp 同载荷；
  3. broker 被 SIGTERM/SIGSTOP 波及时自动重连续订（broker 重启窗口不丢数据——
     SIGSTOP 期间内核仍会应答 TCP，且 SUBSCRIBE 会话随断连丢失，重连后重订即可，
     断连窗口内错过 qos1 消息的“会话丢失”是实验语义的一部分，桥记录每次重连事件）。
"""

import argparse
import json
import os
import re
import socket
import struct
import sys
import time

SEQ_RE = re.compile(rb"i=(\d+);")

def rcv_exact(s, n):
    buf = b""
    while len(buf) < n:
        chunk = s.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("peer closed")
        buf += chunk
    return buf

def varint_decode(sock):
    mult = 1
    val = 0
    while True:
        b = rcv_exact(sock, 1)[0]
        val += (b & 0x7F) * mult
        if not (b & 0x80):
            return val
        mult *= 128

def varint_encode(n):
    out = b""
    while True:
        d = n % 128
        n //= 128
        if n:
            d |= 0x80
        out += bytes([d])
        if not n:
            return out

class Bridge:
    def __init__(self, jsonl_path):
        self.f = open(jsonl_path, "a", buffering=1)
        self.echo_count = 0
        self.msg_total = 0
        self.reconnects = 0

    def log(self, s):
        print(f"[bridge] {s}", flush=True)

    def connect_session(self):
        s = socket.create_connection(("127.0.0.1", 1883), timeout=10)
        s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        s.settimeout(30)
        # CONNECT（3.1.1）：可变头 = 协议名(2+4) + level(1) + connect-flags(1)
        #                + keepalive(2)；随后是 payload(clientId)。
        # 注意 clientId 长度必须用 len() 动态写——写死一位就是协议错误。
        # 带上 pid 随机化：防止"同 id 接管踢旧连接"的自持互踢风暴。
        cid = f"ch21bridge-{os.getpid()}".encode()
        payload = struct.pack("!H", len(cid)) + cid
        vh = struct.pack("!H", 4) + b"MQTT" + bytes([4])     # name + level
        flags = bytes([0x02])                                 # clean session
        ka = struct.pack("!H", 60)
        body = vh + flags + ka + payload
        s.sendall(bytes([0x10]) + varint_encode(len(body)) + body)
        ack = rcv_exact(s, 4)
        assert ack[0] >> 4 == 2 and ack[3] == 0, f"CONNACK bad: {ack.hex()}"
        # SUBSCRIBE '#' qos1
        body = struct.pack("!H", 1) + struct.pack("!H", 1) + b"#"+bytes([1])
        s.sendall(bytes([0x82]) + varint_encode(len(body)) + body)
        suback = rcv_exact(s, 5)
        assert suback[0] >> 4 == 9, f"SUBACK bad: {suback.hex()}"
        return s

    def publish_echo(self, s, data):
        topic = b"ch21/rtt/rsp"
        pkt = struct.pack("!H", len(topic)) + topic + data
        s.sendall(bytes([0x30]) + varint_encode(len(pkt)) + pkt)
        self.echo_count += 1

    def puback(self, s, pid):
        s.sendall(bytes([0x40, 0x02]) + struct.pack("!H", pid))

    def run_forever(self):
        while True:
            try:
                s = self.connect_session()
            except OSError as e:
                self.reconnects += 1
                self.log(f"connect failed ({e}), retry in 0.3s")
                time.sleep(0.8)
                continue
            if self.reconnects:
                pass
            self.log("session up (connect+subscribe ok)")
            try:
                self.pump(s)
            except (ConnectionError, OSError) as e:
                self.log(f"connection lost: {e} -> reconnect")
                try:
                    s.close()
                except Exception:
                    pass
                time.sleep(0.5)

    def pump(self, s):
        while True:
            b0 = rcv_exact(s, 1)[0]
            rlen = varint_decode(s)
            rest = rcv_exact(s, rlen) if rlen else b""
            mtype = b0 >> 4
            if mtype == 13:                      # PINGREQ -> PINGRESP
                s.sendall(b"\xd0\x00")
                continue
            if mtype == 14:                      # DISCONNECT
                self.log("broker sent DISCONNECT")
                return
            if mtype != 3:                       # 只关心 PUBLISH
                continue
            qos = (b0 >> 1) & 0x03
            dup = (b0 >> 3) & 0x01
            tlen = struct.unpack("!H", rest[:2])[0]
            topic = rest[2:2 + tlen].decode(errors="replace")
            off = 2 + tlen
            pid = None
            if qos > 0:
                pid = struct.unpack("!H", rest[off:off + 2])[0]
                off += 2
            payload = rest[off:]
            ts_ns = time.time_ns()

            m = SEQ_RE.match(payload)
            seq = int(m.group(1)) if m else -1
            parts = payload.split(b";")
            tag = parts[2].decode(errors="replace") if len(parts) >= 3 else ""
            self.msg_total += 1
            rec = {"ts_ns": ts_ns, "topic": topic, "plen": len(payload),
                   "seq": seq, "tag": tag, "qos": qos, "dup": dup}
            self.f.write(json.dumps(rec) + "\n")

            if qos == 1 and pid is not None:
                self.puback(s, pid)
            elif qos == 2 and pid is not None:
                s.sendall(bytes([0x50, 0x02]) + struct.pack("!H", pid))
            if topic == "ch21/rtt/req":
                self.publish_echo(s, payload)

if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--jsonl", required=True)
    args = ap.parse_args()
    Bridge(args.jsonl).run_forever()
