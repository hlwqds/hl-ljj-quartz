#!/usr/bin/env python3
"""lab05 RTSP 帧计数对账客户端（stdlib）：三本账的「抓包侧」账本。

完成 OPTIONS/DESCRIBE/SETUP(TCP interleaved=0-1)/PLAY 信令后，在指定窗口内解析
$ 交织 RTP 流，按「offset 0 起包 + M 位止包、同时间戳」计完整帧数（即时间戳去
重数，RFC 2435 成帧判据）。与板端 `$$$ ONVIF LAB05 FRAME` 标记行、ffmpeg 解码
帧数三本账互对。

用法：python3 tools/rtsp_ledger.py <板IP> [--seconds 12] [--port 8554]
"""

import argparse
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
        buf.clear()
        buf.extend(rest)
        return resp

    print(rtsp("OPTIONS").splitlines()[0])
    print(rtsp("DESCRIBE", "Accept: application/sdp\r\n").splitlines()[0])
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
        f"$$$ HOST LAB05 RTSP LEDGER frames={complete} "
        f"window={args.seconds}s transport=TCP-interleaved",
        flush=True,
    )
    sock.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
