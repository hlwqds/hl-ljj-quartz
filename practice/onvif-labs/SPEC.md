# ONVIF 设备端实验室 · 构建规格 v1（ONVIF LABS SPEC）

本文件是 `practice/onvif-labs/` 套件全部实验的实现契约：把一块 ESP32-S31-Korvo-1
变成局域网里一台可互通的 ONVIF 取流设备。方案叙事见 `content/onvif-deep-dive/ch11-esp32s31-lab-plan.md`
（下称「方案章」），本文只写可执行契约，不重复论证。协议事实以系列 ch02–ch06 为准，
互通事实以 ch09 为准。

## 1. 定位与目录约定

- 目录：`practice/onvif-labs/labNN-slug/`（NN 两位：lab01–lab06）。
- 每工程必备：`main/`（源码）、根 `CMakeLists.txt`、`sdkconfig.defaults`、`README.md`
  （中文，含拓扑与复现命令）、`run.log`（真实上板运行留存）；需要宿主配合的附 `tools/`
  （python 脚本为主：wsdiscovery 探测、onvif 冒烟、rtsp 验流）。
- 基座裁剪自 esp32-video-tran 工作区 `~/code/esp32-video-tran/demo/factory_demo`
  （本机工作区，不在本仓；复跑手册 `~/code/esp32-video-tran/RUNBOOK.md`）。裁剪产物
  （本仓入库形态）只保留：采集→PPA→硬件 JPEG→双缓冲 管线 + WiFi STA + 串口控制台；
  裁掉 LVGL/UI、mmap 资产分区、触摸、USB HID、音频。各 lab 在此基座上叠加增量模块。
- 机器可读标记：每 lab 的关键事件必须落一行 `$$$ ONVIF LABnn <event> <k=v ...>`，
  便于 grep 验收（沿用本仓 lwIP 实验室的 $$$ 纪律）。

## 2. 环境硬事实（引用，不重复论证）

板卡与构建环境以 RUNBOOK 为准，速查版（全部实测）：

| 项        | 事实                                                                                                                                                                                                                                                        |
| --------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 板/芯片   | ESP32-S31-Korvo-1，target `esp32s31`（IDF v6.1 **preview target**，`set-target`/`list-targets` 必带 `--preview`）                                                                                                                                           |
| 摄像头    | SmartSens SC101IOT（PID 0xda4a），640×480 UYVY；官方资料写 OV3660 是错的                                                                                                                                                                                    |
| 编码/缩放 | 硬件 JPEG（esp_new_jpeg）+ PPA 硬件缩放；实测 25,165 B/帧，编码侧上限 16.667 fps                                                                                                                                                                            |
| WiFi 实测 | MJPEG 推流 13.75 fps / 2.77 Mbps；30 分钟烤机均值 13.51 fps，0 重启 0 断连；瓶颈在 2.4G 空口                                                                                                                                                                |
| 内存      | 16MB Octal PSRAM + 16MB flash；推流稳态实测 free_dma ≈ 190KB（190,039–190,931 B，控制台与烤机实测；teardown 后起 WiFi 前 269–293KB）                                                                                                                        |
| 构建壳    | NixOS 必须套 `NIXPKGS_ALLOW_UNFREE=1 nix shell --impure nixpkgs#steam-run nixpkgs#cmake nixpkgs#ninja nixpkgs#git -c steam-run bash -c '. ~/esp/esp-idf/export.sh && idf.py …'`                                                                             |
| 烧录口    | 按 VID:PID=**10c4:ea60**（CP2102N）定位 `/dev/ttyUSB*`——口名随插拔顺序变（ttyUSB0/ttyUSB1 都出现过），烧前必核：`udevadm info -q property -n <口> \| grep -E '10c4\|ea60'`；同机常驻另一块 CH340（1a86:7523，STM32 板）勿灌；重插后需 `sudo chmod 666 <口>` |
| 局域网    | 真实网形态（无 QEMU/hostfwd）：WiFi STA 连家庭 AP，板端拿 DHCP 地址；串口控制台 `ip` 可直取                                                                                                                                                                 |

构建-烧录标准命令（在裁剪基座工程目录）：

```bash
NIXPKGS_ALLOW_UNFREE=1 nix shell --impure nixpkgs#steam-run nixpkgs#cmake nixpkgs#ninja nixpkgs#git \
  -c steam-run bash -c '. ~/esp/esp-idf/export.sh && idf.py --preview set-target esp32s31 && idf.py build'
# 烧录/monitor：-p <烧录口>（按上表 VID:PID=10c4:ea60 定位）与构建同壳；烧录前确认串口权限
```

## 3. 基座与组件策略

- 组件树随 factory_demo 的 `dependencies.lock` 固化：`esp_video`、`esp_cam_sensor`、
  `esp_new_jpeg`、`esp_http_server` 等 registry 组件按锁文件离线拉取；本地补丁副本
  （factory_demo 有两个：`esp_cam_sensor`、`esp_lvgl_adapter`）整目录随裁剪基座迁移，
  **禁止**重新在线解析 registry 版本——`esp_lvgl_adapter` 的 6.1 补丁副本是基座能编过的关键。
- 裁剪后仍以「构建离线可重复」为验收项：dependencies.lock 提交，无未锁定的 registry 依赖。
- 摄像头 tee 点沿用 factory_demo_camera.c 的 submit 钩子位置（预览渲染后、
  `bsp_camera_return_frame()` 前），帧数据只透传指针+长度，消费者自行拷贝。

## 4. 固件形态与内存红线

- 形态：**stream-first**（无 LVGL）。UI 与 WiFi 驱动抢内部 DMA RAM 是 esp32-video-tran
  实测的最大内存教训（`esp_wifi_init` 曾因 LVGL 占池而 ESP_ERR_NO_MEM）。
- 红线：推流稳态 free_dma ≥ 170KB（基线 190KB 的 10% 跌幅内）；ONVIF 新增缓冲（XML 应答、SOAP 解析、
  RTP 封包、快照拷贝）一律 PSRAM 分配，内部 RAM 只留栈与 socket 系统缓冲。
- 观测行：启动与每里程碑打印 `free DMA/internal/SPIRAM` 三件套（沿用 factory_stream
  的 heap 打点格式），run.log 必须可对账。

## 5. 端口与地址分配

真实局域网形态，无 hostfwd 表；端口固定如下，禁止占用 81（保留给对照面 status 页）：

| 端口     | 协议           | 用途                                                                                                           |
| -------- | -------------- | -------------------------------------------------------------------------------------------------------------- |
| 80/tcp   | SOAP over HTTP | `/onvif/device_service`、`/onvif/media_service`、`/onvif-http/snapshot`；另保留 `/stream`（HTTP MJPEG 对照面） |
| 3702/udp | WS-Discovery   | 组播 239.255.255.250:3702，Probe→ProbeMatch                                                                    |
| 8554/tcp | RTSP           | 信令 + RTP/AVP/TCP interleaved（MJPEG，RFC 2435）                                                              |

- XAddrs 与 GetStreamUri 必须填板端**实际 IPv4**（DHCP 后取 netif 地址，禁写死）。
- Scopes 必含 `onvif://www.onvif.org/Profile/Streaming`；types 返回 `dn:NetworkVideoTransmitter`。
- 每 lab 一个十位递增子端口块不适用（非 QEMU 形态）；如需临时端口，README 声明并避开
  本表与本仓 legacy 黑名单（8006、8108、8517、9014、1883）。

## 6. 里程碑规格（lab01–lab06）

### lab01-discovery —— WS-Discovery 应答【ch02】

新建 `onvif_disc` 模块：加入 239.255.255.250:3702 组播，解析 Probe（只定向提取
Types/Scopes，宽松匹配），回 ProbeMatch（XAddrs/Scopes/Types/MetadataVersion）。
验收：宿主探测（仓内 `tools/onvif_probe.py`，stdlib、Probe/ProbeMatch 语义等价）探到本板；
板端证据入 `run.log`（DISC READY/JOIN 与 PROBEMATCH 标记行），宿主侧原文入
`runs/probe-*.log`（发出的 Probe 原文 + 应答原文/hex），两账互对（tcpdump 3702 断面为补充
证据，需 sudo，可选）；标记行 `$$$ ONVIF LAB01 PROBEMATCH xaddrs=http://<ip>:80/onvif/device_service`。

### lab02-device-service —— SOAP 控制面最小集【ch03】

新建 `onvif_svc` 模块：单 httpd 挂 `/onvif/*`；实现免鉴权 GetSystemDateAndTime 与
GetDeviceInformation/GetServices/GetCapabilities；未实现操作回合规 SOAP Fault
（ter:ActionNotSupported 结构与 ch09 速查表一致）。模板 XML 手写，命名空间严格对 WSDL；
信封版本跟随请求（SOAP 1.1/1.2 双壳模板、Body 共用——python-onvif-zeep 按绑定强校验
回信信封，纯 1.1 会挂自家验收；成文期决策，最终以实测为准）。验收：python-onvif-zeep 逐操作冒烟全通；Fault 结构留样本；
标记行 `$$$ ONVIF LAB02 OP <name> ok`。

### lab03-auth-digest —— WS-Security 摘要认证【ch04】

PasswordDigest = Base64(SHA1(Nonce+Created+Password))（IDF 6.1 mbedTLS 4，SHA1 走 PSA）；nonce
环形缓存重放拒绝；SNTP 启动对时 + 免鉴权 GetSystemDateAndTime 补偿窗口。验收：带凭据全通/无凭据
ter:NotAuthorized/重放 nonce 被拒三项证据；**故意制造时钟漂移复现 ch09 坑 1**（实测：仅关 SNTP
不足以复现——esp_restart 不清 RTC 墙钟、板钟仍停在上次同步值，需显式 `clock reset` 拨回纪元）
并记录恢复路径；标记行 `$$$ ONVIF LAB03 AUTH <result> user=<u>`。

### lab04-media-snapshot —— Media Profile 与快照【ch05】

GetProfiles 返回单一 profile（token 固定 `profile_1`，MJPEG 编码档）；GetSnapshotUri
指向 `/onvif-http/snapshot`。快照实现：从最新帧双缓冲拷贝最近一帧编码 JPEG。
验收：curl 落地 JPEG 文件、`file`/`ffprobe` 确认 JPEG 完整性；python-onvif 拿到
Profile 与 SnapshotUri；标记行 `$$$ ONVIF LAB04 SNAPSHOT bytes=<n>`。

### lab05-rtsp-mjpeg —— RTSP/RTP 取流全链【ch06】

新建 `rtsp_server` 模块（raw socket，逐连接串行，单客户端语义）：OPTIONS/DESCRIBE（SDP
m=video RTP/AVP 26）/SETUP（先 TCP interleaved，UDP 第二档）/PLAY/TEARDOWN；MJPEG 按
RFC 2435 封 RTP（量化表与编码器输出对齐，抓包逐字节校验头 8 字节）。验收：ffplay/VLC
出图；帧计数对账——板端 `frames_sent` ↔ 宿主解码 JPEG EOI 计数一致（沿用
esp32-video-tran 方法学）；12 秒采样窗口无丢帧；标记行 `$$$ ONVIF LAB05 FRAME seq=<n> bytes=<n>`。

### lab06-interop-harness —— 互通收口【ch09】

总装前五个 lab 的完整固件；witness：**Home Assistant 或 Frigate 以 ONVIF 集成完成
发现→凭据→取流三步，零手工填 URL**。验收：HA 设备页/Frigate camera 配置与实时画面
证据入 README；tcpdump 三断面（3702/80/8554）各留一段对账；标记行
`$$$ ONVIF LAB06 WITNESS <ha|frigate> result=<ok|fail>`。可选扩展（不进主链验收）：
PullPoint 事件（帧差运动检测）、G.711 前向音频（板载 ES8389）。

## 7. 通用验收清单（一票否决项在前）

1. README 缺失或无中文说明 = 否决（目的、拓扑 ASCII、构建/运行命令、**真实输出摘录**、边界）。
2. run.log 无真实上板输出、或输出与 README/方案章声称不符 = 否决。严禁编造。
3. 构建不满足离线可重复（dependencies.lock 未提交、registry 未锁版本）= 否决。
4. 日志 >1MB 未按本仓政策截断 = 否决（首 5000 行 + 关键证据行 + 尾 500 行 + 截断标注）。
5. prettier 未过 = 否决（交付前 `npx prettier <新文件> --write`）。
6. 违反 §4 内存红线（推流稳态 free_dma < 170KB 仍继续叠功能）= 打回。
7. 违反 §5 端口表或 XAddrs 写死 IP = 打回。
8. 加分项：坏 case 实验矩阵（错凭据/重放/时钟漂移/断网重连）、机器可读标记行覆盖全部
   关键事件、XML 应答样本归档（`runs/` 下按操作名存样）。
