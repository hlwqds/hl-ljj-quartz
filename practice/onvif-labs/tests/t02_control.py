#!/usr/bin/env python3
"""t02 控制面：免鉴权四连中的两条 + HTTP 语义（对齐 lab02 验收）。"""

from ctx import board_get, soap_post

_S12 = ('<?xml version="1.0"?><s:Envelope '
        'xmlns:s="http://www.w3.org/2003/05/soap-envelope" '
        'xmlns:tds="http://www.onvif.org/ver10/device/wsdl">'
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
]
