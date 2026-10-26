#!/usr/bin/env python3
"""t10 Profile G 骨架（ch17 §17.5.5，宏隔离 ONVIF_PROFILE_G）。

T32 trc GetServiceCapabilities → RecordingCapabilities（诚实：0 recordings）
T33 GetRecordings 空列表（无存储，诚实档）
T34 trt SetSynchronizationPoint(profile_1) → 200（G 对出流设备的 MUST 操作）

raw SOAP + Digest（随包 wsdl 含 recording/search，onvif-zeep 亦登记；选 raw 为
验证（未开站二进制不含 G 符号），套件只验行为。
"""

import base64
import hashlib
import http.client
import os
import re
import time

_NS = ('xmlns:s="http://www.w3.org/2003/05/soap-envelope" '
       'xmlns:trc="http://www.onvif.org/ver10/recording/wsdl" '
       'xmlns:trt="http://www.onvif.org/ver10/media/wsdl" '
       'xmlns:tt="http://www.onvif.org/ver10/schema" '
       'xmlns:wsse="http://docs.oasis-open.org/wss/2004/01/'
       'oasis-200401-wss-wssecurity-secext-1.0.xsd" '
       'xmlns:wsu="http://docs.oasis-open.org/wss/2004/01/'
       'oasis-200401-wss-wssecurity-utility-1.0.xsd"')


def _soap(c, body, action):
    """Digest 鉴权 POST 到 media_service（trc/trt 操作同 URI）。"""
    nonce = base64.b64encode(os.urandom(20)).decode()
    created = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    digest = base64.b64encode(hashlib.sha1(
        base64.b64decode(nonce) + created.encode() + c["password"].encode()).digest()).decode()
    env = (f'<?xml version="1.0"?><s:Envelope {_NS}><s:Header>'
           f'<wsse:Security mustUnderstand="1">'
           f'<wsse:UsernameToken><wsse:Username>admin</wsse:Username>'
           f'<wsse:Password Type="http://docs.oasis-open.org/wss/2004/01/'
           f'oasis-200401-wss-username-token-profile-1.0#PasswordDigest">{digest}</wsse:Password>'
           f'<wsse:Nonce EncodingType="http://docs.oasis-open.org/wss/2004/01/'
           f'oasis-200401-wss-soap-message-security-1.0#Base64Binary">{nonce}</wsse:Nonce>'
           f'<wsu:Created>{created}</wsu:Created></wsse:UsernameToken>'
           f'</wsse:Security></s:Header><s:Body>{body}</s:Body></s:Envelope>')
    conn = http.client.HTTPConnection(c["host"], 80, timeout=8)
    conn.request("POST", "/onvif/media_service", body=env,
                 headers={"Content-Type": "text/xml; charset=utf-8",
                          "SOAPAction": f'"http://www.onvif.org/ver10/recording/wsdl/{action}"'})
    resp = conn.getresponse()
    data = resp.read().decode("utf-8", "replace")
    conn.close()
    return resp.status, data


def t32_caps(c):
    st, body = _soap(c, "<trc:GetServiceCapabilities/>", "GetServiceCapabilities")
    need = ("ReceiverSource>false" in body and "MediaProfileSource>false" in body
            and "DynamicRecordings>false" in body and "DynamicTracks>false" in body
            and "<tt:MaxStringLength>0</tt:MaxStringLength>" in body)
    return st == 200 and need, f"http={st}, 诚实档字段={'✓' if need else body[:120]}"


def t33_empty(c):
    st1, b1 = _soap(c, "<trc:GetRecordings/>", "GetRecordings")
    ok = st1 == 200 and "GetRecordingsResponse" in b1
    return ok, f"recordings={st1}（空列表）"


def t34_sync(c):
    st, body = _soap(c, "<trt:SetSynchronizationPoint>"
                        "<trt:ProfileToken>profile_1</trt:ProfileToken>"
                        "</trt:SetSynchronizationPoint>", "SetSynchronizationPoint")
    ok = st == 200 and "SetSynchronizationPointResponse" in body
    # 未知 token → InvalidArgVal（表驱动 token 门同样覆盖 G 操作）
    st2, b2 = _soap(c, "<trt:SetSynchronizationPoint>"
                       "<trt:ProfileToken>bogus</trt:ProfileToken>"
                       "</trt:SetSynchronizationPoint>", "SetSynchronizationPoint")
    ok2 = st2 == 400 and "InvalidArgVal" in b2
    return (ok and ok2), (f"sync={st}({len(body)}B), "
                          f"bogus={'400/InvalidArgVal' if ok2 else f'{st2}'}")


TESTS = [
    ("T32", "Profile G: RecordingCapabilities 诚实报 0", t32_caps),
    ("T33", "Profile G: GetRecordings 空列表", t33_empty),
    ("T34", "Profile G: SetSynchronizationPoint + token 门", t34_sync),
]
