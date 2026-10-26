#!/usr/bin/env python3
"""t02 控制面：免鉴权四连中的两条 + HTTP 语义（对齐 lab02 验收）。"""

import re

from ctx import board_get, soap_post

_S12 = ('<?xml version="1.0"?><s:Envelope '
        'xmlns:s="http://www.w3.org/2003/05/soap-envelope" '
        'xmlns:tds="http://www.onvif.org/ver10/device/wsdl">'
        '<s:Header><wsa:MessageID xmlns:wsa="http://www.w3.org/2005/08/addressing">'
        'urn:uuid:onvif-selftest-echo-1</wsa:MessageID></s:Header>'
        '<s:Body>{body}</s:Body></s:Envelope>')


def t02_devinfo(c):
    st, body = soap_post(c["host"], 80, "/onvif/device_service",
                         _S12.format(body="<tds:GetDeviceInformation/>"),
                         headers={"SOAPAction": '"http://www.onvif.org/ver10/device/wsdl/GetDeviceInformation"'})
    ok = st == 200 and "GetDeviceInformationResponse" in body and "Manufacturer" in body
    return ok, f"http={st}"


def t03_datetime(c):
    st, body = soap_post(c["host"], 80, "/onvif/device_service",
                         _S12.format(body="<tds:GetSystemDateAndTime/>"))
    ok = st == 200 and "SystemDateAndTime" in body and "UTCDateTime" in body
    return ok, f"http={st}"


def t04b_wsa(c):
    """T30: 请求带 wsa:MessageID（真 uuid4）→ 应答回 RelatesTo 回显 +
    自生成 MessageID（8-4-4-4-12 uuid 形态）+ wsa:Action（ONVIF Core §5.2）。"""
    import uuid
    mid = f"urn:uuid:{uuid.uuid4()}"
    st, body = soap_post(c["host"], 80, "/onvif/device_service",
                         _S12.format(body="<tds:GetDeviceInformation/>").replace(
                             "urn:uuid:onvif-selftest-echo-1", mid))
    echo = mid in body
    gen = re.search(r"<wsa:MessageID>urn:uuid:"
                    r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
                    r"</wsa:MessageID>", body)
    # Action 必须以【本次操作】的 Response 结尾（抓跨请求残留）
    act = re.search(r"<wsa:Action>[^<]*/GetDeviceInformationResponse</wsa:Action>",
                    body) is not None
    # 负例：未列白名单操作的 Fault 不得带 Action（陈旧残留探测）
    st2, fault = soap_post(c["host"], 80, "/onvif/device_service",
                           _S12.format(body="<tds:GetSystemLog/>"))
    no_stale = st2 == 500 and "<wsa:Action>" not in fault
    ok = st == 200 and echo and bool(gen) and act and no_stale
    return ok, (f"http={st} echo={'✓' if echo else '✗'} "
                f"gen-uuid={'✓' if gen else '✗'} action-suffix={'✓' if act else '✗'} "
                f"fault-clean={'✓' if no_stale else f'✗(Action残留?)'}")


def t04_405(c):
    try:
        st, _ = board_get(c["host"], "/onvif/device_service")
        return st == 405, f"GET http={st}"
    except Exception as e:
        if "405" in str(e):
            return True, "GET http=405"
        return False, str(e)


TESTS = [
    ("T02", "免鉴权 GetDeviceInformation", t02_devinfo),
    ("T03", "免鉴权 GetSystemDateAndTime", t03_datetime),
    ("T04", "GET SOAP 端点 → 405", t04_405),
    ("T30", "WS-Addressing MessageID 回显", t04b_wsa),
]
