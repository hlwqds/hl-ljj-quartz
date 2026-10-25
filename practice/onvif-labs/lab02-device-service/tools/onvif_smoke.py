#!/usr/bin/env python3
"""lab02 宿主侧冒烟：python-onvif-zeep 逐操作 + 拒绝语义，双端原文留样。

设备端点 http://<host>:80/onvif/device_service（免鉴权四连；凭据仅填形参，
lab02 设备端不校验 s:Header）。每次 SOAP 交换由 zeep HistoryPlugin 抓取，
请求/应答原文落 runs/（<stem>.req.xml / <stem>.res.xml），与板端
`$$$ ONVIF LAB02 OP <name> ok` 标记行两账互对。

注意：构造 ONVIFCamera 本身就是零号用例——update_xaddrs() 在 __init__ 里
就会发 GetCapabilities({'Category': 'All'})（onvif-zeep 源码可见）；构造不抛
异常即该项已过。下面的 ④ 是同一操作的显式重放，为留样而发。

用法：
  python3 tools/onvif_smoke.py --host <板IP> [--port 80] [--outdir runs]

依赖（宿主）：python-onvif-zeep 0.2.12（pip install onvif-zeep，自带 zeep 4.3.3）。
"""

import argparse
import os
import sys

from lxml import etree
from onvif import ONVIFCamera
from onvif.exceptions import ONVIFError
from zeep.plugins import HistoryPlugin

TDS_NS = "http://www.onvif.org/ver10/device/wsdl"


def dump_exchange(hist: HistoryPlugin, outdir: str, stem: str) -> None:
    for side, msg in (("req", hist.last_sent), ("res", hist.last_received)):
        # zeep 4.3.3 HistoryPlugin 存 {"envelope": …, "http_headers": …}
        node = msg["envelope"] if isinstance(msg, dict) else msg
        data = (
            etree.tostring(node, pretty_print=True)
            if node is not None
            else b"(no exchange captured)\n"
        )
        with open(os.path.join(outdir, f"{stem}.{side}.xml"), "wb") as f:
            f.write(data)


def host_lab02(line: str) -> None:
    print(f"$$$ HOST LAB02 {line}", flush=True)


def bail(msg: str) -> None:
    print(f"SMOKE FAIL: {msg}", flush=True)
    raise SystemExit(1)


def main() -> int:
    ap = argparse.ArgumentParser(description="lab02 SOAP 控制面 zeep 冒烟")
    ap.add_argument("--host", required=True, help="板 IP（以板端 SVC READY 行为准）")
    ap.add_argument("--port", type=int, default=80)
    ap.add_argument("--user", default="admin")
    ap.add_argument("--password", default="admin")
    ap.add_argument("--outdir", default="runs")
    args = ap.parse_args()
    os.makedirs(args.outdir, exist_ok=True)

    hist = HistoryPlugin()
    # 零号用例：构造内部即发 GetCapabilities(Category=All)，答不好走不到下一行。
    cam = ONVIFCamera(args.host, args.port, args.user, args.password)
    cam.devicemgmt.zeep_client.plugins.append(hist)
    dev = cam.devicemgmt
    host_lab02("OP GetCapabilities(implicit-on-init) ok  # 零号用例：构造成功")

    # ① 对表（lab02 无 SNTP，DateTimeType 应诚实为 Manual）
    sdt = dev.GetSystemDateAndTime()
    dump_exchange(hist, args.outdir, "zeep-GetSystemDateAndTime")
    if getattr(sdt, "DateTimeType", None) != "Manual":
        bail(f"DateTimeType={sdt.DateTimeType!r} != Manual")
    utc = sdt.UTCDateTime
    host_lab02(
        "OP GetSystemDateAndTime ok  type=Manual utc="
        f"{utc.Date.Year:04d}-{utc.Date.Month:02d}-{utc.Date.Day:02d} "
        f"{utc.Time.Hour:02d}:{utc.Time.Minute:02d}:{utc.Time.Second:02d}"
    )

    # ② 身份五行
    info = dev.GetDeviceInformation()
    dump_exchange(hist, args.outdir, "zeep-GetDeviceInformation")
    five = ("Manufacturer", "Model", "FirmwareVersion", "SerialNumber", "HardwareId")
    vals = {k: getattr(info, k, None) for k in five}
    if any(not v for v in vals.values()):
        bail(f"GetDeviceInformation 缺字段: {vals}")
    if len(vals["SerialNumber"]) != 12:
        bail(f"SerialNumber 非_efuse MAC 六字节: {vals['SerialNumber']!r}")
    host_lab02("OP GetDeviceInformation ok  " + " ".join(f"{k}={v}" for k, v in vals.items()))

    expect_xaddr = f"http://{args.host}/onvif/device_service"

    # ③ 目录：只应有一条 Device 服务，XAddr 由请求 Host 头拼出（禁写死）
    svcs = dev.GetServices(False)
    # zeep 对单数组应答直接解为 list（无 GetServicesResponse 包装层）
    service_list = svcs if isinstance(svcs, list) else list(svcs.Service)
    dump_exchange(hist, args.outdir, "zeep-GetServices")
    if len(service_list) != 1:
        bail(f"Service 条目数 {len(service_list)} != 1")
    s0 = service_list[0]
    if s0.Namespace != TDS_NS:
        bail(f"Namespace {s0.Namespace!r} 非 Device 服务")
    if s0.XAddr != expect_xaddr:
        bail(f"XAddr {s0.XAddr!r} != Host 头拼出的 {expect_xaddr!r}")
    host_lab02(
        f"OP GetServices ok  n=1 ns=tds xaddr={s0.XAddr} "
        f"version={s0.Version.Major}.{s0.Version.Minor}"
    )

    # ④ 能力树（零号用例的显式重放，为留样）：只应长 Device 小节
    caps = dev.GetCapabilities({"Category": "All"})
    dump_exchange(hist, args.outdir, "zeep-GetCapabilities")
    known_sections = (
        "Device", "Media", "PTZ", "Events", "Analytics", "Extension", "Imaging",
        "Replay", "Receive", "Display", "Recording", "Search", "IODevice",
        "AnalyticsDevice", "RealTimeStreaming",
    )
    sections = {k for k in known_sections if getattr(caps, k, None) is not None}
    if sections != {"Device"}:
        bail(f"Capabilities 小节 {sorted(sections)} != ['Device']")
    if caps["Device"]["XAddr"] != expect_xaddr:
        bail(f"Device XAddr {caps['Device']['XAddr']!r} != {expect_xaddr!r}")
    host_lab02("OP GetCapabilities ok  sections=Device xaddr=" + caps["Device"]["XAddr"])

    # ⑤ 拒绝语义：白名单之外无特例 → env:Receiver + ter:ActionNotSupported
    try:
        dev.GetUsers()
        bail("GetUsers 未被拒绝")
    except ONVIFError as e:
        dump_exchange(hist, args.outdir, "fault-GetUsers")
        text = str(e)
        if "ActionNotSupported" not in text and "not supported" not in text.lower():
            bail(f"Fault 文案不含拒绝语义: {text!r}")
        host_lab02(f"FAULT GetUsers ok  reason={text!r}")

    host_lab02("SMOKE PASS 5/5 (四连 + Fault)，原文留样见 runs/")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
