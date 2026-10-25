#!/usr/bin/env python3
"""lab03 正向基线（矩阵 #1）：python-onvif-zeep 带凭据过鉴权门。

ONVIFCamera(…, user, pass) 的 wsse=UsernameDigestTokenDtDiff 每发自动带
PasswordDigest 头（Created 按宿主钟，SNTP 开时设备钟≈宿主钟，±300s 窗内）。
断言：GetUsers 过鉴权门返回单条 admin（Administrator）；免鉴权四连不受影响。

用法：python3 tools/onvif_smoke.py --host <板IP> [--outdir runs]
依赖：/tmp/onvif-venv（onvif-zeep 0.2.12 + zeep 4.3.3）。
"""

import argparse
import os
import sys

from lxml import etree
from onvif import ONVIFCamera
from onvif.exceptions import ONVIFError
from zeep.plugins import HistoryPlugin


def dump_exchange(hist: HistoryPlugin, outdir: str, stem: str) -> None:
    for side, msg in (("req", hist.last_sent), ("res", hist.last_received)):
        node = msg["envelope"] if isinstance(msg, dict) else msg
        data = (
            etree.tostring(node, pretty_print=True)
            if node is not None
            else b"(no exchange captured)\n"
        )
        with open(os.path.join(outdir, f"{stem}.{side}.xml"), "wb") as f:
            f.write(data)


def main() -> int:
    ap = argparse.ArgumentParser(description="lab03 zeep 正向冒烟（带凭据）")
    ap.add_argument("--host", required=True)
    ap.add_argument("--port", type=int, default=80)
    ap.add_argument("--user", default="admin")
    ap.add_argument("--password", required=True)
    ap.add_argument("--outdir", default="runs")
    args = ap.parse_args()
    os.makedirs(args.outdir, exist_ok=True)

    hist = HistoryPlugin()
    cam = ONVIFCamera(args.host, args.port, args.user, args.password)
    dev = cam.devicemgmt
    dev.zeep_client.plugins.append(hist)

    def ok(line: str) -> None:
        print(f"$$$ HOST LAB03 {line}", flush=True)

    # 矩阵 #1：GetUsers 过鉴权门（Created 按宿主钟，SNTP 开 → 双方钟都准）
    users = dev.GetUsers()
    dump_exchange(hist, args.outdir, "zeep-GetUsers")
    user_list = users if isinstance(users, list) else list(users.User)
    if len(user_list) != 1:
        print(f"SMOKE FAIL: users n={len(user_list)} != 1")
        return 1
    u0 = user_list[0]
    if u0.Username != args.user or u0.UserLevel != "Administrator":
        print(f"SMOKE FAIL: user={u0.Username!r} level={u0.UserLevel!r}")
        return 1
    ok(f"AUTH zeep GetUsers ok  user={u0.Username} level={u0.UserLevel}")

    # 免鉴权四连不受影响（带凭据请求一样放行）
    sdt = dev.GetSystemDateAndTime()
    dump_exchange(hist, args.outdir, "zeep-GetSystemDateAndTime")
    utc = sdt.UTCDateTime
    ok(
        "OP GetSystemDateAndTime ok  type="
        f"{sdt.DateTimeType} utc={utc.Date.Year:04d}-{utc.Date.Month:02d}-"
        f"{utc.Date.Day:02d} {utc.Time.Hour:02d}:{utc.Time.Minute:02d}:{utc.Time.Second:02d}"
    )

    info = dev.GetDeviceInformation()
    ok(f"OP GetDeviceInformation ok  sn={info.SerialNumber} fw={info.FirmwareVersion}")

    ok("SMOKE PASS #1 正向基线（zeep 带凭据过门）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
