#!/usr/bin/env python3
import os
import socket
import struct
import time


iface = os.environ.get("TRAFFIC_PORT", "host-traffic0")
count = int(os.environ.get("TRAFFIC_PACKETS", "256"))
interval = float(os.environ.get("TRAFFIC_INTERVAL", "0.005"))

src = bytes.fromhex(os.environ.get("TRAFFIC_SRC_MAC", "020000000001"))
dst = bytes.fromhex(os.environ.get("TRAFFIC_DST_MAC", "ffffffffffff"))
eth_type = struct.pack("!H", int(os.environ.get("TRAFFIC_ETH_TYPE", "0x88B5"), 0))
payload_size = int(os.environ.get("TRAFFIC_PAYLOAD_SIZE", "64"))
payload = (b"dpdk-vhost-user-lab" * ((payload_size // 19) + 1))[:payload_size]
frame = dst + src + eth_type + payload

sock = socket.socket(socket.AF_PACKET, socket.SOCK_RAW)
sock.bind((iface, 0))

for _ in range(count):
    sock.send(frame)
    if interval > 0:
        time.sleep(interval)

print(f"sent {count} ethernet frames on {iface}")
