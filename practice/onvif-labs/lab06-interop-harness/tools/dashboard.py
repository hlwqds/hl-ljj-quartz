#!/usr/bin/env python3
"""lab06 现代演示客户端：RTSP 视频流 + ONVIF 控制面 + 板端指标，一站式 dashboard。

依赖：/tmp/onvif-venv/bin/python（onvif-zeep 0.2.12 + pyserial）
      ffmpeg 在 PATH（~/.nix-profile/bin）
启动：/tmp/onvif-venv/bin/python tools/dashboard.py --host <板IP> --password <口令>
"""
import faulthandler
faulthandler.enable()

import argparse
import fcntl
import io
import json
import os
import subprocess
import termios
import threading
import time
import urllib.request
from http.server import ThreadingHTTPServer as HTTPServer, BaseHTTPRequestHandler

os.environ.pop("http_proxy", None)
os.environ.pop("https_proxy", None)
os.environ.pop("HTTP_PROXY", None)
os.environ.pop("HTTPS_PROXY", None)

ARGS = None
FFMPEG = os.path.expanduser("~/.nix-profile/bin/ffmpeg")
SERIAL_DEV = "/dev/ttyUSB0"

# ---- serial ----
import serial as pyserial_mod

_serial_port = None
_serial_lock = threading.Lock()

def serial_open():
    global _serial_port
    if _serial_port is not None:
        return
    try:
        _serial_port = pyserial_mod.Serial(SERIAL_DEV, 115200, timeout=1)
        _serial_port.rts = True
        time.sleep(0.1)
        _serial_port.rts = False
        time.sleep(8)
    except Exception as e:
        print(f"serial open failed (metrics disabled): {e}")
        _serial_port = None

def serial_cmd(cmd, wait=1.5):
    if _serial_port is None:
        return ""
    with _serial_lock:
        try:
            _serial_port.write((cmd + "\r\n").encode())
            time.sleep(wait)
            data = _serial_port.read(8192)
        except Exception:
            data = b""
    return data.decode("utf-8", "replace")

def serial_read_until(keyword, timeout_s=10):
    global _serial_port
    serial_open()
    end = time.time() + timeout_s
    buf = b""
    while time.time() < end:
        try:
            buf += _serial_port.read(4096)
        except Exception:
            pass
        text = buf.decode("utf-8", "replace")
        if keyword in text:
            return text
        time.sleep(0.2)
    return text

# ---- ONVIF SOAP ----
_cam = None  # ONVIFCamera 单例：复用连接，不每次 new

def _get_cam():
    global _cam
    if _cam is None:
        from onvif import ONVIFCamera
        _cam = ONVIFCamera(ARGS.host, ARGS.port, "admin", ARGS.password)
    return _cam

def soap_call(op, body_inner, password):
    cam = _get_cam()
    if op == "GetDeviceInformation":
        return cam.devicemgmt.GetDeviceInformation()
    elif op == "GetProfiles":
        media = cam.create_media_service()
        return media.GetProfiles()
    elif op == "GetServices":
        return cam.devicemgmt.GetServices(False)
    elif op == "GetSystemDateAndTime":
        return cam.devicemgmt.GetSystemDateAndTime()
    elif op == "GetStreamUri":
        media = cam.create_media_service()
        return media.GetStreamUri({"ProfileToken": "profile_1",
                                   "StreamSetup": {"Stream": "RTP-Unicast",
                                                    "Transport": {"Protocol": "RTSP"}}})
    elif op == "GetSnapshotUri":
        media = cam.create_media_service()
        return media.GetSnapshotUri({"ProfileToken": "profile_1"})
    return None

# ---- ffmpeg RTSP → MJPEG ----
_ff_proc = None
_ff_lock = threading.Lock()
_ff_frame = b""
_ff_event = threading.Event()

def ffmpeg_loop():
    global _ff_proc, _ff_frame
    url = f"rtsp://{ARGS.host}:8554/mjpeg"
    cmd = [FFMPEG, "-rtsp_transport", "tcp", "-i", url,
           "-f", "mpjpeg", "-q:v", "4", "-"]
    while True:
        try:
            _ff_proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
            buf = b""
            boundary = b"--"
            while True:
                chunk = _ff_proc.stdout.read(4096)
                if not chunk:
                    break
                buf += chunk
                # 找完整 JPEG（SOI…EOI）
                while True:
                    soi = buf.find(b"\xff\xd8")
                    eoi = buf.find(b"\xff\xd9", soi + 2) if soi >= 0 else -1
                    if soi >= 0 and eoi > soi:
                        frame = buf[soi:eoi + 2]
                        _ff_frame = frame
                        _ff_event.set()
                        buf = buf[eoi + 2:]
                    else:
                        break
        except Exception:
            pass
        time.sleep(2)  # 重连间隔

def start_ffmpeg():
    t = threading.Thread(target=ffmpeg_loop, daemon=True)
    t.start()

# ---- HTTP Handler ----
class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        path_only = self.path.split("?")[0]  # 剥 query（?ts=… 等 cache busting）
        if path_only == "/" or path_only == "/index.html":
            self.serve_html()
        elif path_only == "/video.mjpeg":
            self.serve_mjpeg()
        elif path_only == "/api/snapshot":
            self.proxy_board("/onvif-http/snapshot", "image/jpeg")
        elif path_only == "/api/info":
            self.api_info()
        elif path_only == "/api/profiles":
            self.api_profiles()
        elif path_only == "/api/stream_uri":
            self.api_stream_uri()
        elif path_only == "/api/status":
            self.api_status()
        elif path_only == "/api/datetime":
            self.api_datetime()
        else:
            self.send_response(404)
            self.end_headers()

    def serve_html(self):
        html = build_page().encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(html)))
        self.end_headers()
        self.wfile.write(html)

    def serve_mjpeg(self):
        try:
            self.send_response(200)
            self.send_header("Content-Type", "multipart/x-mixed-replace; boundary=frame")
            self.end_headers()
            while True:
                frame = _ff_frame
                if frame:
                    try:
                        self.wfile.write(b"--frame\r\nContent-Type: image/jpeg\r\n\r\n")
                        self.wfile.write(frame)
                        self.wfile.write(b"\r\n")
                        self.wfile.flush()
                    except (BrokenPipeError, ConnectionResetError, OSError):
                        return
                time.sleep(1 / 15)
        except Exception:
            return  # 客户端断开，不影响其他请求

    def proxy_board(self, path, ctype):
        # 剥 query（板端 httpd 按 URI 精确匹配，?ts=… 会导致 404）
        clean_path = path.split("?")[0]
        try:
            req = urllib.request.Request(f"http://{ARGS.host}:80{clean_path}")
            opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
            resp = opener.open(req, timeout=5)
            data = resp.read()
            self.send_response(200)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        except Exception as e:
            self.send_response(502)
            self.end_headers()
            self.wfile.write(str(e).encode())

    def api_info(self):
        try:
            info = soap_call("GetDeviceInformation", None, ARGS.password)
            d = {"Manufacturer": info.Manufacturer, "Model": info.Model,
                 "FirmwareVersion": info.FirmwareVersion,
                 "SerialNumber": info.SerialNumber, "HardwareId": info.HardwareId}
            self.json_ok(d)
        except Exception as e:
            self.json_err(str(e))

    def api_profiles(self):
        try:
            profiles = soap_call("GetProfiles", None, ARGS.password)
            plist = profiles if isinstance(profiles, list) else [profiles]
            out = [{"token": p.token, "name": p.Name,
                    "encoding": p.VideoEncoderConfiguration.Encoding,
                    "width": p.VideoEncoderConfiguration.Resolution.Width,
                    "height": p.VideoEncoderConfiguration.Resolution.Height} for p in plist]
            self.json_ok(out)
        except Exception as e:
            self.json_err(str(e))

    def api_stream_uri(self):
        try:
            uri = soap_call("GetStreamUri", None, ARGS.password)
            self.json_ok({"Uri": uri.Uri})
        except Exception as e:
            self.json_err(str(e))

    def api_datetime(self):
        try:
            sdt = soap_call("GetSystemDateAndTime", None, ARGS.password)
            utc = sdt.UTCDateTime
            self.json_ok({"DateTimeType": sdt.DateTimeType,
                          "UTC": f"{utc.Date.Year:04d}-{utc.Date.Month:02d}-{utc.Date.Day:02d}T"
                                 f"{utc.Time.Hour:02d}:{utc.Time.Minute:02d}:{utc.Time.Second:02d}Z"})
        except Exception as e:
            self.json_err(str(e))

    def api_status(self):
        out = serial_cmd("status", wait=1.5)
        lines = [l.strip() for l in out.splitlines() if "=" in l]
        d = dict(l.split("=", 1) for l in lines if "=" in l)
        self.json_ok(d)

    def json_ok(self, d):
        body = json.dumps(d, ensure_ascii=False).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def json_err(self, msg):
        body = json.dumps({"error": msg}).encode()
        self.send_response(500)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(body)

# ---- HTML ----
def build_page():
    return open(os.path.join(os.path.dirname(__file__), "dashboard.html"), encoding="utf-8").read()

# ---- main ----
def main():
    global ARGS
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", required=True)
    ap.add_argument("--port", type=int, default=80)
    ap.add_argument("--password", required=True)
    ap.add_argument("--listen", type=int, default=8080)
    ARGS = ap.parse_args()

    serial_open()
    start_ffmpeg()

    server = HTTPServer(("0.0.0.0", ARGS.listen), Handler)
    print(f"dashboard: http://0.0.0.0:{ARGS.listen}")
    print(f"  board: {ARGS.host}:{ARGS.port}")
    server.serve_forever()

if __name__ == "__main__":
    main()
