---
title: "ONVIF 深度解析（八）：录像与回放——Profile G 与 NVR 侧视角"
date: 2026-10-10 12:00:00
description: "录像侧解剖：Profile G 圈定的能力域（录像创建与管理、检索、回放、导出）；Recording 服务的对象模型——RecordingConfiguration 的来源与保留策略、Video/Audio/Metadata 三种 Track、RecordingJob 的模式/优先级抢占与计划事件触发；Find* 会话式检索的事件索引搜索与正反向时间过滤；Replay 服务 GetReplayUri 与 RTSP 的 clock Range、Scale/Rate-Control 控速——与取流同构的控制面发地址、媒体面拉流；ExportRecordedData 导出与 GetStorageConfigurations 存储管理；NVR 侧视角——一台 NVR 的 ONVIF 面如何既当客户端又当服务端。"
tags: [onvif, profile-g, nvr, recording, rtsp, series]
---

> [!info] ONVIF 深度解析系列 0. [[onvif-deep-dive|系列索引]] 1. [[ch01-onvif-overview|第一章]] … 7. [[ch07-ptz-events|第七章]] 8. **第八章：录像与回放**

# ONVIF 深度解析（八）：录像与回放——Profile G 与 NVR 侧视角

前七章的设备都活在「现在时」：发现它、跟它认证、配 Profile、拉实时流、转云台、收事件。这一章把时间轴翻向过去：**录像怎么被标准化地创建、怎么检索、怎么回放、怎么导出**——以及视角切换带来的新问题：做这些事的往往不再是摄像机，而是 NVR（或带 SD 卡的边缘存储摄像机），于是我们第一次站到「记录者」一侧看 ONVIF 的另一张面孔。

---

## 8.1 Profile G：给设备加上「过去时」

Profile G 在 S 立稳之后数年才加入（2015 年），圈定的能力域可以概括为四块，恰好对应一组成套的服务——其中 `tse`/`trp` 是新面孔（ch03 的词典已补）：

| 能力块         | 干什么                                    | 承载服务                      |
| -------------- | ----------------------------------------- | ----------------------------- |
| 录像创建与管理 | 建/删录像与轨道、配保留策略、调度录像作业 | Recording（`trc`）            |
| 检索           | 按来源/时间/事件找录像、找事件、找元数据  | Search（`tse`）               |
| 回放           | 把录像段作为媒体流放出来                  | Replay（`trp`）               |
| 导出与存储     | 导出可交换文件、管理存储位置              | Recording + 设备服务（`tds`） |

G 设备的两种典型形态：**NVR**（多路集中录像）与**边缘存储摄像机**（机身 SD 卡，断网也能录）。实践中 NVR 常同时标注 S 与 G——既能被实时取流，又能提供录像检索回放，两块能力各管一段。与 S 对照着记：

|          | Profile S（ch05/ch06） | Profile G（本章）                  |
| -------- | ---------------------- | ---------------------------------- |
| 时间态   | 现在时（live）         | 过去时（recorded）                 |
| 核心对象 | Media Profile          | Recording / Track / RecordingJob   |
| 拿到画面 | GetStreamUri           | GetReplayUri + RTSP clock Range    |
| 主键     | 设备 + Profile token   | RecordingToken（一段有来源的历史） |

最后一行是全章的题眼：**G 的世界里主键不再是「设备」而是「一段录像」**——来源设备只是录像的一个属性。8.6 会回到这一点。

## 8.2 Recording 服务的对象模型：一录、三轨、若干作业

Recording 服务把「录像」拆成三个正交概念——**录像（存什么、留多久）、轨道（数据在哪儿）、作业（谁在何时往轨道里灌数据）**：

```text
Recording（RecordingToken）
├── RecordingConfiguration   来源描述 + 保留策略
├── Track × N                数据真的躺在这儿，每轨一种类型
│   ├── VIDEO001   TrackType = Video
│   ├── AUDIO001   TrackType = Audio
│   └── META001    TrackType = Metadata
└── RecordingJob × N         调度单元：何时录、从哪录、录到哪条轨
```

**RecordingConfiguration** 回答「这段录像从哪来、留多久」：

```xml
<trc:RecordingConfiguration>
  <trc:Source>
    <tt:SourceId>urn:uuid:6f2a...</tt:SourceId>
    <tt:Name>前门枪机</tt:Name>
    <tt:Location>1 号楼大堂</tt:Location>
    <tt:Description>主码流 7×24</tt:Description>
    <tt:Address>http://192.168.1.64/onvif/device_service</tt:Address>
  </trc:Source>
  <tt:MaximumRetentionTime>PT72H</tt:MaximumRetentionTime>
</trc:RecordingConfiguration>
```

Source 的六个字段里，`Address` 指向来源设备的设备服务端点——检索结果里它就是「这段录像出自哪台设备」的凭证。`MaximumRetentionTime` 是 xs:duration（示例即保留 72 小时）：设为 `PT0S` 表示不限保留，但规范同时写明——无论如何设置，设备仍可为给新录像腾地方而自动删除旧数据。**保留策略是上限不是承诺**。

**TrackConfiguration** 的灵魂是 `TrackType` 枚举：只有 **Video / Audio / Metadata** 三个正式值（另有 Extended 占位），且规范明文规定**轨道只能装本类型的数据**。三种 track 各自的含义：视频帧序列、音频序列、元数据序列（含 ch07 的事件与分析结果——它们被录进 Metadata 轨，是 8.3 事件检索的物理基础）。规范的示例还给出一个工程便利：**CreateRecording 会隐式创建 A/V/M 三条轨道**，track token 预定义为 `VIDEO001`/`AUDIO001`/`META001`——最简录像不需要 CreateTrack；要录第二路码流时才加轨。

**RecordingJob** 回答「何时录」：`Mode` 只有 **Idle / Active** 两个合法值；`Priority` 为非负整数，多个作业写同一条轨道时**只有最高优先级者生效**（同优先级行为未定义）。每个 Source 项把「来源 + 源标签」映射到目的轨道（`SourceTag` → `Destination`），并可置 `AutoCreateReceiver` 让设备自动建好收流接收器（8.6 展开）。两个可选开关把「何时录」变成可编程的：

- **ScheduleToken**：把作业挂到 Schedule 服务的某个计划上——**计划存在且活跃才录**，这就是「按计划录」的标准做法；
- **EventFilter**：事件触发录像，配合前后预录（BeforeEvent/AfterEvent，设备上限由能力的 `BeforeEventLimit`/`AfterEventLimit` 报出）。

排错第一站是 **GetRecordingJobState**：track 级状态为 Idle/Active/Error——配置成功不等于真的在录，状态要问出来。

## 8.3 检索：Find\* 的会话式搜索与事件索引

Search 服务没有「搜一次返回一页」的简单模式，而是**会话式增量**——Find 发起、轮询取批、显式结束：

```text
客户端                                       设备（Search 服务）
  │  FindRecordings / FindEvents / ...           │
  ├─────────────────────────────────────────→   │ 建搜索会话（异步开搜）
  │  ←──────────── SearchToken ──────────────    │
  │  Get*SearchResults(SearchToken, MaxResults)  │
  ├─────────────────────────────────────────→   │ 增量取结果（不重复已给过的）
  │  ←──────────── 结果批（可阻塞攒批）──────    │
  │  ... 循环直至搜索状态 Completed              │
  ├──────── EndSearch(SearchToken) ────────→     │ 结束（或 KeepAliveTime 超时自灭）
```

规范定义了**四对** Find/GetResult 操作：

| Find 操作       | 找什么                                       | 取结果                      |
| --------------- | -------------------------------------------- | --------------------------- |
| FindRecordings  | 录像（结果按 recording 计数）                | GetRecordingSearchResults   |
| FindEvents      | 事件：recording event 与录在轨道里的其他事件 | GetEventSearchResults       |
| FindPTZPosition | 云台位置历史                                 | GetPTZPositionSearchResults |
| FindMetadata    | 元数据轨迹                                   | GetMetadataSearchResults    |

一个容易踩的命名误会：坊间常说的「FindTracks」在现行 WSDL 里**查无此操作**——落到单条轨道级的数据定位，规范的原话是「For viewing individual recorded data for a single track use the FindEvents method」：轨道级检索由 FindEvents / FindMetadata 承担。

**范围与时间**分居两处：`Scope`（SearchScope）圈数据集——`IncludedSources`（哪些来源）、`IncludedRecordings`（哪些录像）、`RecordingInformationFilter`（XPath 对录像信息再过滤）；时间窗则直接放在请求上：`StartPoint` → `EndPoint`，**终点早于起点即反向搜索**（新到旧，适合「只要最近一次匹配」），不给终点则一律正向。以 FindEvents 为例（字段名与类型取自 WSDL，过滤内容为示意）：

```xml
<tse:FindEvents>
  <tse:StartPoint>2026-10-09T18:00:00Z</tse:StartPoint>
  <tse:EndPoint>2026-10-10T06:00:00Z</tse:EndPoint>
  <tse:Scope>
    <tse:IncludedRecordings>REC-1F2A</tse:IncludedRecordings>
  </tse:Scope>
  <!-- SearchFilter 为 topic/消息过滤器（XPath 方言，与 ch07 事件订阅的过滤同族） -->
  <tse:SearchFilter>//tt:Motion</tse:SearchFilter>
  <tse:IncludeStartState>true</tse:IncludeStartState>
  <tse:MaxMatches>100</tse:MaxMatches>
  <tse:KeepAliveTime>PT30S</tse:KeepAliveTime>
</tse:FindEvents>
```

「事件索引式搜索」的精髓在最后两行的配合：**recording event 一律表示成 notification + topic**——无论它来自元数据轨道、设备内部机制还是客户端回填，搜索过滤器面对的都是统一的事件视图；而 `IncludeStartState` 让服务器**即时构造虚拟起始态事件**（recording events 强制支持，其余看 GeneralStartEvents 能力；反向搜索时起止两端都会给）。虚拟事件的用处很实际：回放器拖到任意时间点，第一刷结果就能拿到「此刻各属性事件处于什么状态」——**搜的是索引，不是扫流**。

## 8.4 回放：GetReplayUri 与 RTSP 的 clock 时间轴

回放与取流是**同一个模式的两份实例**：控制面发地址、媒体面拉流（ch06）。GetReplayUri 的入参几乎是 GetStreamUri 的镜像，只是把 Profile token 换成 Recording token：

```xml
<trp:GetReplayUri>
  <trp:StreamSetup>
    <tt:Stream>RTP-Unicast</tt:Stream>              <!-- 与 ch06 GetStreamUri 同款枚举 -->
    <tt:Transport><tt:Protocol>RTSP</tt:Protocol></tt:Transport>
  </trp:StreamSetup>
  <trp:RecordingToken>REC-1F2A</trp:RecordingToken>
</trp:GetReplayUri>
```

应答一个 `rtsp://` 地址；DESCRIBE/SETUP 照常走，差别全在 **PLAY**——ONVIF 在这里加了自己的扩展头（以下为规范原文报文的骨架）：

```text
PLAY rtsp://192.168.0.1/path/to/recording RTSP/1.0
Cseq: 123
Session: 12345678
Require: onvif-replay
Range: clock=20261009T180000.000Z-20261010T060000Z
Rate-Control: no
```

- **`Require: onvif-replay`**：声明本次会话启用 ONVIF 回放扩展，规范的回放示例皆带此头；
- **`Range: clock=...`**：RTSP 原生时间轴是相对的（npt），回放需要绝对墙钟——ONVIF 用 RFC 2326 的 utc 区间把「录像的哪一段」钉死。开/闭区间皆可；闭区间正向递增、倒放递减，**方向必须与 Scale 一致**；区间第一个点就是回放起点；
- 帧与真实时间的锚不止这一处：**RTP 扩展头里带 NTP 时间戳，对应原始采集时的墙钟**——回放流的每一帧都能对回它被录下的那一刻。

**速度与方向控制**是一张三件套：

| 头                       | 语义                                                             | 备注                          |
| ------------------------ | ---------------------------------------------------------------- | ----------------------------- |
| `Rate-Control: no`       | 客户端控速：服务器尽快发，RTP 时间戳沿用原始采集时间             | ONVIF 服务器**必须**支持      |
| `Rate-Control: yes`/缺省 | 服务器控速：按播放时序打 RTP 时间戳，间隔由 Scale/Speed 共同决定 | 非 ONVIF 客户端的默认路径     |
| `Scale: -1.0`            | 倒放（需 Replay 能力的 ReversePlayback 位）                      | Rate-Control=no 时只允许 ±1.0 |
| `Immediate: yes`         | 播放中换起点，新起点首包置 D（不连续）位                         | seek 的标准姿势               |

倒放的传输规则最能体现工程细致：**GOP 之间倒序、GOP 之内正序**（解码器才解得开），每个 GOP 首包带 D 位，可用片段末尾带 E 位；音频倒放没有意义，规范直言一般不传。

观察回放会话不需要私有工具：

```bash
# 抓 RTSP 回放信令（TCP 554）
tcpdump -i eth0 -vvv -s0 'tcp port 554'
# Wireshark：rtsp 协议过滤，展开 PLAY 请求即可见 Range/Scale/Rate-Control
#   rtsp && ip.addr == 192.168.1.64
# 拿到 GetReplayUri 应答的地址后可直接拉流播放（URI 形态因设备而异）
ffplay rtsp://192.168.1.64/onvif-replay/REC-1F2A
```

看点清单：PLAY 请求与应答里 Range 的回显；`Require: onvif-replay` 是否被服务器接受；不带 Range 时设备从哪里起播（由实现决定，想要精确窗口就显式带 Range）。

## 8.5 导出与存储管理

检索和回放都是「到设备上看」，**导出是「带走」**——证据固定、离线分析、跨系统归档都靠它。

**存储在哪**：设备服务（tds，回到 ch03 的词典）的 **GetStorageConfigurations** 列出设备的存储配置，`StorageConfiguration.Data` 两种形态：`LocalPath`（本地 SD 卡/磁盘路径）与 `StorageUri`（网络存储地址，`User` 为访问凭据位）。新一代 RecordingConfiguration 还可携带 **Target**：引用 storage token，并附 Format、SegmentDuration、Prefix/Postfix 等——把录像直接指到外置存储目标上录。

**怎么导出**：现行 WSDL 里的名字是 **ExportRecordedData**——五个参数 `StartPoint`/`EndPoint`/`SearchScope`/`FileFormat`/`StorageDestination`，语义自明：把范围内命中的录像按指定格式导到指定存储位；配套 **GetExportRecordedDataState** 轮询进度、**StopExportRecordedData** 中止，另有分段导出的 **ExportRecordedSegments**。又一处命名陷阱：不少资料把导出记作 ExportRecordings，**该操作在现行 WSDL 中查无此名**——以 WSDL 为准。导出文件的容器格式由独立的 ExportFileFormat 规范定义（跨厂商可交换），设备支持哪些格式看能力里的 `SupportedExportFileFormats`。

## 8.6 NVR 侧视角：一台 NVR 的 ONVIF 面是两面镜子

前七章我们始终站在「被连接者」（摄像机）一侧。装上 G 之后，把镜头摇向 NVR，会发现它的 ONVIF 面**同时朝两个方向**：

```text
            ┌──────────────────────────── NVR ────────────────────────────┐
 前端摄像机  │ 客户端面孔：Probe 发现、四连问、GetStreamUri 拉流、订阅事件     │
   × N ───→ │ 录像引擎：  Receiver 收流 → Track 落盘 → Job 调度             │
            │ 服务端面孔：Recording / Search / Replay / Export（8.1–8.5）   │
            └───────────────────────────────────────────────────────────────┘
                                     ↓
                     上层平台 / VMS / 播放器（把 NVR 当一台 G 设备用）
```

规范自己的「单摄像机录像」示例把上半张脸讲透了（原文为伪代码，此处意译）：

```text
; 1) 建录像——隐式带出 VIDEO001/AUDIO001/META001 三条轨道
RecordToken = CreateRecording(RecordConfiguration)
; 2) 建录像作业——AutoCreateReceiver 让 NVR 自动建好从远端收流的接收器
JobToken, ActualJobConfig = CreateRecordingJob(JobConfiguration)
; 3) 配置接收器——指向那台摄像机
ConfigureReceiver(ActualJobConfig.ReceiverToken, ReceiverConfiguration)
; 4) 真正开录——NVR 主动向摄像机发起 RTSP 连接
SetRecordingJobMode(JobToken, Active)
```

配置持久化，此后起停录像只需 SetRecordingJobMode 在 Idle/Active 间切换。四个能力项在 NVR 身上各出现两次：

| 能力 | 摄像机侧（被记录者）             | NVR 侧（记录者）                                   |
| ---- | -------------------------------- | -------------------------------------------------- |
| 发现 | 应答 Probe、上线发 Hello（ch02） | 发 Probe、维护设备表                               |
| 取流 | GetStreamUri 供流（ch06）        | 消费 GetStreamUri，同时对外供 GetReplayUri         |
| 事件 | 被订阅、发通知（ch07）           | 订阅者，再把事件录进 Metadata 轨供 FindEvents 检索 |
| 身份 | 主要是 Profile S/T 设备          | 主要是 Profile G 设备（常兼 S）                    |

一句话收束：**NVR 是把 N 路 S 设备聚合、重发布成一台 G 设备的桥**。这也解释了 8.1 留下的题眼——G 的主键是 RecordingToken 而非设备：检索与回放面向的是「一段有来源的历史」，来源信息（Source.Address）只是这段历史的注脚。

## 8.7 小结

- Profile G 给设备加上「过去时」，四块能力对应三套服务：Recording（`trc`）管录像与导出、Search（`tse`）管检索、Replay（`trp`）管回放；G 设备的两种形态是 NVR 与边缘存储摄像机。
- 对象模型是「一录三轨若干作业」：RecordingConfiguration 定来源与保留上限（`PT0S` = 不限，但保留是上限不是承诺）；Track 只装 Video/Audio/Metadata 本类数据，CreateRecording 隐式建三轨；Job 用 Idle/Active 起停、Priority 抢轨道、ScheduleToken/EventFilter 定「何时录」。
- 检索是会话式增量：Find* 拿 SearchToken，Get*SearchResults 分批取且不重复，EndSearch/KeepAliveTime 收尾；四对 Find 操作里**没有 FindTracks**——轨道级定位走 FindEvents/FindMetadata；终点早于起点即反向搜索；IncludeStartState 的虚拟事件让任意时间点都能立刻拿到属性状态——搜的是索引不是扫流。
- 回放与取流同构：GetReplayUri 领 rtsp:// 地址，PLAY 里 `Require: onvif-replay` + `Range: clock=` 钉绝对时间窗（闭区间方向随 Scale）；Rate-Control/Scale/Speed 三件套控速（服务器必须支持 Rate-Control=no，此时 Scale 只允许 ±1.0）；倒放 GOP 间倒序、GOP 内正序；RTP 扩展头 NTP 时间戳把帧锚回原始墙钟。
- 导出现行名是 ExportRecordedData/ExportRecordedSegments（坊间的 ExportRecordings 查无此名）；存储两形态 LocalPath/StorageUri，新代 Target 可把录像指到外置目标。
- NVR 的 ONVIF 面是两面镜子：对摄像机是 ch02–ch07 的那个客户端，对上层平台是本章的服务端——它把 N 路 S 设备聚合重发布成一台 G 设备，所以 G 用 RecordingToken 而非设备做主键。

单台设备的拼图至此完整：发现、认证、配置、取流、控制、事件、录像回放。但标准写得再好，也要看设备兑现成色——下一章拿真工具验收：官方测试工具怎么跑、互通兼容性的高频坑（伪装 Profile、私有 SDK 子集投影）、以及 gSOAP/zeep 一线的开源生态。[[ch09-interop-ecosystem|第九章：互通实战]]。
