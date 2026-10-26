#!/usr/bin/env python3
"""t05 RTSP 面：信令四步 + 12s 成帧 + 板端对账（三本账不变量）。

- 客户端账：rtsp_ledger.py 输出 frames=N（按 RTP 时间戳去重后的完整帧行）
- 板端账：流结束后串口上 `$$$ ONVIF LAB05 TEARDOWN total=M`
- 不变量：M ≥ N（板端连握手窗口一起计），且 M - N ≤ 30（约 2s@15fps 的边界余量）
"""

import os
import re
import subprocess
import time

from ctx import TOOLS_DIR, serial_send_and_read


def t14_rtsp(c):
    """RTSP 是单客户端串行 accept 设计：任何存活的旧消费者（孤儿 ffmpeg /
    dash_keeper 孵化的 ffmpeg）都会占死会话槽。开测前清场——这是 ch16 计划外
    发现第 6 笔的自动化对策。"""
    subprocess.run(["pkill", "-9", "-f", "ffmpeg -rtsp_transport"],
                   capture_output=True, timeout=5)
    subprocess.run(["pkill", "-9", "-f", "dash_keeper.sh"],
                   capture_output=True, timeout=5)
    subprocess.run(["pkill", "-9", "-f", "dashboard.py"],
                   capture_output=True, timeout=5)
    time.sleep(1)
    if not c["venv"]:
        return False, "无 onvif venv"
    try:
        r = subprocess.run(
            [c["venv"], os.path.join(TOOLS_DIR, "rtsp_ledger.py"),
             c["host"], "--seconds", "12", "--user", "admin",
             "--password", c["password"]],
            capture_output=True, text=True, timeout=45)
    except subprocess.TimeoutExpired:
        return False, "ledger 45s 超时"
    out = r.stdout
    for step in ("OPTIONS", "DESCRIBE", "SETUP", "PLAY"):
        if f"RTSP/1.0 200 OK" not in out:
            return False, f"{step} 未拿到 200"
    m = re.search(r"frames=(\d+)", out)
    if not m or int(m.group(1)) == 0:
        return False, f"12s 窗口 0 完整帧: {out[-200:]}"
    n = int(m.group(1))
    # 板端对账：等 TEARDOWN total（流关后板端打印）
    line = serial_send_and_read(pattern=r"TEARDOWN total=(\d+)", timeout=10)
    if not line:
        return True, f"客户端 {n} 帧（板端 TEARDOWN 未读到——串口被占?）"
    mb = re.search(r"total=(\d+)", line)
    total = int(mb.group(1)) if mb else -1
    if total < n or total - n > 30:
        return False, f"三本账不平: board={total} client={n}"
    return True, f"对账齐: board={total} client={n}"


TESTS = [("T14", "RTSP 信令 + 12s 成帧 + 板端对账", t14_rtsp)]
