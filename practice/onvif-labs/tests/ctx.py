#!/usr/bin/env python3
"""套件级共享上下文：地址、口令、解释器、传输原语、串口。

设计约定（README 详述）：
- 口令默认从 lab06 main/onvif_secrets.h 读，绝不打印；
- 解释器优先 ~/.venvs/onvif（持久），/tmp/onvif-venv 兜底，实际选用路径随汇总落盘；
- 所有网络原语自带超时，任何异常由 runner 捕获记 FAIL，禁止向上抛穿。
"""

import os
import re
import time

SUITE_DIR = os.path.dirname(os.path.abspath(__file__))
LAB06_DIR = os.path.join(SUITE_DIR, "..", "lab06-interop-harness")
SECRETS_H = os.path.join(LAB06_DIR, "main", "onvif_secrets.h")
TOOLS_DIR = os.path.join(LAB06_DIR, "tools")

SERIAL_PORT = "/dev/ttyUSB0"
SERIAL_BAUD = 115200

VENV_CANDIDATES = [
    os.path.expanduser("~/.venvs/onvif/bin/python"),
    "/tmp/onvif-venv/bin/python",
]


def find_python():
    """持久 venv 优先，/tmp 兜底；找不到返回 None（依赖 zeep 的测试会被跳过）。"""
    for p in VENV_CANDIDATES:
        if os.path.exists(p):
            return p
    return None


def password_from_secrets():
    """从 onvif_secrets.h 提取 ONVIF_AUTH_PASS；缺失返回 None。"""
    try:
        text = open(SECRETS_H, encoding="utf-8").read()
    except OSError:
        return None
    m = re.search(r'ONVIF_AUTH_PASS\s+"([^"]+)"', text)
    return m.group(1) if m else None


def soap_post(host, port, path, body, headers=None, timeout=8):
    """POST 一个 SOAP 信封，返回 (http_status, body_text)。"""
    import http.client
    h = {"Content-Type": "text/xml; charset=utf-8"}
    if headers:
        h.update(headers)
    conn = http.client.HTTPConnection(host, port, timeout=timeout)
    try:
        conn.request("POST", path, body=body, headers=h)
        resp = conn.getresponse()
        return resp.status, resp.read().decode("utf-8", "replace")
    finally:
        conn.close()


def board_get(host, path, port=80, timeout=5):
    """直连板子 GET，绕开代理；返回 (status, bytes)。"""
    import urllib.request
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(f"http://{host}:{port}{path}", timeout=timeout) as resp:
        return resp.status, resp.read()


def serial_send_and_read(send=None, pattern=None, timeout=8):
    """打开串口，可选先写一条命令，读到匹配 pattern 的行即返回该行；超时返回 None。

    打开前先 DTR/RTS 抖动会复位板子——这里**不复位**，只读（复位是显式的 serial_reset）。
    """
    import serial
    with serial.Serial(SERIAL_PORT, SERIAL_BAUD, timeout=1) as s:
        if send:
            s.write(send.encode() if isinstance(send, str) else send)
            s.flush()
        deadline = time.time() + timeout
        while time.time() < deadline:
            line = s.readline().decode("utf-8", "replace").strip()
            if line and (pattern is None or re.search(pattern, line)):
                return line
    return None


def serial_reset(wait=10):
    """DTR/RTS 抖动硬复位板子并等它起来（恢复挂死的 httpd 用）。"""
    import serial
    with serial.Serial(SERIAL_PORT, SERIAL_BAUD, timeout=1) as s:
        s.dtr = False
        s.rts = True
        time.sleep(0.1)
        s.rts = False
    time.sleep(wait)
