#!/usr/bin/env python3
"""t03 摘要门：正路径 + 三条负路径（对齐 lab03 验收矩阵的行 1/2/3/6）。

自含 WS-Security UsernameToken 摘要构造（stdlib），不依赖 zeep：
  B64(SHA1(nonce + created + password))
负路径覆盖：无凭据 / 错口令 / 重放（同 nonce+created 第二次）。
时钟漂移与 ghost-user 行留在 lab03 tools/onvif_auth_probe.py 的九行矩阵，不重复。
"""

import base64
import hashlib
import os
import uuid

from ctx import soap_post

_NS = ('xmlns:s="http://www.w3.org/2003/05/soap-envelope" '
       'xmlns:trt="http://www.onvif.org/ver10/media/wsdl" '
       'xmlns:wsse="http://docs.oasis-open.org/wss/2004/01/'
       'oasis-200401-wss-wssecurity-secext-1.0.xsd" '
       'xmlns:wsu="http://docs.oasis-open.org/wss/2004/01/'
       'oasis-200401-wss-wssecurity-utility-1.0.xsd"')


def _auth_header(user, password, created, nonce_b64=None):
    nonce = os.urandom(20)
    if nonce_b64:
        nonce = base64.b64decode(nonce_b64)
    else:
        nonce_b64 = base64.b64encode(nonce).decode()
    digest = base64.b64encode(
        hashlib.sha1(nonce + created.encode() + password.encode()).digest()).decode()
    tok = (f'<wsse:UsernameToken><wsse:Username>{user}</wsse:Username>'
           f'<wsse:Password Type="http://docs.oasis-open.org/wss/2004/01/'
           f'oasis-200401-wss-username-token-profile-1.0#PasswordDigest">{digest}</wsse:Password>'
           f'<wsse:Nonce EncodingType="http://docs.oasis-open.org/wss/2004/01/'
           f'oasis-200401-wss-soap-message-security-1.0#Base64Binary">{nonce_b64}</wsse:Nonce>'
           f'<wsu:Created>{created}</wsu:Created></wsse:UsernameToken>')
    return (f'<?xml version="1.0"?><s:Envelope {_NS}><s:Header>'
            f'<wsse:Security mustUnderstand="1">{tok}</wsse:Security></s:Header>'
            f'<s:Body><trt:GetProfiles/></s:Body></s:Envelope>')


def _created_now():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


import time  # noqa: E402


def t05_auth_ok(c):
    st, body = soap_post(c["host"], 80, "/onvif/media_service",
                         _auth_header("admin", c["password"], _created_now()),
                         headers={"SOAPAction": '"http://www.onvif.org/ver10/media/wsdl/GetProfiles"'})
    ok = st == 200 and "profile_1" in body
    return ok, f"http={st}"


def t06_no_creds(c):
    body = (f'<?xml version="1.0"?><s:Envelope {_NS}>'
            f'<s:Body><trt:GetProfiles/></s:Body></s:Envelope>')
    st, body = soap_post(c["host"], 80, "/onvif/media_service", body)
    ok = st == 500 and "NotAuthorized" in body
    return ok, f"http={st}"


def t07_wrong_pass(c):
    st, body = soap_post(c["host"], 80, "/onvif/media_service",
                         _auth_header("admin", c["password"] + "x", _created_now()))
    ok = st == 500 and "NotAuthorized" in body
    return ok, f"http={st}"


def t08_replay(c):
    created, nonce = _created_now(), None
    # 同一 nonce+created 发两次：第二次必被 nonce 环挡下
    env = _auth_header("admin", c["password"], created)
    st1, _ = soap_post(c["host"], 80, "/onvif/media_service", env)
    st2, body2 = soap_post(c["host"], 80, "/onvif/media_service", env)
    ok = st1 == 200 and st2 == 500 and "NotAuthorized" in body2
    return ok, f"first={st1} replay={st2}"


TESTS = [
    ("T05", "摘要门正路径 GetProfiles → 200", t05_auth_ok),
    ("T06", "无凭据 GetProfiles → NotAuthorized", t06_no_creds),
    ("T07", "错口令 → NotAuthorized", t07_wrong_pass),
    ("T08", "同 nonce 重放 → NotAuthorized", t08_replay),
]
