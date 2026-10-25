#!/usr/bin/env python3
"""SOAP 1.1 壳手工探针（stdlib）：双壳验收的第二条腿。

python-onvif-zeep 只走 1.2 绑定；本脚本手搓 1.1（text/xml + SOAPAction 头）
验证存量兼容底座：白名单内回 1.1 信封（Content-Type text/xml; charset=utf-8、
HTTP 200），白名单外回 faultcode s:Receiver + ter:ActionNotSupported 文案
（HTTP 500），GET 端点回 405。请求/应答原文落 runs/。

用法：python3 tools/soap11_probe.py --host <板IP> [--outdir runs]
"""

import argparse
import http.client
import os

ENV = """<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"
            xmlns:tds="http://www.onvif.org/ver10/device/wsdl">
  <s:Body>
    <tds:{op}/>
  </s:Body>
</s:Envelope>
"""


def post(host: str, port: int, op: str, outdir: str, stem: str) -> str:
    body = ENV.format(op=op)
    conn = http.client.HTTPConnection(host, port, timeout=10)
    conn.request(
        "POST",
        "/onvif/device_service",
        body=body,
        headers={
            "Content-Type": "text/xml; charset=utf-8",
            "SOAPAction": f'"http://www.onvif.org/ver10/device/wsdl/{op}"',
        },
    )
    resp = conn.getresponse()
    data = resp.read()
    conn.close()
    with open(os.path.join(outdir, f"{stem}.req.xml"), "w") as f:
        f.write(body)
    with open(os.path.join(outdir, f"{stem}.res.xml"), "wb") as f:
        f.write(data)
    text = data.decode("utf-8", "replace")
    ctype = resp.getheader("Content-Type") or ""
    print(
        f"$$$ HOST LAB02 SOAP11 {op} http={resp.status} ctype={ctype} bytes={len(data)}",
        flush=True,
    )
    return text


def main() -> int:
    ap = argparse.ArgumentParser(description="SOAP 1.1 壳手工探针")
    ap.add_argument("--host", required=True)
    ap.add_argument("--port", type=int, default=80)
    ap.add_argument("--outdir", default="runs")
    args = ap.parse_args()
    os.makedirs(args.outdir, exist_ok=True)

    # ① 1.1 正常路径：身份五行（XAddr 在 GetServices/GetCapabilities，见 ①b）
    text = post(args.host, args.port, "GetDeviceInformation", args.outdir, "soap11-GetDeviceInformation")
    if "Espressif" not in text or "ESP32-S31-Korvo-1" not in text:
        print("SOAP11 FAIL: 身份字段缺失")
        return 1
    print("$$$ HOST LAB02 SOAP11 GetDeviceInformation ok  # 1.1 信封 + 身份五行")

    # ①b GetServices：XAddr 须按 Host 头回板 IP（禁写死）
    text = post(args.host, args.port, "GetServices", args.outdir, "soap11-GetServices")
    expect = f"http://{args.host}/onvif/device_service"
    if expect not in text:
        print(f"SOAP11 FAIL: XAddr 未按 Host 头回 {expect}")
        return 1
    print(f"$$$ HOST LAB02 SOAP11 GetServices ok  xaddr={expect}  # Host 回拼")

    # ② 1.1 拒绝路径：faultcode s:Receiver + faultstring 带 ter:ActionNotSupported
    text = post(args.host, args.port, "GetUsers", args.outdir, "soap11-fault-GetUsers")
    if "Receiver" not in text or "ActionNotSupported" not in text:
        print("SOAP11 FAIL: 1.1 Fault 缺 Receiver/ActionNotSupported 语义")
        return 1
    print("$$$ HOST LAB02 SOAP11 FAULT GetUsers ok  # faultcode/faultstring 两件套")

    # ③ GET 端点：不吐 WSDL，回 405（ch03 §3.3 纪律）
    conn = http.client.HTTPConnection(args.host, args.port, timeout=10)
    conn.request("GET", "/onvif/device_service")
    resp = conn.getresponse()
    data = resp.read()
    conn.close()
    print(f"$$$ HOST LAB02 SOAP11 GET http={resp.status}  # 期望 405")
    if resp.status != 405:
        print(f"SOAP11 FAIL: GET 回 {resp.status} 而非 405")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
