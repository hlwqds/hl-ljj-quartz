#!/usr/bin/env python3
"""lab06 现代 ONVIF 客户端：WebSocket 实时流 + ONVIF 控制面 + 板端指标。

架构：
  浏览器 ←WebSocket binary (JPEG frames ~15fps)← ffmpeg subprocess ← RTSP :8554
  浏览器 ←REST JSON (device info / profiles / metrics)← ONVIF SOAP :80 + serial

依赖：ha-venv（aiohttp, websockets, onvif-zeep-async）
启动：/home/huanglin/ha-venv/bin/python tools/onvif_app.py --host <板IP> --password <口令>
"""

import argparse
from urllib.parse import quote
import asyncio
import json
import os
import subprocess
import time

os.environ.pop("http_proxy", None)
os.environ.pop("https_proxy", None)
os.environ.pop("HTTP_PROXY", None)
os.environ.pop("HTTPS_PROXY", None)

from aiohttp import web, WSMsgType

ARGS = None
FFMPEG = os.path.expanduser("~/.nix-profile/bin/ffmpeg")

HTML = """<!DOCTYPE html>
<html lang="zh"><head><meta charset="utf-8"><title>ONVIF Lab06</title>
<style>
:root{--bg:#0d1117;--card:#161b22;--border:#30363d;--text:#c9d1d9;--accent:#58a6ff;--green:#3fb950;--dim:#8b949e}
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:-apple-system,'Segoe UI',Roboto,monospace;background:var(--bg);color:var(--text);padding:16px}
.h{display:flex;align-items:center;gap:10px;margin-bottom:14px}
.h h1{font-size:1.2em;color:var(--accent)}
.dot{width:10px;height:10px;border-radius:50%;background:var(--green);animation:pulse 1.5s infinite}
@keyframes pulse{50%{opacity:.4}}
.badge{padding:3px 10px;border-radius:12px;font-size:.75em;font-weight:bold}
.badge.live{background:#1a3a2a;color:var(--green)}
.badge.err{background:#3a1a1a;color:var(--red)}
.grid{display:grid;grid-template-columns:1fr 320px;gap:14px;max-width:1280px}
@media(max-width:900px){.grid{grid-template-columns:1fr}}
.card{background:var(--card);border:1px solid var(--border);border-radius:8px;padding:14px}
.card h2{font-size:.8em;color:var(--dim);text-transform:uppercase;letter-spacing:1px;margin-bottom:10px}
canvas{width:100%;border-radius:6px;display:block;background:#000}
.row{display:flex;justify-content:space-between;padding:5px 0;border-bottom:1px solid var(--border)}
.row .k{color:var(--dim)}
.row .v{font-family:monospace;color:var(--accent)}
.fps-big{font-size:2em;font-weight:bold;color:var(--green);text-align:center;padding:10px}
.sub{font-size:.7em;color:var(--dim);text-align:center}
</style></head><body>
<div class="h"><div class="dot" id="dot"></div><h1>ONVIF Lab06</h1><span class="badge err" id="badge">CONNECTING</span></div>
<div class="grid">
<div>
  <div class="card"><h2>Live Stream — RTSP → WebSocket</h2><canvas id="cv" width="640" height="480"></canvas>
  <div class="fps-big"><span id="fps-val">0</span> fps<div class="sub">WebSocket binary push</div></div></div>
</div>
<div>
  <div class="card"><h2>Device</h2><div id="dev">—</div></div>
  <div class="card" style="margin-top:12px"><h2>Profile</h2><div id="prof">—</div></div>
  <div class="card" style="margin-top:12px"><h2>Stream URI</h2><code id="suri" style="font-size:.8em;color:var(--accent);word-break:break-all">—</code></div>
  <div class="card" style="margin-top:12px"><h2>Board Metrics</h2><div id="metrics">—</div></div>
  <div class="card" style="margin-top:12px"><h2>ONVIF Time</h2><div class="row"><span class="k">Type</span><span class="v" id="dt-t">—</span></div><div class="row"><span class="k">UTC</span><span class="v" id="dt-u">—</span></div></div>
</div>
</div>
<script>
const cv = document.getElementById('cv');
const ctx = cv.getContext('2d');
const img = new Image();
let ws = null, frames = 0, fpsStart = Date.now(), fpsTimer = null;

function connectWS() {
  ws = new WebSocket(`ws://${location.host}/ws/video`);
  ws.binaryType = 'blob';
  ws.onopen = () => {
    document.getElementById('badge').textContent = 'LIVE';
    document.getElementById('badge').className = 'badge live';
  };
  ws.onmessage = (e) => {
    if (e.data instanceof Blob) {
      const url = URL.createObjectURL(e.data);
      img.src = url;
      img.onload = () => {
        ctx.drawImage(img, 0, 0, cv.width, cv.height);
        URL.revokeObjectURL(url);
        frames++;
        const el = Math.floor((Date.now() - fpsStart) / 1000);
        if (el > 0) document.getElementById('fps-val').textContent = Math.round(frames / el * 10) / 10;
      };
    } else {
      try {
        const d = JSON.parse(e.data);
        if (d.type === 'fps') document.getElementById('fps-val').textContent = d.value;
      } catch(_){}
    }
  };
  ws.onclose = () => {
    document.getElementById('badge').textContent = 'DISCONNECTED';
    document.getElementById('badge').className = 'badge err';
    setTimeout(connectWS, 3000);
  };
}
connectWS();

// REST API
fetch('/api/info').then(r=>r.json()).then(d=>{
  document.getElementById('dev').innerHTML = Object.entries(d).map(([k,v])=>
    `<div class="row"><span class="k">${k}</span><span class="v">${v}</span></div>`).join('');
});
fetch('/api/profiles').then(r=>r.json()).then(list=>{
  const p = list[0]; if (!p) return;
  document.getElementById('prof').innerHTML = `
    <div class="row"><span class="k">Token</span><span class="v">${p.token}</span></div>
    <div class="row"><span class="k">Name</span><span class="v">${p.name}</span></div>
    <div class="row"><span class="k">Encoding</span><span class="v">${p.encoding}</span></div>
    <div class="row"><span class="k">Resolution</span><span class="v">${p.width}×${p.height}</span></div>`;
});
fetch('/api/stream_uri').then(r=>r.json()).then(d=>{
  document.getElementById('suri').textContent = d.Uri || '—';
});
fetch('/api/datetime').then(r=>r.json()).then(d=>{
  document.getElementById('dt-t').textContent = d.DateTimeType || '—';
  document.getElementById('dt-u').textContent = d.UTC || '—';
});
fetch('/api/status').then(r=>r.json()).then(d=>{
  document.getElementById('metrics').innerHTML = Object.entries(d).map(([k,v])=>
    `<div class="row"><span class="k">${k}</span><span class="v">${v}</span></div>`).join('');
});
setInterval(()=>{ fetch('/api/status').then(r=>r.json()).then(d=>{
  document.getElementById('metrics').innerHTML = Object.entries(d).map(([k,v])=>
    `<div class="row"><span class="k">${k}</span><span class="v">${v}</span></div>`).join('');
});}, 5000);
</script>
</body></html>"""


async def onvif_ws_handler(request):
    """WebSocket：推送 ffmpeg 解码的 JPEG 帧给浏览器。"""
    ws = web.WebSocketResponse()
    await ws.prepare(request)
    proc = None
    try:
        user_enc = quote(ARGS.user, safe="")
    pass_enc = quote(ARGS.password, safe="")
    url = f"rtsp://{user_enc}:{pass_enc}@{ARGS.host}:8554/mjpeg"  # URL userinfo → ffmpeg 走 RTSP Digest
        cmd = [FFMPEG, "-rtsp_transport", "tcp", "-i", url,
               "-f", "mjpeg", "-q:v", 4, "-"]
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL)
        buf = b""
        frame_count = 0
        t_start = time.time()
        loop = asyncio.get_event_loop()
        while True:
            chunk = await loop.run_in_executor(None, proc.stdout.read, 8192)
            if not chunk:
                break
            buf += chunk
            while True:
                soi = buf.find(b"\xff\xd8")
                eoi = buf.find(b"\xff\xd9", soi + 2) if soi >= 0 else -1
                if soi < 0 or eoi < 0:
                    break
                frame = buf[soi:eoi + 2]
                buf = buf[eoi + 2:]
                frame_count += 1
                # WebSocket binary frame push
                await ws.send_bytes(frame)
                # 每 30 帧（~2s）推一条 fps 指标
                if frame_count % 30 == 0:
                    fps = frame_count / (time.time() - t_start)
                    await ws.send_json({"type": "fps", "value": round(fps, 1),
                                        "frames": frame_count})
    except Exception:
        pass
    finally:
        if proc:
            proc.kill()
    return ws


async def api_handler(request):
    """REST API：ONVIF SOAP 调用。"""
    path = request.path
    loop = asyncio.get_event_loop()
    try:
        if path == "/api/info":
            r = await loop.run_in_executor(None, soap_info)
            return web.json_response(r)
        elif path == "/api/profiles":
            r = await loop.run_in_executor(None, soap_profiles)
            return web.json_response(r)
        elif path == "/api/stream_uri":
            r = await loop.run_in_executor(None, soap_stream_uri)
            return web.json_response(r)
        elif path == "/api/datetime":
            r = await loop.run_in_executor(None, soap_datetime)
            return web.json_response(r)
        elif path == "/api/status":
            r = await loop.run_in_executor(None, board_status)
            return web.json_response(r)
    except Exception as e:
        return web.json_response({"error": str(e)}, status=500)
    return web.json_response({"error": "not found"}, status=404)


def soap_info():
    from onvif import ONVIFCamera
    cam = ONVIFCamera(ARGS.host, ARGS.port, "admin", ARGS.password)
    info = cam.devicemgmt.GetDeviceInformation()
    return {"Manufacturer": str(info.Manufacturer), "Model": str(info.Model),
            "FirmwareVersion": str(info.FirmwareVersion),
            "SerialNumber": str(info.SerialNumber),
            "HardwareId": str(info.HardwareId)}


def soap_profiles():
    from onvif import ONVIFCamera
    cam = ONVIFCamera(ARGS.host, ARGS.port, "admin", ARGS.password)
    media = cam.create_media_service()
    profiles = media.GetProfiles()
    plist = profiles if isinstance(profiles, list) else [profiles]
    return [{"token": str(p.token), "name": str(p.Name),
             "encoding": str(p.VideoEncoderConfiguration.Encoding),
             "width": int(p.VideoEncoderConfiguration.Resolution.Width),
             "height": int(p.VideoEncoderConfiguration.Resolution.Height)} for p in plist]


def soap_stream_uri():
    from onvif import ONVIFCamera
    cam = ONVIFCamera(ARGS.host, ARGS.port, "admin", ARGS.password)
    media = cam.create_media_service()
    uri = media.GetStreamUri({"ProfileToken": "profile_1",
                              "StreamSetup": {"Stream": "RTP-Unicast",
                                              "Transport": {"Protocol": "RTSP"}}})
    return {"Uri": str(uri.Uri)}


def soap_datetime():
    from onvif import ONVIFCamera
    cam = ONVIFCamera(ARGS.host, ARGS.port, "admin", ARGS.password)
    sdt = cam.devicemgmt.GetSystemDateAndTime()
    utc = sdt.UTCDateTime
    return {"DateTimeType": str(sdt.DateTimeType),
            "UTC": f"{utc.Date.Year:04d}-{utc.Date.Month:02d}-{utc.Date.Day:02d}T"
                   f"{utc.Time.Hour:02d}:{utc.Time.Minute:02d}:{utc.Time.Second:02d}Z"}


def board_status():
    out = serial_cmd("status", wait=1.5)
    lines = [l.strip() for l in out.splitlines() if "=" in l]
    return dict(l.split("=", 1) for l in lines if "=" in l)


# ---- serial ----
import serial as pyserial_mod

_serial_port = None

def serial_cmd(cmd, wait=1.5):
    global _serial_port
    try:
        if _serial_port is None:
            _serial_port = pyserial_mod.Serial(SERIAL_DEV, 115200, timeout=1)
        _serial_port.write((cmd + "\r\n").encode())
        time.sleep(wait)
        return _serial_port.read(8192).decode("utf-8", "replace")
    except Exception:
        return ""


# ---- app setup ----
async def index_handler(request):
    return web.Response(text=HTML, content_type="text/html")


async def main():
    global ARGS
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", required=True)
    ap.add_argument("--port", type=int, default=80)
    ap.add_argument("--password", required=True)
    ap.add_argument("--serial", default="/dev/ttyUSB0")
    ap.add_argument("--listen", type=int, default=8899)
    ARGS = ap.parse_args()

    app = web.Application()
    app.router.add_get("/", index_handler)
    app.router.add_get("/ws/video", onvif_ws_handler)
    for p in ("/api/info", "/api/profiles", "/api/stream_uri",
              "/api/datetime", "/api/status"):
        app.router.add_get(p, api_handler)

    runner = web.AppRunner(app)
    await runner.setup()
    site = web.TCPSite(runner, "0.0.0.0", ARGS.listen)
    await site.start()
    print(f"ONVIF app: http://0.0.0.0:{ARGS.listen}")
    print(f"  board: {ARGS.host}:{ARGS.port}")
    print(f"  WebSocket video: /ws/video")
    await asyncio.Event().wait()


if __name__ == "__main__":
    asyncio.run(main())
