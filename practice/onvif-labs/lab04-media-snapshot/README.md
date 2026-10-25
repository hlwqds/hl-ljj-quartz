# lab04-media-snapshot — Media Profile 与快照（ONVIF 设备端实验室第 4 站）

把 [[ch05-media-profiles|第五章]]的配置模型最小可信落地：`/onvif/media_service` 上
GetProfiles 交出**单 profile 静态模板**（token=profile_1、JPEG 编码档 640×480、Quality 80、
15fps——每个字段取自基座实测/固件常量），GetSnapshotUri 以请求 Host 头现拼
`/onvif-http/snapshot` 地址；快照本体零额外编码——从 `/stream` 同源的最新帧双缓冲锁内
拷贝最近一帧成品 JPEG。两个 media 操作都过 lab03 摘要门；未知 ProfileToken 回
s:Sender + ter:InvalidArgVal（HTTP 按壳映射 400/500）。实战叙事见
《ONVIF 深度解析》[[ch15-lab04-media-snapshot-report|第十五章]]，契约见套件
[SPEC](../../SPEC.md)（`practice/onvif-labs/SPEC.md` §6 lab04）。

## 拓扑

```text
宿主机（NixOS，本仓工作区）                ESP32-S31-Korvo-1（WiFi STA，192.168.1.x）
  tools/onvif_smoke.py（onvif-zeep）          ┌────────────────────────────────────┐
      │ POST /onvif/media_service             │ httpd :80（max_uri_handlers=9）     │
      │  ├ GetProfiles（过摘要门）             │  ├ /onvif/device_service（lab02/03）│
      │  └ GetSnapshotUri → Uri 现拼 ────┐    │  ├ /onvif/media_service（lab04）    │
      │                                  │    │  ├ /onvif-http/snapshot（GET 直出） │
      │ GET /onvif-http/snapshot ◀───────┘    │  └ /stream（MJPEG 对照面，同源帧）   │
      │      ▼ 最新帧双缓冲 read_slot         │  采集→PPA→硬件JPEG→jpeg_buf[2]      │
      └──── UART 115200（sntp/auth 门同前）   │    lock 内拷贝 = 快照（不碰 frame_sem）│
                                             └────────────────────────────────────┘
```

固件 = lab03 全量 + ① `onvif_svc` 挂 media 双操作（tds/trt 双命名空间路由）与快照
GET 端点（300KB PSRAM 拷贝缓冲）；② 基座新增 `factory_stream_copy_latest()`（锁内
拷贝 read_slot，不碰 `frame_sem`——不偷 `/stream` 订阅者的唤醒）；③ httpd
`max_uri_handlers` 4→9（基座 2 条 + onvif 5 条，之前的「no slots left」教训）。
方案语境见 [[ch13-lab02-device-service-report|第十三章]]/[[ch14-lab03-auth-digest-report|第十四章]]。

## 构建 / 烧录 / 凭据

同 lab03（复制 lab03 → 改工程名即可复用）：WiFi 凭据 `main/wifi_secrets.h`、认证
口令 `main/onvif_secrets.h`（均 gitignore，example 模板同目录）。环境壳：

```bash
NIXPKGS_ALLOW_UNFREE=1 nix shell --impure nixpkgs#steam-run nixpkgs#cmake nixpkgs#ninja nixpkgs#git \
  -c steam-run bash -c '. ~/esp/esp-idf/export.sh && idf.py --preview set-target esp32s31 && idf.py build'
NIXPKGS_ALLOW_UNFREE=1 nix shell --impure nixpkgs#steam-run nixpkgs#cmake nixpkgs#ninja nixpkgs#git \
  -c steam-run bash -c '. ~/esp/esp-idf/export.sh && idf.py -p /dev/ttyUSB0 flash'
```

启动判据：`SC101IOT` 识别 → `AUTH READY`/`SVC READY`/`DISC JOIN`/`SNTP synced`
（同 lab03）→ `lab04 base ready (camera+stream+disc+svc+auth+media)`。串口控制台同
lab03（status/ip/heap/restart/sntp/clock）。

## 验收（宿主侧）

```bash
cd practice/onvif-labs/lab04-media-snapshot
mkdir -p runs
python3 -m venv /tmp/onvif-venv && /tmp/onvif-venv/bin/pip install onvif-zeep pyserial
P=/tmp/onvif-venv/bin/python
PASS=$(grep -oP '(?<=ONVIF_AUTH_PASS ")[^"]+' main/onvif_secrets.h)
$P tools/serial_capture.py --port /dev/ttyUSB0 --seconds 90 --send-at 8:status --send-at 70:status > run.log
# 另开终端（等 SNTP synced；板 IP 以板端日志为准）：
$P tools/onvif_smoke.py --host <板IP> --password "$PASS" --outdir runs  # ①-⑤ 全链
# 快照本体 + 完整性对账（内网 IP 记得绕代理）：
curl --noproxy '*' -fsS -o runs/snap-curl.jpg http://<板IP>/onvif-http/snapshot
file runs/snap-curl.jpg                                    # JPEG image data, 640x480
ffprobe -v error -select_streams v:0 -show_entries stream=codec_name,width,height \
  -of default=nw=1 runs/snap-curl.jpg                      # mjpeg / 640 / 480
grep 'ONVIF LAB04 SNAPSHOT' run.log | tail -3              # bytes=<n> 与落地文件对账
```

冒烟断言：恰好 1 个 profile（token=profile_1、Encoding=JPEG、640×480）；
GetSnapshotUri 的 Uri == `http://<板IP>/onvif-http/snapshot`（Host 回拼）；
GET Uri 落地 FFD8…FFD9 完整 JPEG；未知 ProfileToken → ter:InvalidArgVal；
免鉴权四连回归。zeep 交换原文落 `runs/zeep-*.xml`。

## 真实输出摘录（2026-10-26 上板实测，板 IP=192.168.1.4 本轮 DHCP）

zeep 冒烟 5/5（`runs/smoke-zeep.log`）：

```text
$$$ HOST LAB04 OP GetProfiles ok  token=profile_1 name=mjpeg_640x480 \
  encoding=JPEG 640x480 quality=80.0 fps=15
$$$ HOST LAB04 OP GetSnapshotUri ok  uri=http://192.168.1.4/onvif-http/snapshot
$$$ HOST LAB04 SNAPSHOT ok  bytes=18901 ctype=image/jpeg -> runs/snap-zeep.jpg
$$$ HOST LAB04 FAULT GetSnapshotUri(unknown token) ok  \
  reason=ONVIFError(Fault('Unknown ProfileToken (ter:InvalidArgVal)'))
$$$ HOST LAB04 OP GetDeviceInformation ok  sn=1c2904d072e8
$$$ HOST LAB04 SMOKE PASS 5/5（Profile/Uri/JPEG/Fault/回归）
```

板端标记行与板宿字节对账（三张快照三对数字，活帧语义可见——逐帧字节数不同）：

```text
I (7340)  onvif_svc: $$$ ONVIF LAB04 SNAPSHOT bytes=18901   ↔ runs/snap-zeep.jpg  18901
I (75569) onvif_svc: $$$ ONVIF LAB04 SNAPSHOT bytes=21044   ↔ runs/snap-curl2.jpg 21044
I (122943) onvif_svc: $$$ ONVIF LAB04 SNAPSHOT bytes=20882  ↔ runs/snap-curl.jpg  20882
```

curl 落地完整性（`file` + `ffprobe`，与 profile 声明逐项一致）：

```text
runs/snap-curl.jpg: JPEG image data, JFIF standard 1.01, ..., baseline, precision 8,
  640x480, components 3
codec_name=mjpeg
width=640
height=480
```

无凭据访问 media 操作（SOAP 1.1，无安全头）：

```text
HTTP/1.1 500 Internal Server Error
Content-Type: text/xml; charset=utf-8
→ faultcode s:Receiver + faultstring ter:NotAuthorized: sender not authorized
（板端 I (13606) onvif_auth: $$$ ONVIF LAB03 AUTH deny reason=no_token user=-）
```

内存红线观测（SPEC §4；含 300KB 快照缓冲分配后）：

```text
t=8  status: free_dma=252067 free_spiram=11726116
t=70 status: free_dma=252035 free_spiram=11726116
```

free_dma 全程 ≈252KB（快照缓冲在 PSRAM，内部 DMA 纹丝不动，Δ=32B），红线 ≥170KB 无压力。

## 已知边界（刻意为之）

- **快照端点免鉴权直出**：SOAP 侧 GetProfiles/GetSnapshotUri 过摘要门，但快照本体是
  普通 HTTP GET、WS-Security 头无处安放——内网实验形态（HTTP Digest 401 挑战与 TLS
  列为后续增强，ch15 §15.3 明示）。
- **单 profile**：只有一路「采集→PPA→硬件 JPEG」管线，没有的能力不声明；GetProfile
  单数、GetVideoEncoderConfigurationOptions、SetVideoEncoderConfiguration 等未实现
  操作回 ter:ActionNotSupported。
- **ProfileToken 校验是字符串比对**：`>profile_1<` 定向查 substring，非 DOM；伪造
  属性形态的 token 不在防御范围（内网实验边界）。
- **未知 ProfileToken 的 HTTP 码按壳分**：1.2 s:Sender→400、1.1 Fault 一律 500
  （坑 6 HTTP 映射的设备端首次自用）。
- **Quality 80 / 15fps / 3020kbps**：Quality 与 FrameRateLimit 取自固件常量与传感器
  上限（同源声明）；BitrateLimit 3020kbps 为 25,165 B/帧 × 15fps × 8bit 的推算值。
- 内存/发现面/双壳边界沿袭 lab01–03（见各 README）。
