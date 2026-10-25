# lab05-rtsp-mjpeg — RTSP/RTP 取流全链（ONVIF 设备端实验室第 5 站）

给 lab04 的 Profile 接上真正的媒体面：8554/tcp raw socket 手写 RTSP 状态机
（OPTIONS/DESCRIBE/SETUP/PLAY/TEARDOWN，TCP interleaved 优先、UDP 第二档），
MJPEG 按 RFC 2435 封 RTP（type 0、量化表带内 Q=255、1400B 载荷避分片），
控制面补 GetStreamUri（过 lab03 摘要门）。验收不是「能出图」而是「每帧完整到达」：
板端 FRAME 标记、客户端成帧计数、ffmpeg 解码帧数三本账互对。实战叙事见
《ONVIF 深度解析》[[ch16-lab05-rtsp-mjpeg-report|第十六章]]，契约见套件
[SPEC](../../SPEC.md)（`practice/onvif-labs/SPEC.md` §6 lab05）。

## 拓扑

```text
宿主机（NixOS，本仓工作区）                ESP32-S31-Korvo-1（WiFi STA，192.168.1.x）
  tools/onvif_smoke.py（zeep）               ┌──────────────────────────────────┐
      │ POST /onvif/media_service            │ onvif_svc :80（lab02–04 全量）    │
      │  GetStreamUri → rtsp://ip:8554/mjpeg │ rtsp_server :8554（raw socket）   │
      │                                      │  ├ OPTIONS/DESCRIBE(SDP)/SETUP   │
  tools/rtsp_ledger.py（stdlib 账本客户端）     │  ├ PLAY → RFC 2435 RTP 流         │
      │  同信令 + 12s 交织流成帧计数 ────────▶ │  │  TCP interleaved $ / UDP 两档  │
  ffmpeg -rtsp_transport tcp|udp -t 12        │  └ 60s 空闲单方面 TEARDOWN        │
      └── 解码帧数（第三本账）──────────────▶ │ 消费者：copy_latest_id 轮询+去重    │
                                              │   （只丢整帧，不碰 /stream 节拍）    │
                                              └──────────────────────────────────┘
```

固件 = lab04 全量 + 新模块 `rtsp_server`（约 470 行：信令状态机 + RFC 2435 封包器）

- `onvif_svc` 挂 GetStreamUri + 基座 `factory_stream_copy_latest_id()`（frame_id 去
  重用）。方案语境见 [[ch13-lab02-device-service-report|第十三章]]–[[ch15-lab04-media-snapshot-report|第十五章]]。

## 构建 / 烧录 / 凭据

同 lab03/04（复制上一站 → 改工程名；凭据两个 gitignore 头文件 + example 模板）：

```bash
NIXPKGS_ALLOW_UNFREE=1 nix shell --impure nixpkgs#steam-run nixpkgs#cmake nixpkgs#ninja nixpkgs#git \
  -c steam-run bash -c '. ~/esp/esp-idf/export.sh && idf.py --preview set-target esp32s31 && idf.py build'
NIXPKGS_ALLOW_UNFREE=1 nix shell --impure nixpkgs#steam-run nixpkgs#cmake nixpkgs#ninja nixpkgs#git \
  -c steam-run bash -c '. ~/esp/esp-idf/export.sh && idf.py -p /dev/ttyUSB0 flash'
```

启动判据：lab03/04 全部判据 + `$$$ ONVIF LAB05 RTSP LISTENING port=8554` →
`lab05 base ready (…+rtsp)`。串口控制台同 lab03/04。

**取证特征**：`serial_capture.py` 打开串口即断言 DTR/RTS、经板上复位电路把板子重启
一次（`--no-reset` 可免）——run.log 里因此有多段启动日志与多个独立补采窗口，属工具
行为而非设备异常重启。

## 验收（宿主侧）

```bash
cd practice/onvif-labs/lab05-rtsp-mjpeg
mkdir -p runs
python3 -m venv /tmp/onvif-venv && /tmp/onvif-venv/bin/pip install onvif-zeep pyserial
P=/tmp/onvif-venv/bin/python
PASS=$(grep -oP '(?<=ONVIF_AUTH_PASS ")[^"]+' main/onvif_secrets.h)
$P tools/serial_capture.py --port /dev/ttyUSB0 --seconds 115 --send-at 8:status --send-at 100:status > run.log
# 另开终端（等 SNTP synced）：
$P tools/onvif_smoke.py --host <板IP> --password "$PASS" --outdir runs    # GetStreamUri + Fault + 回归
$P tools/rtsp_ledger.py <板IP> --seconds 12                              # 抓包侧账本（成帧计数）
# 解码侧账本：TCP 档与 UDP 档（ffmpeg 默认先 UDP，ch06 6.7）各 12 秒（全量 stderr 存 runs/）
ffmpeg -rtsp_transport tcp -i rtsp://<板IP>:8554/mjpeg -t 12 -f null - 2> runs/ffmpeg-tcp.log
ffmpeg -i rtsp://<板IP>:8554/mjpeg -t 12 -f null - 2> runs/ffmpeg-udp.log
grep -oE 'frame=[ 0-9]+' runs/ffmpeg-tcp.log | tail -1
grep -c 'ONVIF LAB05 FRAME' run.log                                      # 板端账本
```

GetStreamUri 的 WSDL 入参要求 StreamSetup 结构（ProfileToken + Stream=RTP-Unicast +
Transport.Protocol=RTSP），zeep 用嵌套 dict 传参；未知 ProfileToken →
ter:InvalidArgVal。无凭据 media 访问 → HTTP 500 + ter:NotAuthorized。

## 真实输出摘录（2026-10-26 上板实测，板 IP=192.168.1.4 本轮 DHCP）

zeep 冒烟 3/3（`runs/smoke-zeep.log`）：

```text
$$$ HOST LAB05 OP GetStreamUri ok  uri=rtsp://192.168.1.4:8554/mjpeg
$$$ HOST LAB05 FAULT GetStreamUri(unknown token) ok  \
  reason=ONVIFError(Fault('Unknown ProfileToken (ter:InvalidArgVal)')))
$$$ HOST LAB05 OP GetProfiles ok  token=profile_1
$$$ HOST LAB05 SMOKE PASS 3/3（GetStreamUri / Fault / 回归）
```

三本账（单 boot 三会话；板端 552 帧 = 188/182/182；解码侧差值为 PLAY→解码器首帧就绪
的启动段，会话内 seq 连续无丢帧；会话2 的 21.89s 拉伸是 ffmpeg 停读后板端 send 阻塞
在 TCP 窗口的停止语义，非丢帧）：

```text
会话1（账本客户端，TCP interleaved）：板端 FRAME 标记 188 帧 ↔ 客户端成帧 188（12.035s ≈ 15.62fps）
会话2（ffmpeg，TCP）：板端 182 帧 ↔ ffmpeg 解码 180（frame= 180）
会话3（ffmpeg，UDP 默认档）：板端 182 帧 ↔ ffmpeg 解码 179（frame= 179）
```

帧长 17,484–18,309 B（暗光场景）→ 实测码率 ≈2.24 Mbps；Profile 的 BitrateLimit
3020 kbps 为亮场基线推导的**配置上限**（25,165 B/帧 × 15fps × 8bit），与暗光实测值
不等——两栏并列，出处见 ch15 §15.2 出处表。

里程碑 heap 三件套（`run.log`；free_dma 全程 ≥243KB，红线 170KB 无压力）：

```text
rtsp: heap@LISTENING free_dma=259567 free_internal=291575 free_spiram=13374432
rtsp: heap@SETUP    free_dma=243419 free_internal=275427 free_spiram=11404732
rtsp: heap@PLAYING  free_dma=243419 free_internal=275427 free_spiram=11404728
rtsp: heap@TEARDOWN free_dma=243231 free_internal=275239 free_spiram=11398100
```

RFC 2435 对齐证据（宿主侧逐字节解析板上成品 JPEG，存证于本仓提交记录）：

```text
SOF0: Y 2x1 / Cb 1x1 / Cr 1x1  → RFC 2435 type 0（4:2:2）逐字段命中
DQT:  Pq=0 Tq=0 ×64B + Pq=0 Tq=1 ×64B → 量化头 = MBZ(1)+Prec(1)+Len(2)=128+128B 系数（132B）
DHT:  四张表与 ffmpeg -huffman default 标准表逐字节相同 → 缩略格式（剥 DHT）合规
DRI:  无（type 0 禁重启标记合规）
```

无凭据 media 访问（SOAP 1.1）→ HTTP 500 + `s:Receiver`/`ter:NotAuthorized`。

## 已知边界（刻意为之）

- **单客户端、逐连接串行**：PLAYING 期间新连接排队（listen backlog），不并发——
  实验形态取舍，README 明示不装 N 路并发。
- **无 RTSP Digest**：DESCRIBE 不做 401 挑战（内网明文实验形态，与控制面同口径）；
  凭据接入归 lab06 互通收口。
- **无 RTCP SR**：交织通道 1 预留不发；个别依赖 SR 判超时的客户端行为列入观察。
- **UDP 档 server_port=8556-8557**：设备反向发包形态依赖 AP 路径对称性（lab01 组播
  教训同源），本轮 ffmpeg UDP 档实测可达。
- **量化表带内 Q=255 路生效**：每帧携带 132B 量化头（「公式路」的 IJG 等价假设未采
  用，不走侥幸路径）。
- 内存/发现面/双壳边界沿袭 lab01–04（见各 README）。
