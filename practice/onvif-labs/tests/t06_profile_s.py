#!/usr/bin/env python3
"""t06 Profile S 缺口操作集（CTT 最小实现补齐验证）。

覆盖 ONVIF Profile S MUST 清单中此前缺失的 8 操作 + 新操作鉴权门：
  T15 GetProfile(profile_1) 正路径          T16 GetProfile 未知 token → InvalidArgVal
  T17 GetVideoSourceConfigurations          T18 GetVideoSourceConfiguration(+负路径)
  T19 GetVideoEncoderConfigurations         T20 GetVideoEncoderConfiguration(+负路径)
  T21 GetVideoEncoderConfigurationOptions   T22 GetNetworkInterfaces（真实 MAC/IP）
  T23 GetScopes（与 ProbeMatch 三条一致）    T24 新操作免鉴权 → NotAuthorized

全部走 zeep（最严校验客户端）；依赖 venv onvif-zeep。
"""

import os
import re
import subprocess

from ctx import TOOLS_DIR

_PROBE = r'''
import sys
from onvif import ONVIFCamera
from onvif.exceptions import ONVIFError
from zeep.exceptions import Fault

cam = ONVIFCamera(sys.argv[1], 80, "admin", sys.argv[2])
dev = cam.devicemgmt
media = cam.create_media_service()

def out(tag, value):
    print(f"{tag}={value}", flush=True)

def call(tag, fn):
    """每操作独立容错：onvif-zeep 把 Fault 包成 ONVIFError，两者都要接住。"""
    try:
        return fn(), None
    except (Fault, ONVIFError) as e:
        return None, str(e)

def subcode_of(err):
    m = __import__("re").search(r"ter:\w+", err or "")
    return m.group(0) if m else ""

# onvif-zeep 0.2.12 sync 包装签名 (*args, **kwargs) 拒收关键字实参——
# 一律单 dict 位置传参（与 tools/onvif_smoke.py 同式）。

r, e = call("T15", lambda: media.GetProfile({"ProfileToken": "profile_1"}))
if r is not None:
    enc = r.VideoEncoderConfiguration.Encoding if r.VideoEncoderConfiguration else "NONE"
    out("T15_profile", f"token={r.token} enc={enc}")
else:
    out("T15_profile", f"FAULT {e}")

r, e = call("T16", lambda: media.GetProfile({"ProfileToken": "bogus"}))
out("T16_profile_bogus", "NO-FAULT" if r is not None
    else f"fault subcode={subcode_of(e)}")

r, e = call("T17", lambda: media.GetVideoSourceConfigurations())
if r is not None:
    c = r[0]
    out("T17_vsrcs", f"n={len(r)} token={c.token} bounds={c.Bounds.width}x{c.Bounds.height}")
else:
    out("T17_vsrcs", f"FAULT {e}")

r, e = call("T18", lambda: media.GetVideoSourceConfiguration({"ConfigurationToken": "vsc_1"}))
out("T18_vsrc", f"srctoken={r.SourceToken}" if r is not None else f"FAULT {e}")
r, e = call("T18b", lambda: media.GetVideoSourceConfiguration({"ConfigurationToken": "bogus"}))
out("T18_vsrc_bogus", "NO-FAULT" if r is not None
    else f"fault subcode={subcode_of(e)}")

r, e = call("T19", lambda: media.GetVideoEncoderConfigurations())
if r is not None:
    c = r[0]
    out("T19_vencs", f"n={len(r)} enc={c.Encoding} {c.Resolution.Width}x{c.Resolution.Height}")
else:
    out("T19_vencs", f"FAULT {e}")

r, e = call("T20", lambda: media.GetVideoEncoderConfiguration({"ConfigurationToken": "vec_1"}))
out("T20_venc", f"enc={r.Encoding} q={r.Quality}" if r is not None else f"FAULT {e}")
r, e = call("T20b", lambda: media.GetVideoEncoderConfiguration({"ConfigurationToken": "bogus"}))
out("T20_venc_bogus", "NO-FAULT" if r is not None
    else f"fault subcode={subcode_of(e)}")

r, e = call("T21", lambda: media.GetVideoEncoderConfigurationOptions())
if r is not None:
    j = r.JPEG  # zeep 4.3.3 对替换组抽象元素可能反序列化为 None——宿主侧限制
    if j is None:
        out("T21_opts", "zeep-substitution-None (由 T21 raw SOAP 判定)")
    else:
        out("T21_opts", f"jpeg=True fpsmax={j.FrameRateRange.Max} "
                        f"w={j.ResolutionsAvailable[0].Width}")
else:
    out("T21_opts", f"FAULT {e}")

r, e = call("T22", lambda: dev.GetNetworkInterfaces())
if r is not None:
    ni = r[0] if isinstance(r, list) else r
    hw = ni.Info.HwAddress if ni.Info else "?"
    addr = ni.IPv4.Config.Manual[0].Address if ni.IPv4 else "?"
    out("T22_netif", f"hw={hw} ip={addr}")
else:
    out("T22_netif", f"FAULT {e}")

r, e = call("T23", lambda: dev.GetScopes())
if r is not None:
    ss = r if isinstance(r, list) else r.Scopes  # onvif-zeep 对单重复元素解包成 list
    vals = []
    for s in ss:
        # 随包老 schema 的 Scope 用旧字段名 ScopeItem，现行规范是 ScopeXAddr；
        # 老字段名对不上时 zeep 把原文丢进 _raw_elements
        v = getattr(s, "ScopeXAddr", None) or getattr(s, "ScopeItem", None)
        if v is None:
            raw = getattr(s, "_raw_elements", [])
            v = raw[0].text if raw else ""
        vals.append(v or "")
    out("T23_scopes", f"n={len(vals)} streaming={'Profile/Streaming' in ' '.join(vals)}")
else:
    out("T23_scopes", f"FAULT {e}")
'''


def _probe(c):
    """跑探针脚本，收集 tag=value 行。异常/超时都返回空 dict + 错误串。"""
    if not c["venv"]:
        return {}, "无 onvif venv"
    try:
        r = subprocess.run([c["venv"], "-c", _PROBE, c["host"], c["password"]],
                           capture_output=True, text=True, timeout=90)
    except subprocess.TimeoutExpired:
        return {}, "zeep 探针 90s 超时（板子 httpd 挂死?）"
    if r.returncode != 0:
        tail = (r.stderr or r.stdout).splitlines()[-2:]
        return {}, f"rc={r.returncode} {' | '.join(tail)}"
    got = {}
    for ln in r.stdout.splitlines():
        if "=" in ln and not ln.startswith(("Traceback", "  ")):
            tag, _, val = ln.partition("=")
            got[tag] = val.strip()
    return got, ""


def _expect(got, key, cond, desc):
    if key not in got:
        return False, f"{key} 无证据"
    if cond(got[key]):
        return True, got[key]
    return False, f"{key}={got[key]}（期望 {desc}）"


def t15(c):
    got, err = _probe(c)
    if err:
        return False, err
    return _expect(got, "T15_profile", lambda v: "token=profile_1" in v and "enc=JPEG" in v,
                   "profile_1 + JPEG")


def t16(c):
    got, err = _probe(c)
    if err:
        return False, err
    return _expect(got, "T16_profile_bogus", lambda v: "InvalidArgVal" in v,
                   "InvalidArgVal")


def t17(c):
    got, err = _probe(c)
    if err:
        return False, err
    return _expect(got, "T17_vsrcs", lambda v: "640x480" in v, "640x480")


def t18(c):
    got, err = _probe(c)
    if err:
        return False, err
    ok1 = _expect(got, "T18_vsrc", lambda v: "srctoken=vs_1" in v, "vs_1")
    ok2 = _expect(got, "T18_vsrc_bogus", lambda v: "InvalidArgVal" in v, "InvalidArgVal")
    return (ok1[0] and ok2[0]), f"{ok1[1]}; {ok2[1]}"


def t19(c):
    got, err = _probe(c)
    if err:
        return False, err
    return _expect(got, "T19_vencs", lambda v: "enc=JPEG" in v and "640x480" in v,
                   "JPEG 640x480")


def t20(c):
    got, err = _probe(c)
    if err:
        return False, err
    ok1 = _expect(got, "T20_venc", lambda v: "enc=JPEG" in v, "JPEG")
    ok2 = _expect(got, "T20_venc_bogus", lambda v: "InvalidArgVal" in v, "InvalidArgVal")
    return (ok1[0] and ok2[0]), f"{ok1[1]}; {ok2[1]}"


def t21(c):
    """GetVideoEncoderConfigurationOptions：zeep 严格校验（Options 是具体类型，
    QualityRange 必填 IntRange + JPEG(JpegOptions)；板端模板必须 schema 合规才能解析出 .JPEG）。"""
    got, err = _probe(c)
    if err:
        return False, err
    return _expect(got, "T21_opts", lambda v: "jpeg=True" in v and "fpsmax=15" in v
                   and "w=640" in v, "JPEG + fps 15 + 640")


def t22(c):
    got, err = _probe(c)
    if err:
        return False, err
    v = got.get("T22_netif", "")
    if "FAULT" in v or "无证据" in v:
        return False, v
    m = re.search(r"hw=([0-9a-fA-F:]{17}) ip=(\S+)", v)
    if not m:
        return False, f"格式不符: {v}"
    return True, v


def t23(c):
    got, err = _probe(c)
    if err:
        return False, err
    return _expect(got, "T23_scopes", lambda v: "streaming=True" in v and "n=3" in v,
                   "3 scopes 含 Profile/Streaming")


def t24(c):
    """新操作免鉴权必须吃 NotAuthorized：拿 GetVideoEncoderConfigurations 打样。"""
    import http.client
    body = ('<?xml version="1.0"?><s:Envelope '
            'xmlns:s="http://www.w3.org/2003/05/soap-envelope" '
            'xmlns:trt="http://www.onvif.org/ver10/media/wsdl">'
            '<s:Body><trt:GetVideoEncoderConfigurations/></s:Body></s:Envelope>')
    conn = http.client.HTTPConnection(c["host"], 80, timeout=8)
    conn.request("POST", "/onvif/media_service", body=body,
                 headers={"Content-Type": "text/xml; charset=utf-8",
                          "SOAPAction": '"http://www.onvif.org/ver10/media/wsdl/'
                                        'GetVideoEncoderConfigurations"'})
    resp = conn.getresponse()
    data = resp.read().decode("utf-8", "replace")
    conn.close()
    ok = resp.status == 500 and "NotAuthorized" in data
    return ok, f"http={resp.status}"


TESTS = [
    ("T15", "GetProfile(profile_1) → JPEG", t15),
    ("T16", "GetProfile 未知 token → InvalidArgVal", t16),
    ("T17", "GetVideoSourceConfigurations → 640x480", t17),
    ("T18", "GetVideoSourceConfiguration 正/负路径", t18),
    ("T19", "GetVideoEncoderConfigurations → JPEG", t19),
    ("T20", "GetVideoEncoderConfiguration 正/负路径", t20),
    ("T21", "GetVideoEncoderConfigurationOptions → JPEG/15fps", t21),
    ("T22", "GetNetworkInterfaces → 真实 MAC/IP", t22),
    ("T23", "GetScopes → 与 ProbeMatch 一致", t23),
    ("T24", "新操作免鉴权 → NotAuthorized", t24),
]
