#!/usr/bin/env python3
"""lab04 宿主侧冒烟：zeep 走 Media 双操作 + 快照二次验证。

media = cam.create_media_service()（xaddr 落默认模板 http://<ip>/onvif/media_service，
本板 GetCapabilities 只报 Device，媒体 xaddr 由客户端按定义模板回填）。
断言链：
  ① GetProfiles 过 lab03 鉴权门 → 恰好 1 个 profile：token=profile_1、JPEG、640×480；
  ② GetSnapshotUri(profile_1) → Uri == http://<host>/onvif-http/snapshot（Host 现拼）；
  ③ GET 该 Uri 落地 JPEG（FFD8 起 FFD9 止），字节数>0，存 runs/snap-zeep.jpg；
  ④ 未知 ProfileToken → ter:InvalidArgVal（Fault 留样）；
  ⑤ 免鉴权四连回归（GetDeviceInformation）。
HistoryPlugin 抓双端原文落 runs/（zeep-GetProfiles/zeep-GetSnapshotUri/…）。

用法：python3 tools/onvif_smoke.py --host <板IP> --password <口令> [--outdir runs]
依赖：/tmp/onvif-venv（onvif-zeep 0.2.12 + zeep 4.3.3）。
"""

import argparse
import os
import sys
import urllib.request

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
    ap = argparse.ArgumentParser(description="lab04 Media Profile 与快照 zeep 冒烟")
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
        print(f"$$$ HOST LAB04 {line}", flush=True)

    def bail(msg: str) -> None:
        print(f"SMOKE FAIL: {msg}", flush=True)
        raise SystemExit(1)

    # ① GetProfiles：单 profile、token/编码/分辨率逐项对账
    media = cam.create_media_service()
    media.zeep_client.plugins.append(hist)
    profiles = media.GetProfiles()
    dump_exchange(hist, args.outdir, "zeep-GetProfiles")
    plist = profiles if isinstance(profiles, list) else [profiles]
    if len(plist) != 1:
        bail(f"profiles n={len(plist)} != 1")
    p0 = plist[0]
    if p0.token != "profile_1":
        bail(f"token={p0.token!r} != 'profile_1'")
    vec = p0.VideoEncoderConfiguration
    if vec.Encoding != "JPEG" or vec.Resolution.Width != 640 or vec.Resolution.Height != 480:
        bail(f"encoding={vec.Encoding} res={vec.Resolution.Width}x{vec.Resolution.Height}")
    ok(
        f"OP GetProfiles ok  token={p0.token} name={p0.Name} "
        f"encoding={vec.Encoding} {vec.Resolution.Width}x{vec.Resolution.Height} "
        f"quality={vec.Quality} fps={vec.RateControl.FrameRateLimit}"
    )

    # ② GetSnapshotUri：Host 现拼
    uri = media.GetSnapshotUri({"ProfileToken": "profile_1"})
    dump_exchange(hist, args.outdir, "zeep-GetSnapshotUri")
    expect = f"http://{args.host}/onvif-http/snapshot"
    if uri.Uri != expect:
        bail(f"Uri={uri.Uri!r} != {expect!r}")
    ok(f"OP GetSnapshotUri ok  uri={uri.Uri}")

    # ③ 快照本体：GET 落地 JPEG（FFD8…FFD9）
    with urllib.request.urlopen(uri.Uri, timeout=10) as r:
        snap = r.read()
        ctype = r.headers.get("Content-Type", "")
    if not snap.startswith(b"\xff\xd8") or not snap.endswith(b"\xff\xd9"):
        bail(f"snapshot not a complete JPEG: {len(snap)}B ctype={ctype}")
    with open(os.path.join(args.outdir, "snap-zeep.jpg"), "wb") as f:
        f.write(snap)
    ok(f"SNAPSHOT ok  bytes={len(snap)} ctype={ctype} -> runs/snap-zeep.jpg")

    # ④ 未知 ProfileToken：ter:InvalidArgVal
    try:
        media.GetSnapshotUri({"ProfileToken": "no_such_profile"})
        bail("unknown ProfileToken 未被拒绝")
    except ONVIFError as e:
        dump_exchange(hist, args.outdir, "fault-GetSnapshotUri-unknown-token")
        if "InvalidArgVal" not in str(e):
            bail(f"Fault 不含 InvalidArgVal: {e!r}")
        ok(f"FAULT GetSnapshotUri(unknown token) ok  reason={e!r}")

    # ⑤ 免鉴权回归
    info = dev.GetDeviceInformation()
    ok(f"OP GetDeviceInformation ok  sn={info.SerialNumber}")

    ok("SMOKE PASS 5/5（Profile/Uri/JPEG/Fault/回归）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
