---
title: "ONVIF 深度解析（十一）：实战方案——把 ONVIF 设备端装进 ESP32-S31-Korvo-1"
date: 2026-10-25 12:00:00
description: "实战篇开题：前十章拆轮子，本章反着装——以 esp32-video-tran 已烤机验证的摄像头→PPA→硬件 JPEG→WiFi 推流管线为媒体面底牌，规划 ONVIF 设备端三件套（WS-Discovery 应答、SOAP 控制面最小集、RTSP MJPEG 取流）的固件架构、六个里程碑、风险清单与互通验收方法；含诚实的边界声明：无 PTZ、无 H.264、不追徽标只追互通。工程契约见 practice/onvif-labs/SPEC.md。"
tags: [onvif, esp32, rtsp, embedded, series]
---

> [!info] ONVIF 深度解析系列 0. [[onvif-deep-dive|系列索引]] … 10. [[ch10-design-lessons|第十章]] 11. **第十一章：实战方案**

# ONVIF 深度解析（十一）：实战方案——把 ONVIF 设备端装进 ESP32-S31-Korvo-1

前十章都在**拆**轮子：发现（[[ch02-ws-discovery|第二章]]）、控制（[[ch03-soap-services|第三章]]–[[ch05-media-profiles|第五章]]）、媒体（[[ch06-rtsp-streaming|第六章]]）、生态（[[ch09-interop-ecosystem|第九章]]）。这一章反着来——**装**：把 ONVIF 设备端的三件套装进手头一块开发板，让它变成局域网里一台可被发现、可被查询、可被认证、可被取流的「ONVIF 摄像机」。NVR/平台侧视角我们已经讲透了，设备侧自己下场造一台，协议的每一条必选项都会变成「我到底实现了没有」的诚实拷问。

方案的工程契约（环境硬事实、目录约定、端口分配、验收清单）已按本仓惯例先立 SPEC：[practice/onvif-labs/SPEC.md](/static/code/#/onvif-labs/SPEC.md)（[GitHub 源](https://github.com/hlwqds/hl-ljj-quartz/blob/v4/practice/onvif-labs/SPEC.md)）。本文是方案叙事，SPEC 是可执行契约，两者不重复论证。

## 11.1 硬件底牌：为什么这块板有资格

板卡：**ESP32-S31-Korvo-1**（IDF target `esp32s31`，RISC-V；固件工具链实报的板卡实名）。它的关键不是参数表，而是**媒体面已经被烤机验证过**——本仓 esp32-video-tran 工作区（`~/code/esp32-video-tran/`，本机工作区不入博客仓，复跑手册见其 `RUNBOOK.md`）在这块板上跑通过「摄像头 → PPA 缩放 → 硬件 JPEG → WiFi 推流」全链：

| 底牌         | 实测事实                                                                                                                      | 对 ONVIF 的意义                         |
| ------------ | ----------------------------------------------------------------------------------------------------------------------------- | --------------------------------------- |
| 摄像头       | SmartSens SC101IOT（PID 0xda4a），640×480 UYVY（官方资料写 OV3660，以芯片自报为准）                                           | 采集端不用写一行驱动                    |
| 缩放         | PPA 硬件缩放器（640×480 → 240×240 canvas 实证）                                                                               | 给 RTSP 档位做低分辨率副本零 CPU 成本   |
| 编码         | 硬件 JPEG 编码器（esp_new_jpeg 组件），平均 25,165 B/帧                                                                       | MJPEG 媒体面的像素来源已解决            |
| WiFi 吞吐    | MJPEG 推流 13.75 fps / 2.77 Mbps；30 分钟烤机均值 13.51 fps，0 重启 0 断连                                                    | 编码侧上限 16.667 fps，瓶颈在 2.4G 空口 |
| 内存         | 16MB Octal PSRAM + 16MB flash；推流稳态实测 free_dma ≈ 190KB（30min 烤机 190,039→190,627 B；teardown 后起 WiFi 前 269–293KB） | XML 缓冲进 PSRAM，内部 RAM 留给 WiFi    |
| 音频（可选） | 板载 ES8389 codec（出厂 demo 验证过音频通路）                                                                                 | 给 G.711 前向音频留了门，见 11.4 lab06  |

结论一句话：**媒体面（三件套的第三件）已存在且被验证，实战的全部增量在协议面**——发现、控制、以及把 HTTP MJPEG 换成 RTSP/RTP。这正是前十章拆过的那三层，一一对应。

## 11.2 目标形态与诚实的边界

目标形态：一台**局域网自立的 ONVIF 取流设备**——上电连 WiFi，NVR/客户端发 Probe 它应答，带凭据查询它给信息，`GetStreamUri` 领地址后 VLC/ffmpeg 直接出图，Home Assistant/Frigate 能当一台普通 ONVIF 摄像机接入。

诚实的边界先立好（每条都有硬件或工程理由，不做能力伪装——[[ch09-interop-ecosystem|第九章]]刚审判过伪装者）：

| 不做                               | 理由                                                                                 |
| ---------------------------------- | ------------------------------------------------------------------------------------ |
| PTZ（[[ch07-ptz-events\|第七章]]） | 板上没有云台，也没有可映射的执行机构；裸实现只会产出 ActionNotSupported 之外的假能力 |
| H.264/H.265                        | 芯片没有视频编码器，MJPEG（Profile T 的编码面）是唯一诚实选项                        |
| Profile 徽标合规                   | 官方 Device Test Tool 会员专属；目标定「被主流客户端互通」，不追认证                 |
| HTTPS/TLS 控制面                   | 第一期走内网明文 SOAP（局域网实验形态）；TLS 列为后续增强不进里程碑                  |

Profile 定位按 [[ch01-onvif-overview|第一章]]的读法：**Profile S 的取流最小子集 + Profile T 的 MJPEG 编码面**，互通性以实测为准——「标称当广告、探测当合同」同样约束我们自己。MJPEG 在 ONVIF 客户端生态的支持度参差（部分 NVR 只认 H.264），这是 11.5 风险表的第一条；兜底路径是保留现有 `/stream` HTTP MJPEG 端点作为非 ONVIF 对照面。

## 11.3 架构：三层栈映射成固件三个模块

```text
ONVIF 三件套（前十章）            固件模块（新建/复用）
─────────────────────────        ─────────────────────────────────────
发现  WS-Discovery        ──→    disc responder：UDP 3702 组播应答（新）
控制  SOAP/WSDL over HTTP ──→    onvif svc：单 httpd 挂 /onvif/* URI（新）
        Device 服务                （模板 XML + 定向解析，不引 XML 库）
        Media 服务/Profile
        WS-Security 摘要认证       （mbedTLS SHA1 + nonce 缓存 + SNTP 对时）
媒体  RTSP/RTP            ──→    rtsp server：8554 端口 raw socket（新）
        MJPEG 按 RFC 2435 封 RTP   ──┐
媒体  采集→PPA→JPEG 编码   ──→    factory_stream 管线（复用，已烤机验证）
        最新帧双缓冲 + 帧到达钩子 ──┘ 两路消费者：快照 / RTP 封包
```

三个关键决策：

1. **基座 = 裁剪版 factory_demo**。采集→PPA→JPEG→双缓冲这条管线带着 `esp_video`/`esp_cam_sensor`/`esp_new_jpeg` 组件树和传感器时序，已被 30 分钟烤机验证——重写零收益、引入新风险纯负收益。裁掉 LVGL/UI 与 mmap 资产分区，保留双模形态的 teardown 纪律（LVGL 与 WiFi 驱动抢同一池内部 DMA RAM，这是 esp32-video-tran 实测出的最大内存教训）。
2. **控制面不引 XML/gSOAP 栈**。设备端要应答的操作是有限白名单（约 10 个），模板字符串 + 定向提取（SOAPAction 头 + Body 首子节点名）足够；换来的是完全可控的内存足迹与报文格式。客户端侧的宽松解析教训（[[ch09-interop-ecosystem|第九章]]坑 5）反过来约束我们自己：应答报文严格按 WSDL 的命名空间来，一行不多；信封版本跟随请求（1.1/1.2 双壳模板、Body 共用——python-onvif-zeep 按绑定强校验回信信封，纯 1.1 会挂自家验收，成文期决策见第十三章）。
3. **RTSP 独立端口 + TCP interleaved 优先**。8554 端口 raw socket 自己写信令（OPTIONS/DESCRIBE/SETUP/PLAY/TEARDOWN，报文格式见 [[ch06-rtsp-streaming|第六章]]），传输先做 RTP/AVP/TCP 交织（单连接、无 UDP 端口对协商， NAT/防火墙面最小），UDP 传输作为第二档。MJPEG 按 RFC 2435 封 RTP：25KB 帧 ÷ 1400B 载荷 ≈ 18 包/帧，13–15 fps 下约 250 包/秒——远在 WiFi 实测吞吐余量之内。

WS-Security（[[ch04-ws-security-auth|第四章]]）的设备侧实现与客户端推导完全对称：`PasswordDigest = Base64(SHA1(Nonce + Created + Password))`，外加两条设备侧纪律——nonce 环形缓存做重放拒绝、免鉴权的 `GetSystemDateAndTime` 做时钟对表（[[ch09-interop-ecosystem|第九章]]坑 1 的治本组合：SNTP 启动同步 + 校验窗口）。

## 11.4 里程碑：六个 lab

每个 lab 一个独立工程（`practice/onvif-labs/labNN-slug/`），自带上板运行日志与互通证据；「先成文后实跑」，工程随落地逐个入库并在本章回填深链。

| Lab                   | 交付                                                                                            | 对应章节                           |
| --------------------- | ----------------------------------------------------------------------------------------------- | ---------------------------------- |
| lab01-discovery       | Probe→ProbeMatch 应答，被 wsdiscovery 探到，Scopes 自报能力                                     | [[ch02-ws-discovery\|第二章]]      |
| lab02-device-service  | 免鉴权四连（GetSystemDateAndTime/GetDeviceInformation/GetServices/GetCapabilities）+ 合规 Fault | [[ch03-soap-services\|第三章]]     |
| lab03-auth-digest     | WS-Security 摘要认证 + nonce 防重放 + 时钟漂移实验复现                                          | [[ch04-ws-security-auth\|第四章]]  |
| lab04-media-snapshot  | GetProfiles/GetSnapshotUri，curl 拉到真实 JPEG 快照                                             | [[ch05-media-profiles\|第五章]]    |
| lab05-rtsp-mjpeg      | RTSP 全链（DESCRIBE/SETUP/PLAY），ffplay/VLC 出图，帧计数板宿对账                               | [[ch06-rtsp-streaming\|第六章]]    |
| lab06-interop-harness | Home Assistant 或 Frigate 以 ONVIF 集成完整接入（发现→凭据→流）                                 | [[ch09-interop-ecosystem\|第九章]] |

> [!tip] lab01 已落地（2026-10-25 上板验收通过）
> 工程：[practice/onvif-labs/lab01-discovery](/static/code/#/onvif-labs/lab01-discovery/README.md)
> （README 含拓扑/复现命令/实测摘录）· 应答器实现：[main/onvif_disc.c](/static/code/#/onvif-labs/lab01-discovery/main/onvif_disc.c)
> · 工程契约：[SPEC](/static/code/#/onvif-labs/SPEC.md)。
> 实测要点：单播直探 4/4 ProbeMatch（UUID/XAddrs/Types 全对）；组播 Probe 板端 4/4 收到并回包
> （`$$$ ONVIF LAB01 PROBEMATCH` 标记行入 run.log），家庭 AP 组播回包路径不对称已记录为工程边界。

两个里程碑刻意「先难后易」地拆：lab03 把认证单独成站，是因为时钟与重放是设备侧最容易翻车的组合（故意把 SNTP 关掉复现 NotAuthorized，比一次做对更有教学价值）；lab05 单独成站，是因为 RTSP 信令与 RTP 封包是全新代码，需要帧计数对账（复用 esp32-video-tran 的板端 `frames_sent` ↔ 宿主 JPEG EOI 计数方法学）来证明「每一帧都完整到达」。事件（PullPoint 订阅 + 简单帧差运动检测，[[ch07-ptz-events|第七章]]的三模型之一）与 G.711 前向音频（板载 ES8389）列为 lab06 之后的可选扩展，不进主链。

## 11.5 风险清单

| 风险                                | 影响                                   | 缓解                                                                     |
| ----------------------------------- | -------------------------------------- | ------------------------------------------------------------------------ |
| MJPEG 的客户端支持参差              | 部分 NVR 发现后无法出图                | 目标客户端先锁定 VLC/ffmpeg/HA/Frigate（实测认 MJPEG）；保留 HTTP 对照面 |
| RFC 2435 对 JPEG 量化表的约束       | 封包参数与编码器输出不匹配即花屏       | lab05 先固定编码 Q 档再定 RFC 2435 表头，抓包逐字节对账                  |
| 内部 DMA 堆预算                     | WiFi 静态缓冲饥饿致 esp_wifi_init 失败 | ONVIF 新增缓冲一律 PSRAM；保持 stream-first 形态与 teardown 纪律         |
| esp32s31 是 IDF preview target      | 组件兼容性随 IDF 版本漂移              | 固化 dependencies.lock 与本地补丁副本；升级 IDF 视为新基线重跑烤机       |
| 时钟漂移致鉴权失败（ch09 坑 1）     | 密码正确仍 NotAuthorized               | SNTP 启动同步 + 免鉴权对表 + 校验窗口做成 lab03 的显式实验               |
| 严格客户端对报文的挑剔（坑 5/坑 6） | zeep/HA 反序列化失败                   | 应答以 python-onvif-zeep 为第一验收客户端，逐操作留 XML 样本             |

## 11.6 验收方法

宿主侧工具链全套沿用 [[ch09-interop-ecosystem|第九章]]的工作流：`wsdiscovery` 探测、python-onvif-zeep 逐操作冒烟、zeep 传输层日志 + tcpdump（3702/80/8554 三个断面）三层对账、ffplay/ffmpeg 验流。每个 lab 的 run.log 必须含机器可读标记行（`$$$ ONVIF LABnn …`，格式见 SPEC）与真实互通输出——python-onvif 的返回对象、VLC 截帧、HA 的设备页截图式证据。最终 witness 定为：**Home Assistant 或 Frigate 在零手工配置 URL 的前提下，通过 ONVIF 集成完成发现、认证、取流三步**——这是「一台普通 ONVIF 摄像机」定义的操作化。

## 11.7 小结

- 媒体面底牌已在手：SC101IOT 采集 → PPA → 硬件 JPEG → WiFi MJPEG 推流（13.51–13.75 fps，烤机零故障），实战增量全部在协议面。
- 架构三决策：裁剪版 factory_demo 做基座、模板 XML 不引栈、RTSP 独立端口 + TCP interleaved 优先。
- 边界诚实：无 PTZ、无 H.264、不追徽标；Profile S 取流最小子集 + Profile T 的 MJPEG 编码面，互通为准。
- 六个里程碑对应前六章的协议栈层级，最终以 HA/Frigate 零手工接入 witness 收口。

方案至此成文，工程契约见 [practice/onvif-labs/SPEC.md](/static/code/#/onvif-labs/SPEC.md)。实战篇的后续章节将随 lab01–lab06 的落地逐个补齐——每章一个 lab 的实测实录，与本文的规划对账。回到 [[onvif-deep-dive|系列索引]]。
