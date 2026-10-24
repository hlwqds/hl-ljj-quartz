---
title: "ONVIF 深度解析（六）：取流全链——GetStreamUri 到 RTP 的每一步"
date: 2026-10-10 12:00:00
description: "媒体面全链：GetStreamUri 的 StreamSetup 在 RTP/UDP 单播与 RTP over RTSP over TCP 之间怎么取舍、返回的 rtsp URL 内嵌用户口令的经典问题、DESCRIBE/SETUP/PLAY 三步走（会话 id 与 Transport 头逐项解读）、SDP 里的 payload type 96 与 sprop-parameter-sets 如何喂饱解码器、UDP 端口协商对比 TCP interleaved 的 $ 帧格式、RTCP 与会话保活、GetSnapshotUri 抓图捷径，以及 ffmpeg/VLC 与 tcpdump/Wireshark 的观察方法。"
tags: [onvif, rtsp, rtp, sdp, streaming, series]
---

> [!info] ONVIF 深度解析系列 0. [[onvif-deep-dive|系列索引]] 1. [[ch01-onvif-overview|第一章]] … 5. [[ch05-media-profiles|第五章]] 6. **第六章：取流全链**

# ONVIF 深度解析（六）：取流全链——GetStreamUri 到 RTP 的每一步

前五章都停在控制面：发现设备（ch02）、问清服务（ch03）、通过鉴权（ch04）、配好 Profile（ch05）。这一章跨过控制/媒体的分界线，走完最后几百米：**流地址从哪来**（GetStreamUri 与 StreamSetup）、**连接怎么建**（DESCRIBE/SETUP/PLAY 三步走）、**数据怎么认**（SDP、payload type 与 SPS/PPS 的解码器初始化）、**会话怎么活**（保活与超时）——外加 GetSnapshotUri 抓图捷径与抓包观察。读完它，取流链上任何一环卡住，你都能定位是链上的哪一格。

---

## 6.1 GetStreamUri 与 StreamSetup：先选传输，再要地址

第五章结尾配好的 Media Profile 是一张配置快照；取流的第一步是拿这张快照去 Media 服务换一个可用的流地址。GetStreamUri 的特别之处在于：**你要先声明打算怎么传，设备才告诉你地址**——传输方式是请求的一部分，不是拿到地址后再选：

```xml
<!-- SOAP 信封与安全头同前几章，这里只看 Body -->
<s:Body>
  <trt:GetStreamUri>
    <trt:StreamSetup>
      <tt:Stream>RTP-Unicast</tt:Stream>   <!-- 单播；组播填 RTP-Multicast（6.2） -->
      <tt:Transport>
        <tt:Protocol>RTSP</tt:Protocol>    <!-- UDP | RTSP | HTTP -->
      </tt:Transport>
    </trt:StreamSetup>
    <trt:ProfileToken>Profile_1</trt:ProfileToken>
  </trt:GetStreamUri>
</s:Body>
```

两个维度组合出常见形态：`tt:Stream` 选单播/组播，`tt:Transport/Protocol` 选承载。注意**命名陷阱**：`Protocol=RTSP` 的实际含义是「RTP 打包进 RTSP 的 TCP 连接」（interleaved，6.5），不是字面的「用 RTSP 协议」。三种承载一张表说清：

| 承载                | 丢包行为            | 防火墙/NAT          | 时延               | 适用场景         |
| ------------------- | ------------------- | ------------------- | ------------------ | ---------------- |
| UDP（RTP over UDP） | 丢了就丢，花屏/跳帧 | 双向高端口都要放行  | 最低               | 同网段、受控网络 |
| RTSP（TCP 打包）    | 重传，队头阻塞      | 一条出站 554 全搞定 | 空闲时低，丢包时抖 | 穿防火墙、公网   |
| HTTP（再套一层）    | 同上，封装开销更大  | 只放 80 的环境兜底  | 最高               | 极端受限网络     |

取舍的物理根源：视频是实时流，**迟到的帧等于丢帧**——UDP 的丢包表现为花屏，TCP 的丢包表现为卡顿后追赶（把队列里的帧快速放完）。在 TCP 上跑实时流必然面对队头阻塞，这正是 [[quic-deep-dive|QUIC 深度探索系列]]反复讨论的那个问题——只是 RTSP 时代没有第二条可靠传输可选，工程师只能在这张表里挑边站。

## 6.2 返回的 rtsp URL：内嵌口令与单播/组播两形态

应答只有一个字段，但信息量都在 URI 里：

```xml
<trt:GetStreamUriResponse>
  <trt:MediaUri>
    <tt:Uri>rtsp://192.168.1.64:554/media/video1</tt:Uri>
  </trt:MediaUri>
</trt:GetStreamUriResponse>
```

**内嵌口令的经典问题**：设备普遍对 RTSP 端点也套 HTTP Digest——与 [[ch04-ws-security-auth|第四章]]同一套挑战-应答，但要搬进 RTSP 头字段里重算一遍。于是大量客户端的省事做法是把凭据直接塞进 URL：`rtsp://user:pass@192.168.1.64:554/...`。三个坑按出场频率排：

1. **泄露面**：带凭据的 URL 会溜进日志、shell history、工单与聊天记录——口令泄露的最常见形态之一；
2. **编码**：口令含 `@`、`:`、`/`、`#` 等字符时必须 percent-encode，没编码的 URL 解析必然错位；
3. **语义错觉**：内嵌凭据只是「用户名口令的载体」，表达不了 Digest 的 realm/nonce——客户端照样要实现完整的 401 挑战-应答，URL 一点鉴权也没省掉。

规范角度，GetStreamUri 返回的 URI 并不承诺包含凭据；但「内嵌口令」作为事实惯例已跑通多年，这段规范与现实的落差是取流互操作的常客（ch09 再算总账）。

**单播/组播**由请求里的 `tt:Stream` 决定，两形态一句话分清：

- **单播**（默认）：一个观看者一条流，带宽随人数线性增长，网络零特殊要求；
- **组播**：设备只发一份，SETUP 协商的 destination 是组播组地址，N 个观看者共享——代价是网络要「会」组播（交换机 IGMP Snooping、路由器组播路由），跨路由器默认不通；配错的典型症状是「第一个客户端能看，之后全网变卡」。

## 6.3 RTSP 三步走：DESCRIBE、SETUP、PLAY

拿到 URL 后离开 HTTP，进入 RTSP（RFC 2326，端口 554）。一次取流的完整节奏：

```text
客户端                                        设备（RTSP 服务端 554/tcp）
  │ ── OPTIONS ─────────────────────────────► │  预检：应答 Public 列出支持的方法（兼作保活，6.5）
  │ ── DESCRIBE rtsp://…/video1 ────────────► │  Accept: application/sdp
  │ ◄── 200 OK + SDP（媒体说明书，6.4）────── │  （首轮常先吃 401 Digest 挑战）
  │ ── SETUP …/trackID=1 ───────────────────► │  Transport：端口对 或 interleaved 通道
  │ ◄── 200 OK + Session: id;timeout=60 ───── │  会话建立
  │ ── PLAY（带 Session）───────────────────► │
  │ ◄── 200 OK + RTP-Info ─────────────────── │  紧接着 RTP 数据开始到达
```

三步各司其职：

- **DESCRIBE**：拿 SDP。首轮未带凭据时会收到 `401 Unauthorized + WWW-Authenticate: Digest`——第四章的手工推导在 RTSP 头字段上原样再来一遍；
- **SETUP**：定传输、建会话。注意 URL 用的是 SDP 里 `a=control` 给出的 **track 级地址**（`…/trackID=1`），不是 DESCRIBE 的总地址——视频、音频各有一条 track，各 SETUP 一次，共用一个会话；
- **PLAY**：开工。应答里的 `RTP-Info: url=…;seq=37442;rtptime=87654321` 给出起始序列号与 RTP 时间戳，客户端靠它在乱序到达的包里对齐「第一帧」。

SETUP 的灵魂是 Transport 头，逐项拆开：

| 字段              | 例值        | 含义                                                   |
| ----------------- | ----------- | ------------------------------------------------------ |
| 协议              | RTP/AVP     | RTP over UDP；TCP 打包时是 RTP/AVP/TCP                 |
| unicast/multicast | unicast     | 6.2 的两形态                                           |
| client_port       | 50000-50001 | 客户端侧端口对：RTP 偶数、RTCP=+1（RFC 3550 的硬规定） |
| server_port       | 6970-6971   | 应答携带：设备侧端口对                                 |
| interleaved       | 0-1         | TCP 模式：RTP 走通道 0、RTCP 走通道 1（6.5）           |
| ssrc              | 1A2B3C4D    | 应答携带：这条流的同步标识                             |
| mode              | PLAY        | RTSP 本义是「遥控录像机」：取流 PLAY、录制 RECORD      |

应答同时给出会话的身份证：`Session: 47112344;timeout=60`——后续 PLAY/PAUSE/TEARDOWN 都必须带这个 id；timeout 的含义见 6.5。

## 6.4 SDP 解剖：m 行、payload type 96 与 sprop-parameter-sets

DESCRIBE 应答的 body 就是 SDP（RFC 4566）——一份「媒体说明书」。示例（含义拆在表里）：

```text
v=0
o=- 123456 1 IN IP4 192.168.1.64
s=Media Presentation
c=IN IP4 0.0.0.0
a=control:rtsp://192.168.1.64:554/media/video1
m=video 0 RTP/AVP 96
a=rtpmap:96 H264/90000
a=control:rtsp://192.168.1.64:554/media/video1/trackID=1
a=fmtp:96 packetization-mode=1; profile-level-id=420029; sprop-parameter-sets=Z0IAKZWgUICA,aM48gA==
```

| 行                       | 读法                                                                                                        |
| ------------------------ | ----------------------------------------------------------------------------------------------------------- |
| `m=video 0 RTP/AVP 96`   | 视频流；端口 0 是占位（真实端口在 SETUP 协商）；96 是动态 payload type（96–127 段，含义由 rtpmap 现场约定） |
| `a=rtpmap:96 H264/90000` | 96 = H.264，采样时钟 90kHz（RTP 视频的标准时钟）                                                            |
| `a=control:…/trackID=1`  | 这条 track 的 SETUP 地址（6.3 的落点）                                                                      |
| `a=fmtp:96 …`            | H.264 专属参数，三个键各管一段（下拆）                                                                      |

fmtp 三键：

- **packetization-mode=1**：非交错打包——单 NAL 单包与 FU-A 分片（大帧切片）都允许，这是最普遍的模式；
- **profile-level-id=420029**：三字节十六进制速记——`42`=Baseline 档、`00`=约束集、`29`→level 4.1，解码能力门槛一眼可读；
- **sprop-parameter-sets=…,…**：**base64 编码的 SPS、PPS**（逗号分隔、SPS 在前）——解码器初始化的钥匙。

为什么 SPS/PPS 值得单独一节：H.264 裸流没有「文件头」概念，解码器开工前必须先拿到 SPS（分辨率、档次等全局参数）与 PPS。MP4 封装里它们躺在 moov box；RTP 直播流里则靠 sprop-parameter-sets **带外**递送——客户端把它喂给解码器，随后到达的 IDR 帧才解得动。若设备运行中热切换分辨率，新的 SPS/PPS 会**带内**随码流下发，客户端两条路都得认。这套封装规则的规定文本是 RFC 6184。

## 6.5 传输与保活：UDP 端口对、$ interleaved 帧与 RTCP

**UDP 模式**：SETUP 协商出两对端口（客户端一对、设备一对），RTP 偶、RTCP 奇。防火墙视角的要点：放行出站 554 只解决了信令，**数据是设备反向打到客户端高端口的**——这是「内网能放、穿墙转圈」类故障的最常见根因；NAT 后的客户端还要面对映射问题，实践里往往直接切 TCP 了事。

**TCP interleaved 模式**：RTP/RTCP 不再走独立端口，而是嵌进 554 那条 TCP 连接里，与 RTSP 文本报文混流，靠首字节区分：

```text
┌──────┬───────────┬───────────┬────────────────────────┐
│ '$'  │ channel   │ length    │  RTP/RTCP 包（N 字节） │
│ 0x24 │ 1 字节    │ 2 字节大端│  （length = N）        │
└──────┴───────────┴───────────┴────────────────────────┘
SETUP 的 interleaved=0-1：通道 0 走视频 RTP、通道 1 走视频 RTCP（音频依次 2/3）；RTSP 报文照旧以方法名或 RTSP/1.0 开头。
```

好处是防火墙只要一条出站 554；代价回到 6.1 表格的后半行——丢包时 TCP 重传与队头阻塞把时延顶起来。

**RTCP**：同一会话的伴生协议，周期性交换 SR/RR——丢包率、累计丢包、抖动、来回时延（由 LSR/DLSR 推出），相当于流媒体的质量仪表盘；NVR 界面上「这条流丢包若干」一类读数就来自这里。SR 还携带 NTP 时钟与 RTP 时间戳的对应关系，是多路流对齐、音视频同步的基准。

**保活与超时**：会话不是建好就一劳永逸——`timeout=60` 意味着空闲约 60 秒后设备可单方面释放。保活三选一：

| 保活方式                    | 形态                     | 备注               |
| --------------------------- | ------------------------ | ------------------ |
| RTSP OPTIONS                | 周期发、带上 Session 头  | 最常见             |
| SET_PARAMETER/GET_PARAMETER | 同上，空参数即可         | 常见备选           |
| RTCP                        | 客户端的 RR 本身就算活动 | UDP 模式下天然在跑 |

经典的互操作坑：客户端只按一种保活、设备只认另一种——症状极具辨识度：**画面固定放 30 或 60 秒整就断**，断点恰好等于 timeout 值。规范要求设备支持 OPTIONS 与 SET_PARAMETER 保活，RTCP 报文通常也计入活动，但现实参差（ch09 算总账）。

## 6.6 GetSnapshotUri：HTTP 抓图的捷径

Media 服务还藏着一个轻量出口：不要流，只要此刻的一张图。

```xml
<trt:GetSnapshotUri>
  <trt:ProfileToken>Profile_1</trt:ProfileToken>
</trt:GetSnapshotUri>
```

应答结构与 GetStreamUri 同款（MediaUri），URI 换成 HTTP——抓图就是一次普通的 HTTP GET（鉴权仍是 Digest）：

```bash
curl --digest -u user:pass -o snap.jpg "http://192.168.1.64/onvif-http/snapshot.jpg"
```

抓图与取流怎么选：

|        | GetSnapshotUri（HTTP 抓图）      | GetStreamUri（RTSP 取流）       |
| ------ | -------------------------------- | ------------------------------- |
| 产物   | 单张 JPEG（按当前 Profile 参数） | 连续码流（H.264/H.265，含音频） |
| 协议栈 | 一次 HTTP GET                    | RTSP 信令 + RTP 传输 + 保活     |
| 成本   | 极低，无会话                     | 常驻会话与带宽                  |
| 场景   | 缩略图、低频巡检、告警配图       | 实时监看、录像、分析            |

两个细节：快照的像素参数跟随 Profile 的视频源配置，但它**不是「第二路流」**——实现上重编码还是 ISP 直出 JPEG 是厂商自由，规范只约束到 URL 这层；抓图也没有「上一张/下一张」语义，每次 GET 都是即时快门。

## 6.7 一行验证与抓包：亲眼看一次取流

链路读懂了，接下来按 [[ch02-ws-discovery|第二章]]的观察法到媒体面亲眼看一次——一台 ONVIF 摄像机即可复现全部现象：

```bash
# VLC 拉流（等价于图形界面「媒体 → 打开网络串流」贴 URL）
vlc "rtsp://user:pass@192.168.1.64:554/media/video1"

# ffmpeg 拉 10 秒并丢弃：-f null 只验链路不落文件；-rtsp_transport tcp 强制 interleaved
ffmpeg -rtsp_transport tcp -i "rtsp://user:pass@192.168.1.64:554/media/video1" -t 10 -f null -
# ffprobe 看协商出的流参数（编码/分辨率/码率，来自 DESCRIBE 的 SDP）
ffprobe -hide_banner "rtsp://user:pass@192.168.1.64:554/media/video1"
```

口令含特殊字符记得 percent-encode（6.2 坑二）；穿防火墙失败时，显式 `-rtsp_transport tcp` 是第一反应（ffmpeg 默认先走 UDP）。

抓包侧：

```bash
# RTSP 信令全量（-A 直接可读，DESCRIBE 应答里的 SDP 一览无余）
tcpdump -i eth0 -A -s0 'tcp port 554'
# UDP 模式的 RTP/RTCP：抓 SETUP 协商出的 client_port 端口对
tcpdump -i eth0 -vv -s0 'udp port 50000 or udp port 50001'
```

Wireshark 过滤器换到媒体面这一组：

```text
rtsp                     # 全部 RTSP 信令
rtsp.method == "SETUP"   # 只看传输协商（Transport 头一目了然）
rtp                      # 全部 RTP 数据包
rtp.p_type == 96         # 只看 payload type 96 的视频包
rtcp                     # 质量报告（SR/RR 展开成树）
```

操作要点：**信令与数据要在同一次抓包里拿**——Wireshark 靠 SETUP 协商的端口/通道把后续包自动解码成 RTP，并按 SDP 把 96 认成 H.264；只有数据没有信令时，看到的只是一串裸 UDP。Telephony → RTP → Stream Analysis 还能把丢包/抖动画成曲线，与 RTCP 报告相互印证。

看点清单（延续 ch02 的清单式观察）：DESCRIBE 应答里 sprop-parameter-sets 是否随分辨率配置变化（6.4 的带外钥匙）；UDP 模式下「设备→客户端」反向端口的包是否被防火墙吞掉（6.5 根因的直接证据）；客户端静默一个 timeout 周期再回来，会话是否已被设备单方面释放（保活坑的复现）。

## 6.8 小结

- GetStreamUri 用 StreamSetup 把「取什么（ProfileToken）+ 怎么传（Stream × Protocol）」一次说清：UDP 换时延、TCP 换可达、HTTP 隧道兜底——`Protocol=RTSP` 指的是 TCP 打包，不是字面的「用 RTSP」。
- 返回的 rtsp URL 不承诺带凭据；内嵌 user:pass 是跑通多年的事实惯例——泄露面、percent-encode、Digest 语义三坑齐备。
- RTSP 三步走各司其职：DESCRIBE 交 SDP（先过一轮 401 Digest）、SETUP 定 Transport 与会话 id（track 级地址）、PLAY 用 RTP-Info 对齐起点。
- SDP 是解码器初始化的钥匙：m 行的动态 PT 96 由 rtpmap 认成 H.264/90000，fmtp 的 sprop-parameter-sets 带外交付 SPS/PPS；分辨率热切换时还有带内一路。
- UDP 端口对（偶 RTP 奇 RTCP）对防火墙不友好；TCP interleaved 的 $ 帧（通道 0/1）一条 554 全搞定；RTCP 是质量仪表盘；timeout 空闲即断，「整 30/60 秒断流」先查保活。
- GetSnapshotUri 是 HTTP 抓图捷径：无会话、成本极低，低频场景完胜取流。

画面到手只算「看到」。下一章让设备动起来、让消息流回来：PTZ 的连续/绝对/相对三种移动语义、预置位与巡航的配置模型，以及事件的三种通知模型——从「看」到「控」再到「听」。[[ch07-ptz-events|第七章：PTZ 与事件]]。
