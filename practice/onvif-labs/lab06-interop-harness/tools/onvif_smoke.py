#!/usr/bin/env python3
"""lab05 宿主侧冒烟：zeep 走 GetStreamUri（过 lab03 摘要门）+ 未知 token Fault + 回归。

断言链：
  ① GetStreamUri(profile_1) → Uri == rtsp://<host>:8554/mjpeg（Host 现拼）；
  ② 未知 ProfileToken → ter:InvalidArgVal（Fault 留样）；
  ③ GetProfiles 回归（单 profile 仍在）；免鉴权四连回归。

用法：python3 tools/onvif_smoke.py --host <板IP> --password <口令> [--outdir runs]
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
    ap = argparse.ArgumentParser(description="lab05 GetStreamUri zeep 冒烟")
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
    media = cam.create_media_service()
    media.zeep_client.plugins.append(hist)

    def ok(line: str) -> None:
        print(f"\$\$\$ HOST LAB06 {line}", flush=True)

    def bail(msg: str) -> None:
        print(f"SMOKE FAIL: {msg}", flush=True)
        raise SystemExit(1)

    # ① GetStreamUri：WSDL 要求 StreamSetup 结构（嵌套 dict 由 zeep 渲染）
    uri = media.GetStreamUri(
        {
            "ProfileToken": "profile_1",
            "StreamSetup": {
                "Stream": "RTP-Unicast",
                "Transport": {"Protocol": "RTSP"},
            },
        }
    )
    dump_exchange(hist, args.outdir, "zeep-GetStreamUri")
    expect = f"rtsp://{args.host}:8554/mjpeg"
    if uri.Uri != expect:
        bail(f"Uri={uri.Uri!r} != {expect!r}")
    ok(f"OP GetStreamUri ok  uri={uri.Uri}")

    # ② 未知 ProfileToken：ter:InvalidArgVal
    try:
        media.GetStreamUri(
            {
                "ProfileToken": "no_such_profile",
                "StreamSetup": {
                    "Stream": "RTP-Unicast",
                    "Transport": {"Protocol": "RTSP"},
                },
            }
        )
        bail("unknown ProfileToken 未被拒绝")
    except ONVIFError as e:
        dump_exchange(hist, args.outdir, "fault-GetStreamUri-unknown-token")
        if "InvalidArgVal" not in str(e):
            bail(f"Fault 不含 InvalidArgVal: {e!r}")
        ok(f"FAULT GetStreamUri(unknown token) ok  reason={e!r}")

    # ③ 回归：单 profile + 免鉴权四连
    profiles = media.GetProfiles()
    plist = profiles if isinstance(profiles, list) else [profiles]
    if len(plist) != 1 or plist[0].token != "profile_1":
        bail(f"profiles 异常: {[p.token for p in plist]}")
    ok("OP GetProfiles ok  token=profile_1")
    info = dev.GetDeviceInformation()
    ok(f"OP GetDeviceInformation ok  sn={info.SerialNumber}")

    ok("SMOKE PASS 3/3（GetStreamUri / Fault / 回归）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
