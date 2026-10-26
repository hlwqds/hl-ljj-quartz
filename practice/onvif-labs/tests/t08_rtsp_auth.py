#!/usr/bin/env python3
"""t08 媒体面 Digest 鉴权（ch17 §17.5.3）。

T26 无凭据 DESCRIBE → 401 + WWW-Authenticate: Digest；裸 PLAY（无 SETUP/凭据）同样 401
T27 带凭据全流程（401→质询应答→200→SETUP→PLAY→成帧）
T28 错口令 → 401（且不出流）
T29 nonce 一次性重放 → 401；已鉴权后无 SETUP 直 PLAY → 454
"""

import hashlib
import re
import socket

from ctx import TOOLS_DIR
import os
import subprocess


def _conn(host, timeout=5):
    s = socket.create_connection((host, 8554), timeout=timeout)
    s.settimeout(timeout)
    return s


def _rtsp(s, method, cseq, extra="", uri_path=None, host=None):
    req = f"{method} rtsp://{host}:8554/mjpeg RTSP/1.0\r\nCSeq: {cseq}\r\n{extra}\r\n"
    s.sendall(req.encode())
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = s.recv(2048)
        if not chunk:
            break
        data += chunk
    head, _, rest = data.partition(b"\r\n\r\n")
    # 按 Content-Length 把 body 读满丢弃（SDP）——分段确定性，残体不毒化下一响应
    m = re.search(rb"Content-Length: (\d+)", head)
    if m:
        need = int(m.group(1)) - len(rest)
        while need > 0:
            c = s.recv(min(need, 4096))
            if not c:
                break
            need -= len(c)
            rest += c
    return head.decode("utf-8", "replace")


def _digest_header(user, password, method, uri, www_auth):
    realm = re.search(r'realm="([^"]+)"', www_auth).group(1)
    nonce = re.search(r'nonce="([^"]+)"', www_auth).group(1)
    ha1 = hashlib.md5(f"{user}:{realm}:{password}".encode()).hexdigest()
    ha2 = hashlib.md5(f"{method}:{uri}".encode()).hexdigest()
    resp = hashlib.md5(f"{ha1}:{nonce}:{ha2}".encode()).hexdigest()
    return (f"Authorization: Digest username=\"{user}\", realm=\"{realm}\", "
            f"nonce=\"{nonce}\", uri=\"{uri}\", response=\"{resp}\"\r\n")


def t26(c):
    """无凭据 DESCRIBE 与裸 PLAY 都必须 401 + Digest 质询。"""
    s = _conn(c["host"])
    r1 = _rtsp(s, "DESCRIBE", 1, "Accept: application/sdp\r\n", host=c["host"])
    ok1 = r1.startswith("RTSP/1.0 401") and "WWW-Authenticate: Digest" in r1
    r2 = _rtsp(s, "PLAY", 2, host=c["host"])
    ok2 = r2.startswith("RTSP/1.0 401")
    s.close()
    return (ok1 and ok2), f"DESCRIBE={'401' if ok1 else r1.splitlines()[0]}, PLAY={'401' if ok2 else r2.splitlines()[0]}"


def t27(c):
    """带凭据全流程：401→质询→200→SETUP→PLAY→6s 成帧（ledger --user/--pass）。"""
    if not c["venv"]:
        return False, "无 onvif venv"
    try:
        r = subprocess.run(
            [c["venv"], os.path.join(TOOLS_DIR, "rtsp_ledger.py"),
             c["host"], "--seconds", "6", "--user", "admin",
             "--password", c["password"]],
            capture_output=True, text=True, timeout=45)
    except subprocess.TimeoutExpired:
        return False, "ledger 45s 超时"
    out = r.stdout
    ok200 = out.count("RTSP/1.0 200 OK") >= 4  # OPTIONS/DESCRIBE×2/SETUP/PLAY
    m = re.search(r"frames=(\d+)", out)
    ok_frames = m and int(m.group(1)) > 0
    return (ok200 and bool(ok_frames)), f"200×{out.count('RTSP/1.0 200 OK')} frames={m.group(1) if m else '?'}"


def t28(c):
    """错口令：质询应答后仍 401。"""
    s = _conn(c["host"])
    r1 = _rtsp(s, "DESCRIBE", 1, "Accept: application/sdp\r\n", host=c["host"])
    www = next((ln for ln in r1.splitlines() if ln.lower().startswith("www-authenticate:")), "")
    hdr = _digest_header("admin", "wrong-pass-x", "DESCRIBE",
                         f"rtsp://{c['host']}:8554/mjpeg", www)
    r2 = _rtsp(s, "DESCRIBE", 2, "Accept: application/sdp\r\n" + hdr, host=c["host"])
    s.close()
    return r2.startswith("RTSP/1.0 401"), f"re-DESCRIBE={r2.splitlines()[0]}"


def t29(c):
    """nonce 一次性：首次合法 200 → 同头重放 401 → 新 nonce 再入 200；
    已鉴权连接无 SETUP 直 PLAY → 454。"""
    s = _conn(c["host"])
    uri = f"rtsp://{c['host']}:8554/mjpeg"
    r1 = _rtsp(s, "DESCRIBE", 1, "Accept: application/sdp\r\n", host=c["host"])
    www1 = next((ln for ln in r1.splitlines() if ln.lower().startswith("www-authenticate:")), "")
    hdr1 = _digest_header("admin", c["password"], "DESCRIBE", uri, www1)
    r2 = _rtsp(s, "DESCRIBE", 2, "Accept: application/sdp\r\n" + hdr1, host=c["host"])
    ok_first = r2.startswith("RTSP/1.0 200 OK")
    # 已鉴权连接：无 SETUP 直 PLAY → 454（RFC 2326 状态前置；鉴权门已过）
    r3 = _rtsp(s, "PLAY", 3, host=c["host"])
    ok454 = r3.startswith("RTSP/1.0 454")
    s.close()
    # 同头重放必须在【新连接】上测：已鉴权连接的 authed 门闩放行后续请求是
    # RTSP 标准语义（建立时验一次）；nonce 一次性由新连接的独立验证兜住。
    # （组件串行 accept：必须先关上一条连接，否则新连接在 backlog 里饿死）
    s2 = _conn(c["host"])
    r4 = _rtsp(s2, "DESCRIBE", 1, "Accept: application/sdp\r\n" + hdr1, host=c["host"])
    ok_replay = r4.startswith("RTSP/1.0 401")
    www4 = next((ln for ln in r4.splitlines() if ln.lower().startswith("www-authenticate:")), "")
    hdr4 = _digest_header("admin", c["password"], "DESCRIBE", uri, www4)
    r5 = _rtsp(s2, "DESCRIBE", 2, "Accept: application/sdp\r\n" + hdr4, host=c["host"])
    ok_recover = r5.startswith("RTSP/1.0 200 OK")
    s2.close()
    detail = (f"first={'200' if ok_first else r2.splitlines()[0]}, "
              f"direct PLAY={'454' if ok454 else r3.splitlines()[0]}, "
              f"replay={'401' if ok_replay else r4.splitlines()[0]}, "
              f"recover={'200' if ok_recover else r5.splitlines()[0]}")
    return (ok_first and ok_replay and ok_recover and ok454), detail


TESTS = [
    ("T26", "无凭据 DESCRIBE/裸 PLAY → 401+Digest 质询", t26),
    ("T27", "带凭据全流程 200 + 6s 成帧", t27),
    ("T28", "错口令 → 401", t28),
    ("T29", "nonce 重放 → 401；无 SETUP 直 PLAY → 454", t29),
]
