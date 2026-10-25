#!/usr/bin/env python3
"""lab03 原声探针（stdlib）：nonce/Created/摘要三原料全可控，喂九行坏 case 矩阵。

启动自检：ch04 4.2 验收向量按规范字节观复算——头里的 Nonce 是 base64
（TEtLMHdpOWNRM1ptdlFwMg== = 16 字节可打印 ASCII "LKK0wi9cQ3ZmvQp2"），
摘要 = Base64(SHA1(b64decode(Nonce) + Created + Password))
= yN+RxcHPSx2u50AcC/obCm/0zIQ=。算不出就退出，不发报文。

时钟默认按板钟对表（免鉴权 GetSystemDateAndTime → 计算偏移，ch09 坑 1 治标）；
--host-clock 改按宿主钟（不补偿，漂移现场复现用）。

用法（板 IP 以板端日志为准，DHCP 会变）：
  python3 tools/onvif_auth_probe.py <板IP> --op GetUsers                    # 正向（默认对表）
  python3 tools/onvif_auth_probe.py <板IP> --no-auth                        # 不带安全头
  python3 tools/onvif_auth_probe.py <板IP> --pass wrong                     # 错口令
  python3 tools/onvif_auth_probe.py <板IP> --user ghost                     # 错用户名
  python3 tools/onvif_auth_probe.py <板IP> --nonce-as-text                  # ch04 4.2 字节坑
  python3 tools/onvif_auth_probe.py <板IP> --replay 2                       # 同一报文连发两次
  python3 tools/onvif_auth_probe.py <板IP> --host-clock                     # Created 按宿主钟
原文留样：runs/auth-probe-<case>.req.xml / .res[.N].xml
"""

import argparse
import base64
import datetime
import hashlib
import http.client
import os
import re
import sys

VECTOR_NONCE_B64 = "TEtLMHdpOWNRM1ptdlFwMg=="  # = b64("LKK0wi9cQ3ZmvQp2")
VECTOR_CREATED = "2026-10-10T12:00:00.000Z"
VECTOR_PASS = "onvif-demo-pass"
VECTOR_DIGEST = "yN+RxcHPSx2u50AcC/obCm/0zIQ="

SOAP11_ENV = "http://schemas.xmlsoap.org/soap/envelope/"
TDS_NS = "http://www.onvif.org/ver10/device/wsdl"
WSSE_NS = (
    "http://docs.oasis-open.org/wss/2004/01/"
    "oasis-200401-wss-wssecurity-secext-1.0.xsd"
)
WSU_NS = (
    "http://docs.oasis-open.org/wss/2004/01/"
    "oasis-200401-wss-wssecurity-utility-1.0.xsd"
)


def self_check() -> None:
    raw = base64.b64decode(VECTOR_NONCE_B64)
    got = base64.b64encode(
        hashlib.sha1(raw + VECTOR_CREATED.encode() + VECTOR_PASS.encode()).digest()
    ).decode()
    if got != VECTOR_DIGEST:
        print(f"SELF-CHECK FAIL: {got} != {VECTOR_DIGEST}")
        raise SystemExit(2)


def digest_of(nonce_raw: bytes, created: str, password: str, nonce_as_text: bool) -> str:
    """摘要原料字节观：默认用解码后 nonce 字节；--nonce-as-text 故意用 base64 文本
    （ch04 4.2 字节坑复现），设备侧重算必不匹配。"""
    nonce_part = (
        base64.b64encode(nonce_raw) if nonce_as_text else nonce_raw
    )  # 字节坑分支：把 base64 文本的 bytes 当原料
    return base64.b64encode(
        hashlib.sha1(nonce_part + created.encode() + password.encode()).digest()
    ).decode()


def board_epoch_offset(host: str, port: int) -> int:
    """免鉴权 GetSystemDateAndTime 对表：返回 板钟epoch - 宿主epoch。"""
    body = (
        '<?xml version="1.0" encoding="utf-8"?>'
        f'<s:Envelope xmlns:s="{SOAP11_ENV}" xmlns:tds="{TDS_NS}">'
        "<s:Body><tds:GetSystemDateAndTime/></s:Body></s:Envelope>"
    )
    conn = http.client.HTTPConnection(host, port, timeout=10)
    conn.request(
        "POST",
        "/onvif/device_service",
        body=body,
        headers={"Content-Type": "text/xml; charset=utf-8", "SOAPAction": '"GetSystemDateAndTime"'},
    )
    resp = conn.getresponse()
    data = resp.read().decode("utf-8", "replace")
    conn.close()
    m = {k: int(re.search(f"<tt:{k}>(-?\\d+)</tt:{k}>", data).group(1)) for k in
         ("Year", "Month", "Day", "Hour", "Minute", "Second")}
    board = datetime.datetime(
        m["Year"], m["Month"], m["Day"], m["Hour"], m["Minute"], m["Second"],
        tzinfo=datetime.timezone.utc,
    ).timestamp()
    return int(board - datetime.datetime.now(datetime.timezone.utc).timestamp())


def build_request(op: str, user: str, nonce_raw: bytes, created: str,
                  password: str, nonce_as_text: bool, with_auth: bool) -> str:
    ns_extra = "" if not with_auth else (
        f"\n            xmlns:wsse=\"{WSSE_NS}\" xmlns:wsu=\"{WSU_NS}\""
    )  # 不带安全头时连命名空间声明一并去掉（报文干净 + 设备端 no_token 分因可判）
    header = ""
    if with_auth:
        header = (
            "  <s:Header>\n"
            "    <wsse:Security>\n"
            "      <wsse:UsernameToken>\n"
            f"        <wsse:Username>{user}</wsse:Username>\n"
            '        <wsse:Password Type="http://docs.oasis-open.org/wss/2004/01/'
            'oasis-200401-wss-username-token-profile-1.0#PasswordDigest">'
            f"{digest_of(nonce_raw, created, password, nonce_as_text)}</wsse:Password>\n"
            '        <wsse:Nonce EncodingType="http://docs.oasis-open.org/wss/2004/01/'
            f'oasis-200401-wss-soap-message-security-1.0#Base64Binary">'
            f"{base64.b64encode(nonce_raw).decode()}</wsse:Nonce>\n"
            f"        <wsu:Created>{created}</wsu:Created>\n"
            "      </wsse:UsernameToken>\n"
            "    </wsse:Security>\n"
            "  </s:Header>\n"
        )
    return (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        f'<s:Envelope xmlns:s="{SOAP11_ENV}" xmlns:tds="{TDS_NS}"'
        f"{ns_extra}>\n"
        f"{header}"
        f"  <s:Body>\n    <tds:{op}/>\n  </s:Body>\n</s:Envelope>\n"
    )


def send(host: str, port: int, op: str, body: str) -> tuple[int, str, str]:
    conn = http.client.HTTPConnection(host, port, timeout=10)
    conn.request(
        "POST",
        "/onvif/device_service",
        body=body,
        headers={"Content-Type": "text/xml; charset=utf-8",
                 "SOAPAction": f'"http://www.onvif.org/ver10/device/wsdl/{op}"'},
    )
    resp = conn.getresponse()
    data = resp.read().decode("utf-8", "replace")
    conn.close()
    if "NotAuthorized" in data:
        verdict = "DENY ter:NotAuthorized"
    elif "ActionNotSupported" in data:
        verdict = "DENY ter:ActionNotSupported"
    elif f"{op}Response" in data:
        verdict = "OK"
    else:
        verdict = "UNEXPECTED"
    return resp.status, verdict, data


def main() -> int:
    ap = argparse.ArgumentParser(description="lab03 WS-Security 原声探针")
    ap.add_argument("host")
    ap.add_argument("--port", type=int, default=80)
    ap.add_argument("--op", default="GetUsers")
    ap.add_argument("--user", default="admin")
    ap.add_argument("--pass", dest="password", required=True,
                    help="口令（与 main/onvif_secrets.h 的 ONVIF_AUTH_PASS 一致）")
    ap.add_argument("--no-auth", action="store_true")
    ap.add_argument("--nonce-as-text", action="store_true")
    ap.add_argument("--host-clock", action="store_true")
    ap.add_argument("--replay", type=int, default=1)
    ap.add_argument("--tag", default="",
                    help="case 名追加区分位（如 --tag skew-redo），避免同 flag 组合的留样互相覆盖")
    ap.add_argument("--outdir", default="runs")
    args = ap.parse_args()
    self_check()
    os.makedirs(args.outdir, exist_ok=True)

    offset = 0 if args.host_clock else board_epoch_offset(args.host, args.port)
    mode = "host-clock" if args.host_clock else "board-sync"
    created = (
        datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(seconds=offset)
    ).strftime("%Y-%m-%dT%H:%M:%SZ")
    nonce_raw = os.urandom(16)
    body = build_request(args.op, args.user, nonce_raw, created, args.password,
                         args.nonce_as_text, not args.no_auth)

    case = args.op.lower()
    if args.no_auth:
        case += "-noauth"
    if args.password == "wrongpass":
        case += "-wrongpass"  # 按值判名：--pass 传真口令时不得误标
    if args.user == "ghost":
        case += "-ghost"
    if args.nonce_as_text:
        case += "-bytewrong"
    if args.host_clock:
        case += "-hostclock"
    case += f"-{mode}"
    if args.tag:
        case += f"-{args.tag}"

    print(f"$$$ HOST LAB03 AUTH probe case={case} created={created} mode={mode}", flush=True)
    with open(os.path.join(args.outdir, f"auth-probe-{case}.req.xml"), "w") as f:
        f.write(body)

    for i in range(max(1, args.replay)):
        status, verdict, data = send(args.host, args.port, args.op, body)
        res_path = os.path.join(args.outdir, f"auth-probe-{case}.res.xml" if args.replay <= 1
                                else f"auth-probe-{case}.res.{i + 1}.xml")
        with open(res_path, "w") as f:
            f.write(data)
        print(f"$$$ HOST LAB03 AUTH probe send#{i + 1} http={status} -> {verdict}", flush=True)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
