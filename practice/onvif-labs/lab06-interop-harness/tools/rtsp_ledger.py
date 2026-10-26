#!/usr/bin/env python3
"""lab05 RTSP 帧计数对账客户端（stdlib）：三本账的「抓包侧」账本。

完成 OPTIONS/DESCRIBE/SETUP(TCP interleaved=0-1)/PLAY 信令后，在指定窗口内解析
$ 交织 RTP 流，按「offset 0 起包 + M 位止包、同时间戳」计完整帧数（即时间戳去
重数，RFC 2435 成帧判据）。与板端 `$$$ ONVIF LAB05 FRAME` 标记行、ffmpeg 解码
帧数三本账互对。

用法：python3 tools/rtsp_ledger.py <板IP> [--seconds 12] [--port 8554]
"""

import argparse
import re
import socket
import time


def recv_response(sock, buf=bytearray(), timeout=5.0):
    """读一个 RTSP 应答（\r\n\r\n 止），返回 (应答文本, 剩余字节)。"""
    sock.settimeout(timeout)
    while b"\r\n\r\n" not in buf:
        chunk = sock.recv(65536)
        if not chunk:
            raise ConnectionError("connection closed")
        buf += chunk
    i = buf.find(b"\r\n\r\n") + 4
    return buf[:i].decode("utf-8", "replace"), buf[i:]


def main() -> int:
    ap = argparse.ArgumentParser(description="lab05 RTSP 帧计数账本")
    ap.add_argument("host")
    ap.add_argument("--port", type=int, default=8554)
    ap.add_argument("--seconds", type=float, default=12.0)
    ap.add_argument("--user", default=None, help="Digest 用户（缺省匿名，lab05 历史形态）")
    ap.add_argument("--password", dest="password", default=None)
    args = ap.parse_args()
    base = f"rtsp://{args.host}:{args.port}/mjpeg"

    sock = socket.create_connection((args.host, args.port), timeout=10)
    cseq = 0
    buf = bytearray()

    def rtsp(method: str, extra: str = "") -> str:
        nonlocal cseq
        cseq += 1
        sock.sendall(
            f"{method} {base} RTSP/1.0\r\nCSeq: {cseq}\r\n{extra}\r\n".encode()
        )
        resp, rest = recv_response(sock, buf)
        # 按 Content-Length 把 body 读满丢弃（SDP 等）——否则分段到达时残体
        # 留在内核队列，下一响应 head 会被拼上前体行（间歇性 flake 根因）
        m = re.search(r"Content-Length: (\d+)", resp)
        if m:
            need = int(m.group(1)) - len(rest)
            while need > 0:
                c = sock.recv(min(need, 4096))
                if not c:
                    break
                need -= len(c)
                rest += c
        buf.clear()  # 残体（交错帧）不进下一响应解析
        return resp

    print(rtsp("OPTIONS").splitlines()[0])

    def digest_resp(method: str, www_auth: str) -> str:
        """RFC 2617 无 qop 档：response=MD5(MD5(u:r:p):nonce:MD5(m:uri))"""
        import hashlib
        realm = re.search(r'realm="([^"]+)"', www_auth).group(1)
        nonce = re.search(r'nonce="([^"]+)"', www_auth).group(1)
        uri = base
        ha1 = hashlib.md5(f"{args.user}:{realm}:{args.password}".encode()).hexdigest()
        ha2 = hashlib.md5(f"{method}:{uri}".encode()).hexdigest()
        resp = hashlib.md5(f"{ha1}:{nonce}:{ha2}".encode()).hexdigest()
        return (
            f"Authorization: Digest username=\"{args.user}\", realm=\"{realm}\", "
            f'nonce="{nonce}", uri="{uri}", response="{resp}"\r\n'
        )

    describe = rtsp("DESCRIBE", "Accept: application/sdp\r\n")
    if describe.startswith("RTSP/1.0 401") and args.user:
        www = next((ln for ln in describe.splitlines()
                    if ln.lower().startswith("www-authenticate:")), "")
        print(describe.splitlines()[0])
        describe = rtsp("DESCRIBE",
                        "Accept: application/sdp\r\n" + digest_resp("DESCRIBE", www))
    print(describe.splitlines()[0])
    setup = rtsp("SETUP", "Transport: RTP/AVP/TCP;unicast;interleaved=0-1\r\n")
    print(setup.splitlines()[0])
    session = ""
    for line in setup.splitlines():
        if line.lower().startswith("session:"):
            session = line.split(":", 1)[1].split(";")[0].strip()
    print(rtsp("PLAY", f"Session: {session}\r\n").splitlines()[0])

    # ---- 12s 交织 RTP 成帧计数 ----
    complete = 0
    frames = {}
    end = time.time() + args.seconds
    sock.settimeout(1.0)
    while time.time() < end:
        try:
            chunk = sock.recv(65536)
        except socket.timeout:
            continue
        if not chunk:
            break
        buf.extend(chunk)
        while True:
            while buf and buf[0:1] != b"$":
                buf = buf[1:]  # 跳过混入流的零星字节（应答行尾等）
            if len(buf) < 4:
                break
            ln = int.from_bytes(buf[2:4], "big")
            if len(buf) < 4 + ln:
                break
            rtp = bytes(buf[4 : 4 + ln])
            del buf[: 4 + ln]
            if ln < 20:
                continue
            ts = int.from_bytes(rtp[4:8], "big")
            off = (rtp[13] << 16) | (rtp[14] << 8) | rtp[15]  # JPEG 头 fragment offset
            m_bit = bool(rtp[1] & 0x80)
            st = frames.setdefault(ts, {"start": False, "end": False})
            if off == 0:
                st["start"] = True
            if m_bit:
                st["end"] = True
            if st["start"] and st["end"] and not st.get("counted"):
                st["counted"] = True
                complete += 1

    print(
        f"$$$ HOST LAB06 RTSP LEDGER frames={complete} "
        f"window={args.seconds}s transport=TCP-interleaved",
        flush=True,
    )
    sock.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
