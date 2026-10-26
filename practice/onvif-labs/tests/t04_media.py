#!/usr/bin/env python3
"""t04 媒体面：zeep 冒烟逐行解析 + 快照直取。

onvif_smoke.py 每项操作打印独立证据行（OP/FAULT ... ok），这里把
stdout 按行映射为独立测试项——而不是五个项共用一个退出码。
快照用直连 GET 验 JPEG magic（zeep 不管二进制面）。
"""

import os
import subprocess

from ctx import TOOLS_DIR, board_get

_MAP = [
    ("OP GetDeviceInformation ok", "T09", "zeep GetDeviceInformation"),
    ("OP GetProfiles ok", "T10", "zeep GetProfiles(profile_1)"),
    ("OP GetStreamUri ok", "T11", "zeep GetStreamUri → rtsp://"),
    ("FAULT GetStreamUri(unknown token) ok", "T12", "zeep 未知 ProfileToken → InvalidArgVal"),
]


def t09_smoke(c):
    """跑一遍 onvif_smoke.py，逐行出证据；venv 缺失记 SKIP-FAIL 并说明。"""
    if not c["venv"]:
        return False, "无 onvif venv（~/.venvs/onvif 或 /tmp/onvif-venv）"
    outdir = os.path.join(c["outdir"], "smoke-xml")
    try:
        r = subprocess.run(
            [c["venv"], os.path.join(TOOLS_DIR, "onvif_smoke.py"),
             "--host", c["host"], "--password", c["password"], "--outdir", outdir],
            capture_output=True, text=True, timeout=60)
    except subprocess.TimeoutExpired:
        return False, "onvif_smoke 60s 超时（板子 httpd 挂死? 串口复位后重试）"
    lines = r.stdout.splitlines()
    if r.returncode != 0:
        tail = (r.stderr or r.stdout).splitlines()[-3:]
        return False, "rc={} tail={}".format(r.returncode, " | ".join(tail))
    hits = []
    for frag, tid, name in _MAP:
        found = any(frag in ln and "ok" in ln for ln in lines)
        hits.append((tid, name, found))
    bad = [t for t in hits if not t[2]]
    # 把逐行结果暂存全局，runner 打印时可见
    t09_smoke.hits = hits
    if bad:
        return False, "缺失证据行: " + ", ".join(t[0] for t in bad)
    return True, "4/4 证据行齐"


t09_smoke.hits = []


def t13_snapshot(c):
    st, data = board_get(c["host"], "/onvif-http/snapshot")
    ok = st == 200 and data.startswith(b"\xff\xd8") and len(data) > 10000
    return ok, f"{len(data)}B JPEG"


TESTS = [
    ("T09", "zeep 冒烟: 设备信息/Profiles/StreamUri/未知Token", t09_smoke),
    ("T13", "快照直取 200 + JPEG magic", t13_snapshot),
]
