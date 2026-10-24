---
title: "ONVIF 深度解析（七）：PTZ 与事件——云台控制和三种通知模型"
date: 2026-10-10 12:00:00
description: "PTZ 服务解剖：PTZNode/PTZConfiguration/PTZStatus 三件套与 ReferenceToken 的贯穿；ContinuousMove/Stop/AbsoluteMove/RelativeMove 操作族与 pan-tilt-zoom 空间的归一化表示；预置位的 token 语义；事件的三种通知模型——设备主动 POST 的 Basic Notification、客户端长轮询的 Pull-Point、RTSP 元数据流内嵌通知；WS-BaseNotification 报文结构与 tns1 话题树过滤；移动侦测触发 GotoPreset 的完整联动时序。"
tags: [onvif, ptz, events, ws-basenotification, soap, series]
---

> [!info] ONVIF 深度解析系列 0. [[onvif-deep-dive|系列索引]] 1. [[ch01-onvif-overview|第一章]] … 6. [[ch06-rtsp-streaming|第六章]] 7. **第七章：PTZ 与事件**

# ONVIF 深度解析（七）：PTZ 与事件——云台控制和三种通知模型

前六章的设备一直扮演「被动应答者」：被问、被配、被拉流。这一章给它两样新能力：**动**——PTZ 服务怎么用一套归一化坐标系驱动千差万别的云台机械（7.1–7.3）；**说话**——设备里随时发生的事件（移动侦测、信号丢失、规则触发）怎么送达客户端，为什么有三种通知模型、哪种最常用（7.4–7.5）。最后把两者拼成一个完整的联动时序：移动侦测事件触发云台转向预置位（7.6）。

---

## 7.1 PTZ 的对象模型：Node 讲能力，Configuration 讲参数，Status 讲现在

PTZ 服务不是机械云台的专利——**e-PTZ（数字云台）**用同一套接口在放大后的画面里做电子平移与裁剪，所以「支持 PTZ」看不出有没有电机，得看对象模型。三件套各管一层：

| 对象                 | 角色           | 关键内容                                                                                | 可写性         |
| -------------------- | -------------- | --------------------------------------------------------------------------------------- | -------------- |
| **PTZNode**          | 硬件能力说明书 | 支持的空间列表（pan-tilt 与 zoom 各自的位置/速度/位移空间）、最大预置位数、有无 Home 位 | 只读，出厂定死 |
| **PTZConfiguration** | 作业参数       | 限位（PanTiltLimits/ZoomLimits）、DefaultPTZSpeed、DefaultPTZTimeout、绑定的 NodeToken  | 客户端可 Set   |
| **PTZStatus**        | 运行时快照     | 当前 Position、MoveStatus（IDLE/MOVING/UNKNOWN）、Error、UtcTime                        | 设备产出，只读 |

它们与 Media Profile 的挂接关系（复习 [[ch05-media-profiles|第五章]]的三件套）：

```text
Media Profile
├── VideoSourceConfiguration ──SourceToken──► VideoSource（画面从哪来）
├── PTZConfiguration ◄── 客户端 Get/Set 的就是它
│     ├── NodeToken ──────► PTZNode（能做什么：哪些空间、几个预置位）
│     ├── PanTiltLimits / ZoomLimits（能去哪：限位矩形）
│     └── DefaultPTZSpeed / DefaultPTZTimeout（默认怎么动）
└── MetadataConfiguration（7.4 的第三种通知模型会用到它）
```

**ReferenceToken 在这里第二次展现贯穿力**（第一次是 ch03/ch05 的媒体配置）：所有 PTZ 操作的第一个参数都是 ProfileToken——设备顺着 Profile 找到 PTZConfiguration，再顺着 NodeToken 找到 Node，对着能力说明书执行动作。token 全部是设备分配的字符串（`Profile_1`、`PTZNode_1` 这类形态常见），客户端只引用、不发明。

## 7.2 操作族：速度说话的 Continuous，坐标说话的 Absolute/Relative

四个移动操作加一个查询，一张表认清：

| 操作               | 语义             | 参数要点                                           |
| ------------------ | ---------------- | -------------------------------------------------- |
| **ContinuousMove** | 按速度持续移动   | Velocity（[-1,1]，最大速度的百分比）+ 可选 Timeout |
| **Stop**           | 立即停止         | PanTilt/Zoom 两个布尔，各自分别刹                  |
| **AbsoluteMove**   | 去往绝对坐标     | Position（绝对位置空间）+ 可选 Speed               |
| **RelativeMove**   | 从当前位置挪增量 | Translation（位移空间）+ 可选 Speed                |
| **GetStatus**      | 查快照           | 返回 Position + MoveStatus                         |

关键是 7.1 埋下的「空间」概念。pan-tilt 是二维（x/y），zoom 是一维（x），但**同一物理量分好几种空间**：绝对位置空间、速度空间、位移空间——每种空间是一个 URI 加一个取值范围，由 PTZNode 的空间列表声明。最常用的通用空间把一切归一化到 [-1,1]：位置上 x=-1 是行程一端、+1 是另一端；速度上 0.5 表示「最大速度的一半」；方向约定为 x 向右、y 向上、zoom 放大为正。归一化的价值显而易见：客户端不必知道这台球机是 360 度连续旋转还是 ±90 度摆动、光学变焦几倍，写出的控制逻辑天然可移植。某设备真支持哪些空间，`GetNodes`/`GetNode` 翻空间列表即可——列表里没有位移空间，RelativeMove 就无从谈起。

ContinuousMove 的报文（速度空间登场）：

```xml
<!-- 前缀：tt=http://www.onvif.org/ver10/schema tptz=PTZ 服务命名空间 -->
<tptz:ContinuousMove>
  <tptz:ProfileToken>Profile_1</tptz:ProfileToken>
  <tptz:Velocity>
    <tt:PanTilt x="0.5" y="-0.3" space="http://www.onvif.org/ver10/tptz/PanTiltSpaces/VelocityGenericSpace"/>
    <tt:Zoom x="0.1" space="http://www.onvif.org/ver10/tptz/ZoomSpaces/VelocityGenericSpace"/>
  </tptz:Velocity>
  <tptz:Timeout>PT2S</tptz:Timeout>
</tptz:ContinuousMove>
```

语义要点：**速度是「油门」不是「坐标」**——0.5 指的是最大速度的一半，与当前在哪无关；Timeout（ISO 8601 时长）到期自动停，省略时多数设备用配置里的 DefaultPTZTimeout 兜底（实现有出入，ch09 审判）；撞上 7.1 的限位自动夹住；新的移动命令会打断进行中的移动。e-PTZ 设备同样遵守这套语义，只是「行程两端」变成了画面边缘。

AbsoluteMove 换成绝对位置空间：

```xml
<tptz:AbsoluteMove>
  <tptz:ProfileToken>Profile_1</tptz:ProfileToken>
  <tptz:Position>
    <tt:PanTilt x="0.25" y="-0.8" space="http://www.onvif.org/ver10/tptz/PanTiltSpaces/PositionGenericSpace"/>
    <tt:Zoom x="0.5" space="http://www.onvif.org/ver10/tptz/ZoomSpaces/PositionGenericSpace"/>
  </tptz:Position>
</tptz:AbsoluteMove>
```

RelativeMove 与之同构，只是 Position 换成 Translation、落在位移空间；两者的可选 Speed 省略时用 DefaultPTZSpeed。三类操作覆盖云台编程的全部姿势：按住方向键（Continuous）、指哪打哪（Absolute）、挪一格（Relative）——最后一种在巡逻步进、网格扫描这类逻辑里最顺手。

## 7.3 预置位与巡航：token 是设备给的，名字才是你起的

预置位 = 把当前 PTZ 坐标存成具名书签。核心操作：

```xml
<tptz:SetPreset>
  <tptz:ProfileToken>Profile_1</tptz:ProfileToken>
  <tptz:PresetName>door</tptz:PresetName>
</tptz:SetPreset>
<!-- 应答：设备分配的 token -->
<tptz:SetPresetResponse><tptz:PresetToken>3</tptz:PresetToken></tptz:SetPresetResponse>
<!-- GotoPreset/RemovePreset 同构：ProfileToken + PresetToken，一去一删 -->
```

分工很清楚：**名字是客户端起的，token 是设备分配的**（通常是数字串，设备侧唯一）。上限由 PTZNode 的 MaximumNumberOfPresets 声明，`GetPresets` 随时回查名册。两个实践坑：其一，对已存在的名字再 SetPreset，有的设备覆盖、有的报错，行为不统一——写代码前先 GetPresets 对名册更稳；其二，token 没有跨重启的持久化保证，设备重启后可能重排，**名字才是稳定的锚点**（登录后按名字反查 token 是稳妥套路）。

Home 位是特殊的「零号预置位」：SetHomePosition 用当前坐标设家，GotoHomePosition 一键回中——巡逻逻辑收尾的标配。至于多预置位定时巡航（Preset Tour），后续版本的 PTZ 规范补了相关操作，但实现面远不如预置位本身普及；复杂巡逻更常见的做法仍是客户端拿 GotoPreset 加定时器自己编排——控制面虽慢，逻辑完全在你手里。

## 7.4 事件的三种通知模型：让设备学会主动开口

控制面到此为止都是客户端发起的请求-应答，而事件的本质是**设备随时发生的状态变化**——移动侦测触发了、视频源丢了、有人动了存储卡。HTTP 的世界里设备没法凭空「推」给客户端，于是 ONVIF 给了三条路：

```text
① Basic：客户端 Subscribe 上报自己的 HTTP 端点 ── 设备 POST Notify 过来（反向连接，客户端当服务端）
② Pull-Point：客户端领订阅端点后循环 PullMessages（长轮询：无消息则设备按住应答，直到有消息或超时）
③ RTSP 内嵌：元数据 RTP 流以 XML 捎带 NotificationMessage（媒体面顺路，与取流同生共死）
```

**模型① Basic Notification**。Subscribe 的报文（完整信封；认证头按 [[ch04-ws-security-auth|第四章]]的惯例补在 Header）：

```xml
<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"
            xmlns:wsa="http://schemas.xmlsoap.org/ws/2004/08/addressing"
            xmlns:wsnt="http://docs.oasis-open.org/wsn/2004/06/wsn-WS-BaseNotification-1.2-draft-01.xsd"
            xmlns:tns1="http://www.onvif.org/ver10/topics">
  <s:Body>
    <wsnt:Subscribe>
      <wsnt:ConsumerReference>
        <wsa:Address>http://192.168.1.100:8080/onvif/notify</wsa:Address>
      </wsnt:ConsumerReference>
      <wsnt:InitialTerminationTime>PT1M</wsnt:InitialTerminationTime>
      <wsnt:Filter>
        <wsnt:TopicExpression Dialect="http://docs.oasis-open.org/wsn/t-1/TopicExpression/Concrete">tns1:VideoSource/MotionAlarm</wsnt:TopicExpression>
      </wsnt:Filter>
    </wsnt:Subscribe>
  </s:Body>
</s:Envelope>
```

订阅成功后，设备把匹配的 Notify 报文 POST 到 ConsumerReference 指定的地址（消息本体见 7.5）。代价写在脸上：**客户端必须有设备可达的 HTTP 端点**——NAT 后的办公网客户端直接出局；而且这条回推通道没有可用的安全绑定，WS-Security 套不上去。它适合的正是 NVR/平台这类常驻、网络位置固定的服务端角色。

**模型② Pull-Point**。客户端先建订阅点：

```xml
<!-- 前缀：tev=http://www.onvif.org/ver10/events/wsdl wsnt=WS-BaseNotification -->
<tev:CreatePullPointSubscription>
  <tev:Filter>
    <wsnt:TopicExpression Dialect="http://docs.oasis-open.org/wsn/t-1/TopicExpression/Concrete">tns1:VideoSource/MotionAlarm</wsnt:TopicExpression>
  </tev:Filter>
  <wsnt:InitialTerminationTime>PT1M</wsnt:InitialTerminationTime>
</tev:CreatePullPointSubscription>
<!-- 应答：SubscriptionReference（订阅端点地址）+ CurrentTime/TerminationTime -->
```

然后对着订阅端点循环长轮询：

```xml
<tev:PullMessages>
  <tev:Timeout>PT10S</tev:Timeout>
  <tev:MessageLimit>10</tev:MessageLimit>
</tev:PullMessages>
```

设备为每个订阅点维护一个消息缓冲：PullMessages 到来时若缓冲里已有消息立刻返回，没有则按住请求等待（最长 Timeout），期间到达的事件直接捎进应答——所以应答要么捎一批 NotificationMessage、要么空手超时返回。订阅有寿命（TerminationTime），到期前 Renew 续命、不用了 Unsubscribe 退订。**这是三种模型里事实上的默认选择**：客户端保持纯客户端身份（NAT、防火墙全友好，[[p2p-deep-dive|P2P 系列]]要死磕的反向可达问题在这里干脆不存在）、每个请求都能带第四章的摘要认证头、复用控制面同一个 HTTP 端口。代价是事件延迟打了个轮询往返的折扣（亚秒到秒量级，取决于超时设置与网络）。

**模型③ RTSP 内嵌**。给 Profile 挂上 MetadataConfiguration（第五章提过的第四类配置），取流时单独领一路元数据流：RTP 载荷是 XML 格式的元数据文档流，事件以 NotificationMessage 形态作为其中 Events 分支随流而下（PTZ 实时状态也在同一路里）。它与取流通道同生共死：**正在拉流，事件就在；停流，事件也就没了**。好处是延迟与帧对齐（联动场景里最快）、不占额外连接；限制是解析要下探到 RTP 载荷层，且事件覆盖面取决于设备往元数据流里塞了什么。

| 模型       | 消息方向           | 客户端角色  | NAT 友好度 | 典型用户       |
| ---------- | ------------------ | ----------- | ---------- | -------------- |
| Basic      | 设备 → 客户端 POST | HTTP 服务端 | 差         | 常驻 NVR/平台  |
| Pull-Point | 客户端 ⇄ 设备应答  | 纯客户端    | 好         | 绝大多数客户端 |
| RTSP 内嵌  | 随 RTP 元数据流    | 取流者      | 同取流     | 低延迟联动     |

不需要真设备也能观察这套机制的字节形态（有设备更直接）——看点：PullMessages 的 POST 间隔与 Timeout 的关系、事件到达时应答是否立刻回、Basic 模式下客户端端口上出现的入站 POST（Notify 信封与 Pull-Point 应答里的消息结构一模一样，同一套 NotificationMessage、两种投递路径）：

```bash
# 盯住客户端与设备之间的 SOAP 流量：长轮询表现为周期性的 POST→挂起→应答
tcpdump -i eth0 -s0 -A 'host 192.168.1.64 and tcp port 80'
```

## 7.5 WS-BaseNotification 与 tns1 话题树：过滤的两把尺子（又见面了）

ONVIF 事件没有另起炉灶：它站在 OASIS 两个 Web 服务标准（WS-BaseNotification 与 WS-Topics）的肩膀上做裁剪。三种模型投递的是同一种消息：

```xml
<wsnt:NotificationMessage>
  <wsnt:Topic Dialect="http://docs.oasis-open.org/wsn/t-1/TopicExpression/Concrete">tns1:VideoSource/MotionAlarm</wsnt:Topic>
  <wsnt:Message>
    <tt:Message UtcTime="2026-10-10T12:00:01Z" LocalTime="2026-10-10T20:00:01+08:00">
      <tt:Source><tt:SimpleItem Name="Source" Value="VideoSource_1"/></tt:Source>
      <tt:Data><tt:SimpleItem Name="State" Value="true"/></tt:Data>
    </tt:Message>
  </wsnt:Message>
</wsnt:NotificationMessage>
```

读法：Topic 是分类（挂在树的哪个枝上）、Source 是定位（哪个视频源）、Data 是载荷（状态键值对）、两个时间戳是产生时刻。结构化到 Source/Data 这一级，为的是让客户端不解析自然语言就能路由逻辑——7.6 的联动全靠它。

话题按树组织，根命名空间是 **tns1**（`http://www.onvif.org/ver10/topics`），常见分支：

| 话题                          | 语义                           |
| ----------------------------- | ------------------------------ |
| tns1:VideoSource/MotionAlarm  | 移动侦测开关（State）          |
| tns1:VideoSource/SignalLoss   | 视频源信号丢失                 |
| tns1:Device/HardwareFailure/… | 硬件故障族（镜头/风扇/存储…）  |
| tns1:VideoAnalytics/…         | 分析引擎的对象与元数据         |
| tns1:RuleEngine/…             | 分析规则触发（越线/区域入侵…） |

（具体分支与字段名以设备的 `GetEventProperties` 返回为准——它一次给出整棵 TopicSet、支持的话题表达式方言与内容过滤方言；厂商私有话题挂在自家命名空间前缀下，互通坑见 [[ch09-interop-ecosystem|第九章]]。）

订阅时的两把过滤尺子，与 ch02 的 Types/Scopes 惊人地同构：**TopicExpression 是分类尺**——按话题路径过滤，且订阅父话题自动收整个子树（订阅 `tns1:VideoSource` 能同时收到 MotionAlarm 与 SignalLoss）；**MessageContent 是内容尺**——按消息体键值过滤，用 ONVIF 自定义的简化 XPath 方言 ItemFilter，如 `boolean(//tt:SimpleItem[@Name="State" and @Value="true"])`（只要 State 为 true 的沿）。方言 URI 的支持清单同样以 GetEventProperties 为准——OASIS 与 ONVIF 各有一套 Concrete/Full 表达式 URI，混用是常见的踩坑点。

## 7.6 联动时序：移动侦测触发 GotoPreset

场景：一台球机平时对着仓库走廊，画面里出现移动目标时立刻转向门口的预置位。客户端逻辑只需要 7.2/7.3 的 PTZ 操作加 7.4 的 Pull-Point 订阅：

```text
客户端（NVR/脚本）                                摄像机
  │ ① GetProfiles，选带 PTZConfiguration 的 Profile ─►
  │ ② SetPreset(PresetName="door") ─────────────────►
  │ ◄───────────────────── PresetToken=3（记下）
  │ ③ CreatePullPointSubscription，过滤 MotionAlarm ►
  │ ◄────────────── SubscriptionReference（订阅端点）
  │ ④ PullMessages(Timeout=PT10S)，长轮询循环 ──────►
  │           ……画面里出现移动目标……
  │ ◄──── NotificationMessage(State=true)
  │ ⑤ 解析 Topic/Source，GotoPreset(PresetToken=3) ─►
  │ ⑥ 回到 ④；稍后 State=false 也会到达（警情解除）
```

逐步读：①按 7.1 的 token 链选好 Profile；②预置位先存后用，记下设备给的 token；③④拉起长轮询；⑤事件到达——客户端核对 Topic 是订阅的 MotionAlarm、Source 是想看的那路视频源（多目/多源设备必须查），再触发 GotoPreset；设备端新的移动命令会打断当前动作，不必先 Stop。工程细节四条：

- **抖动去抖**：MotionAlarm 的 State 常在 true/false 间快速翻转，联动逻辑应对边沿做去抖（如持续 true 超过阈值才动作），否则云台会跟着抽搐；
- **超时选值**：PullMessages 的 Timeout 太短则空转流量大、太长则订阅寿命管理复杂——常见节奏是轮询超时取秒级、订阅寿命取分钟级并提前 Renew；
- **风暴限流**：MessageLimit 封顶单次返回条数，RuleEngine 类话题批量触发时保护的是客户端自己；
- **分工边界**：这种联动逻辑全部跑在 NVR/平台侧；若要设备自己闭环（事件直接驱动输出/录像），那是设备端规则引擎与 Profile G 的话题（下一章）。

## 7.7 小结

- PTZ 三对象：Node 是只读的能力说明书（空间/预置位数/Home），Configuration 是可写的作业参数（限位/默认速度），Status 是运行时快照；ReferenceToken 从 Profile 一路穿到 Node。
- 四个移动操作共用归一化空间（[-1,1]）：ContinuousMove 踩油门、Absolute/Relative 给坐标、Stop 分轴刹车；支持哪些操作看 Node 的空间列表。
- 预置位：名字客户端起、token 设备给；token 不保证跨重启稳定，名字才是锚点。
- 三种事件模型投递同一种 NotificationMessage：Basic 要客户端当服务端（NAT 不友好、无安全绑定）、Pull-Point 长轮询最常用、RTSP 内嵌随元数据流延迟最低。
- 话题树（tns1:）+ 内容过滤（ItemFilter）构成事件路由的两把尺子，与 ch02 的 Types/Scopes 同构；移动侦测触发 GotoPreset 是两把能力的最小闭环。

PTZ 与事件到手，客户端已经能把设备当「可编程的执行器 + 传感器」用。下一章转向 NVR 侧：Profile G 圈定的录像、存储、回放与搜索——设备怎么描述自己录了什么、客户端怎么按时间轴和条件把录像找回来，以及回放走的那条与取流神似却不同的 RTSP 通道。[[ch08-recording-profile-g|第八章：录像与回放]]。
