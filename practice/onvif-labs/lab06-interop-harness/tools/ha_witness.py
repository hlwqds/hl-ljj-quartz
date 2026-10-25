#!/usr/bin/env python3
"""lab06 HA witness 驱动（纯 WebSocket）：onboarding → auth → ONVIF config flow → camera 实体验证。

前置：HA 运行在 127.0.0.1:8123，configuration.yaml 为最小配置（含 onvif: + ffmpeg:）。
用法：python3 tools/ha_witness.py --host <板IP> --password <口令> [--outdir runs]
"""

import argparse
import asyncio
import json
import os
import time

import websockets

WS_URL = "ws://127.0.0.1:8123/api/websocket"
HTTP_BASE = "http://127.0.0.1:8123"


class HaWs:
    def __init__(self):
        self.ws = None
        self.mid = 0

    async def connect_and_auth(self, token=None):
        self.ws = await websockets.connect(WS_URL, close_timeout=5)
        hello = json.loads(await self.ws.recv())
        assert hello["type"] == "auth_required", hello
        if token:
            await self.ws.send(json.dumps({"type": "auth", "access_token": token}))
            r = json.loads(await self.ws.recv())
            assert r["type"] == "auth_ok", f"auth failed: {r}"
        return hello

    async def call(self, **payload):
        self.mid += 1
        msg = dict(payload, id=self.mid)
        await self.ws.send(json.dumps(msg))
        while True:
            raw = await asyncio.wait_for(self.ws.recv(), timeout=60)
            r = json.loads(raw)
            if r.get("id") == self.mid:
                return r


async def async_main(host, password, outdir, ha_port):
    os.makedirs(os.path.join(outdir, "ha-flow"), exist_ok=True)
    ha = HaWs()

    # ① onboarding：POST /api/onboarding/users → auth_code → /auth/token
    #    用 aiohttp（HA venv 自带）避免 urllib 代理坑
    import aiohttp
    async with aiohttp.ClientSession() as http:
        async with http.post(
            f"http://127.0.0.1:{ha_port}/api/onboarding/users",
            json={"client_id": f"http://127.0.0.1:{ha_port}/",
                  "name": "lab06 witness", "username": "lab06",
                  "password": password, "language": "en"},
        ) as r:
            body = await r.json()
            if r.status == 200:
                auth_code = body["auth_code"]
                print(f"onboarding user created", flush=True)
                async with http.post(
                    f"http://127.0.0.1:{ha_port}/auth/token",
                    json={"grant_type": "authorization_code",
                          "code": auth_code,
                          "client_id": f"http://127.0.0.1:{ha_port}/"},
                ) as tr:
                    token_r = await tr.json()
                    token = token_r["access_token"]
                    print("token acquired", flush=True)
            else:
                # onboarding 已完成 → login_flow
                print(f"onboarding skipped ({r.status}), using login_flow", flush=True)
                async with http.post(
                    f"http://127.0.0.1:{ha_port}/auth/login_flow",
                    json={"handler": ["homeassistant", None], "type": "flow",
                          "client_id": f"http://127.0.0.1:{ha_port}/"},
                ) as r:
                    flow = await r.json()
                async with http.post(
                    f"http://127.0.0.1:{ha_port}/auth/login_flow/{flow['flow_id']}",
                    json={"username": "lab06", "password": password,
                          "client_id": f"http://127.0.0.1:{ha_port}/"},
                ) as r:
                    result = await r.json()
                    if result.get("type") != "create_entry":
                        raise SystemExit(f"login failed: {result}")
                    token = result["result"]
                print("login_flow token acquired", flush=True)

    # ③ WebSocket 认证
    await ha.connect_and_auth(token)

    # ④ ONVIF config flow（发现→凭据→建 entry）
    m = await ha.call(type="config_entries/flow", handler="onvif")
    step_i = 0
    while True:
        if m.get("type") == "create_entry":
            print(f"flow create_entry title={m.get('title')!r}", flush=True)
            break
        if m.get("type") == "abort":
            raise SystemExit(f"flow abort: {m.get('reason')}")
        st = m.get("step_id") or ""
        step_i += 1
        with open(os.path.join(outdir, "ha-flow", f"flow-{step_i:02d}-{st}.json"), "w") as f:
            json.dump(m, f, indent=2, ensure_ascii=False)
        ui = None
        if st == "user":
            ui = {"auto": True}
        elif st == "device":
            opts = []
            for f in m.get("data_schema", []):
                if f.get("name") == "host":
                    opts = (f.get("container") or {}).get("options", [])
            print(f"flow device: discovered={opts}", flush=True)
            tgt = next((o["value"] for o in opts if host in str(o.get("value"))), None)
            if tgt is None:
                raise SystemExit(f"board not discovered (options={opts}); use manual tier")
            ui = {"host": tgt}
        elif st == "configure":
            ui = {"name": "lab06-camera", "host": host, "port": 80,
                  "username": "admin", "password": password}
        elif st == "auth":
            ui = {"username": "admin", "password": password}
        if ui is None:
            raise SystemExit(f"unhandled step: {st}")
        m = await ha.call(type="config_entries/flow", flow_id=m["flow_id"],
                          handler="onvif", user_input=ui)
    entry_id = m["entry_id"]
    print(f"entry_id={entry_id}", flush=True)

    # ⑤ 等 camera 实体 + 验证
    await asyncio.sleep(5)
    states = await ha.call(type="get_states")
    with open(os.path.join(outdir, "ha-flow", "states.json"), "w") as f:
        json.dump(states, f, indent=2, ensure_ascii=False)
    cams = [s for s in states["result"] if s["entity_id"].startswith("camera.")]
    if not cams:
        raise SystemExit("no camera entity")
    for c in cams:
        print(f"camera entity={c['entity_id']} state={c['state']}", flush=True)

    # ⑥ camera_proxy 端到端像素
    import aiohttp
    async with aiohttp.ClientSession() as http:
        async with http.get(
            f"http://127.0.0.1:{ha_port}/api/camera_proxy/{cams[0]['entity_id']}",
            headers={"Authorization": f"Bearer {token}"},
        ) as r:
            img = await r.read()
    png_path = os.path.join(outdir, "ha-camera-proxy.jpg")
    with open(png_path, "wb") as f:
        f.write(img)
    is_jpeg = img.startswith(b"\xff\xd8")
    print(f"camera_proxy: {len(img)}B ctype_ok={is_jpeg} -> {png_path}", flush=True)
    if not is_jpeg:
        raise SystemExit("camera_proxy not JPEG")
    print("WITNESS PASS: HA ONVIF end-to-end (discovery/credentials/stream/snapshot)", flush=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", required=True)
    ap.add_argument("--password", required=True)
    ap.add_argument("--outdir", default="runs")
    ap.add_argument("--ha-port", type=int, default=8123)
    args = ap.parse_args()
    os.environ.pop("http_proxy", None)
    os.environ.pop("https_proxy", None)
    os.environ["no_proxy"] = "*"
    asyncio.run(async_main(args.host, args.password, args.outdir, args.ha_port))


if __name__ == "__main__":
    main()
