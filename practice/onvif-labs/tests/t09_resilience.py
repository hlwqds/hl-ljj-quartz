#!/usr/bin/env python3
"""t09 httpd 控制面韧性（ch17 §17.5.4「完美运行」欠账的实证与回归）。

T31: 连发 3 条半开连接（声明 Content-Length 不发体，占住 httpd 单任务）后，
     正常 SOAP 请求必须在 8s 内恢复 200。
     机理：esp_http_server 单任务串行 + recv_wait_timeout；未修前默认 5s/条
     （3 条 ≈ 15s 阻塞窗），六站压到 1s 后 ≈ 3s 内恢复。超时即暴露窗口回潮。
"""

import socket
import time


def t31(c):
    host = c["host"]
    socks = []
    try:
        for _ in range(3):
            s = socket.create_connection((host, 80), timeout=3)
            s.settimeout(3)
            s.sendall(b"POST /onvif/device_service HTTP/1.1\r\nHost: x\r\n"
                      b"Content-Type: text/xml\r\nContent-Length: 100\r\n\r\n")
            socks.append(s)
        time.sleep(0.5)
        body = ('<?xml version="1.0"?><s:Envelope '
                'xmlns:s="http://www.w3.org/2003/05/soap-envelope" '
                'xmlns:tds="http://www.onvif.org/ver10/device/wsdl">'
                '<s:Body><tds:GetSystemDateAndTime/></s:Body></s:Envelope>')
        t0 = time.time()
        b = socket.create_connection((host, 80), timeout=8)
        b.settimeout(8)
        b.sendall(f"POST /onvif/device_service HTTP/1.1\r\nHost: x\r\n"
                  f"Content-Length: {len(body)}\r\n\r\n".encode() + body.encode())
        r = b.recv(200).decode("utf-8", "replace").splitlines()[0]
        dt = time.time() - t0
        b.close()
        ok = "200" in r and dt < 8.0
        return ok, f"恢复耗时 {dt:.1f}s（<8s 窗口）→ {r}"
    finally:
        for s in socks:
            s.close()


TESTS = [("T31", "httpd 韧性: 3 条半开连接后 8s 内恢复 200", t31)]
