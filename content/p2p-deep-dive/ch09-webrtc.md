---
title: "P2P 网络深度解析（九）：WebRTC——浏览器里的 P2P 复兴"
date: 2026-10-10 12:00:00
description: "把 P2P 塞进浏览器沙箱：信令为什么被刻意排除在标准之外、SDP offer/answer 里 a=candidate 与 a=fingerprint 各自锚定什么、ICE（ch04）如何被产品化成 host/srflx/relay 候选、媒体为什么强制 DTLS-SRTP、DataChannel 为什么是 SCTP over DTLS——附一个不依赖任何库的最小 DataChannel 双页示例，与 WebTorrent/Cloudflare 的产业现状。"
tags: [p2p, network, webrtc, ice, dtls, browser, series]
---

> [!info] P2P 网络深度解析系列 0. [[p2p-deep-dive|系列索引]] 1. [[ch01-p2p-overview|第一章]] 2. [[ch02-first-peer-direct-connect|第二章]] 3. [[ch03-nat-fundamentals|第三章]] 4. [[ch04-nat-traversal|第四章]] 5. [[ch05-unstructured-p2p-search|第五章]] 6. [[ch06-dht-chord|第六章]] 7. [[ch07-kademlia|第七章]] 8. [[ch08-bittorrent|第八章]] 9. **第九章：WebRTC——浏览器里的 P2P 复兴**

# P2P 网络深度解析（九）：WebRTC——浏览器里的 P2P 复兴

2010 年代，Google 把收购来的 RTC 技术开源并推进 W3C/IETF 标准化，P2P 以 **WebRTC** 的形态获得了人类历史上最大的部署面：几十亿台浏览器与 App。这一章看它如何把前八章的零件封装成产品：信令的刻意留白（9.1）、SDP offer/answer 模型（9.2）、ICE 的产品化（9.3）、强制加密的媒体与数据栈（9.4）、DataChannel 的分层（9.5），最后用零依赖的最小示例跑通一遍（9.6）。调试过"为什么连不上"的工程师会在 9.3 找到全部答案的索引。

---

## 9.1 信令留白：标准只管两头，中间随你

WebRTC 最反直觉的设计决定：**信令（signaling）不在标准里**。标准定义的是"两份描述如何协商出一条直连"（offer/answer 模型），至于描述怎么从 A 送到 B——WebSocket、HTTP 轮询、甚至复制粘贴（早期 demos 的做法）——完全不管。

这不是偷懒，而是清醒：信令服务器本来就是控制面（ch05 的结论——**控制面可以中心化，且它便宜**），各家有自己的账号体系与业务逻辑，标准化它只会增加迁移阻力。于是 WebRTC 的架构是刻意的三层分工：

```text
┌─────────────── 你的信令通道（WebSocket/HTTP/任何） ───────────────┐
│   传的是offer/answer(SDP文本) + ICE候选地址 —— 纯文本快递，不看内容 │
└──────────────────────────────┬───────────────────────────────────┘
                               ▼
        ┌─ ICE（RFC 8445，ch04 全套）── 打洞/中继/连通性检查 ─┐
        │                                                        │
        ▼                                                        ▼
   DTLS 1.2+ 强制加密层（媒体密钥也在这派生）                      │
        ▼                                                        ▼
   SRTP（音视频，RFC 3711）                    SCTP（DataChannel，RFC 8831）
```

---

## 9.2 SDP：一份自我介绍的文本

RTCPeerConnection 的核心 API 围绕 **SDP（Session Description Protocol）** 组织：`createOffer()` 生成本端能力清单，经信令送达对端，对端 `setRemoteDescription` 后回 `createAnswer`。SDP 是出了名的晦涩（几千行的 offer 并不罕见），但 P2P 视角下只需要认识三处：

```text
v=0
...
m=application 9 UDP/DTLS/SCTP webrtc-datachannel   ← DataChannel 的媒体行
a=fingerprint:sha-256 XX:XX:...                    ← 本端 DTLS 证书指纹（身份锚点）
...
a=candidate:1 1 udp 2122260223 192.168.1.20 5000 typ host ...        ← ICE host 候选
a=candidate:2 1 udp 1686052607 203.0.113.7 40001 typ srflx ...      ← STUN 反射候选
a=candidate:3 1 udp 41885439 74.x.x.x 39000 typ relay ...           ← TURN 中继候选
a=ice-ufrag:xxxx / a=ice-pwd:yyyy                  ← ICE 凭据（连通性检查用）
a=setup:actpass                                    ← DTLS 角色协商
```

- `a=candidate` 三连正是 ch04 的收集结果：host（同网段最高优先）、srflx（STUN 反射）、relay（TURN 兜底）。
- `a=fingerprint` 把**身份**绑进描述：DTLS 握手用的证书哈希写在这里，两端核对手上的指纹与握出来的一致，防止中间人顶替——**信令通道若被劫持，攻击者也无法伪造证书**（前提是信令本身是 HTTPS/WSS）。
- m 行里音视频与数据通道各自成流，音视频可协商编解码（opus/VP8/VP9/H264…），数据通道统一 `application` 行。

trickle ICE 是工程上的重要补丁：不等候选收集全（STUN/TURN 探测可能要几秒）就先交换描述，候选到一个传一个——首帧时间因此省下数秒。现代 API（`onicecandidate`）默认就是 trickle 语义。

---

## 9.3 ICE 产品化：你调试"连不上"时在看什么

ch04 的 ICE 在浏览器里全自动跑，但调试时 `chrome://webrtc-internals` 暴露的候选对表格值得逐列认领：

- **候选类型优先级**：host > prflx（对端新发现的）> srflx > relay——**能直连绝不过中继**的哲学落实为打分排序。
- **selected candidate pair**：当前选中对。看它的 local/remote 候选类型就知道链路质量：`host↔host`（同 LAN 最优）、`srflx↔srflx`（打洞成功）、`relay↔*`（**走了中继，延迟与成本起飞**——为什么慢的第一嫌疑人）。
- **nominated/consent**：选中后周期性 STUN 探测保活（RFC 7675：约每 5 秒一次 consent 检查，30 秒无响应判死）——ICE restart 触发重打洞。

浏览器还做了一件 ch04 没讲的事：**host 候选的 mDNS 匿名化**——本地 IP 不再裸奔进 SDP，而是包一层 `xxxx.local` mDNS 名，只有同网段能解析。这是隐私设计：网页拿不到你的内网拓扑，又不妨碍 LAN 直连。

---

## 9.4 强制加密：没有明文模式

WebRTC 从第一版起就把加密焊死：**所有媒体走 SRTP、所有数据走 DTLS**，没有协商降级的开关。密钥体系一次握手两用：

- DTLS 握手（复用 ICE 打通的路径）建立安全通道，**同时用导出的密钥给 SRTP 加密音视频**（媒体面不重复握手，省一个 RTT）；
- SDP 里的 `a=fingerprint` 完成证书与信令的双向锚定（9.2）。

对比历史包袱深重的 SIP/WebRTC 之前的实时协议（SRTP 密钥靠 SDES 明文塞 SDP 的年代），这是 2010 年代的新共识：**新协议出生即加密，且不给中间盒"优化"媒体流的机会**——DPI 无法重写加密的 SDP 候选，也顺手解决了 ch05 提到的 ALG 篡改问题。

---

## 9.5 DataChannel：SCTP 的复活

数据通道 API 长得像 WebSocket（`send`/`onmessage`/`close`），底层却是一套有趣的复活：**SCTP over DTLS over ICE/UDP**（RFC 8831）。

- 为什么不是 TCP：ICE 的路径是 UDP 语义（打洞打出来的），上面再跑 TCP 会遭遇 TCP-over-UDP 的队头阻塞叠加（[[quic-deep-dive|QUIC 系列]]第一章对同类问题的长篇论证）。
- 为什么不是 QUIC：标准化时（2011–2015）QUIC 尚未成气候，SCTP 是现成的多流传输（电信信令协议出身），带**部分可靠性**（PR-SCTP：可按优先级/时限丢弃重传）——这在 QUIC/Datagram 出现前是独门能力。
- 每个通道是 SCTP 的一条流（stream id + label），通道间无队头阻塞；DCEP（RFC 8832）负责带内协商新通道。
- 实践红线：**单条消息别超过 16 KiB**（跨浏览器安全的保守值；规范允许协商更大，但旧对端可能拒收或分片失败），大文件自己切块——像不像 ch02 的分块课？

---

## 9.6 动手：零依赖的最小 DataChannel

两个本地 HTML 页面（同一目录用 `python -m http.server` 起一个即可），信令用**复制粘贴**——最诚实的方式，让你亲眼看到"信令只是文本快递"：

```html
<!-- offerer.html：生成 offer，等 answer -->
<script type="module">
  const pc = new RTCPeerConnection()
  pc.onicecandidate = (e) => console.log(JSON.stringify(pc.localDescription)) // ①复制这行输出给对方
  const dc = pc.createDataChannel("chat")
  dc.onopen = () => dc.send("hello from A")
  dc.onmessage = (e) => console.log("B 说:", e.data)
  await pc.setLocalDescription(await pc.createOffer()) // trickle：候选稍后陆续出来
  window.done = async (answer) => {
    // ②拿到对方的 answer 粘进来后执行
    await pc.setRemoteDescription(JSON.parse(answer))
  }
</script>
```

```html
<!-- answerer.html：贴入 offer，生成 answer -->
<script type="module">
  const pc = new RTCPeerConnection()
  pc.ondatachannel = (e) => {
    e.channel.onmessage = (ev) => console.log("A 说:", ev.data)
    e.channel.send("hi from B")
  }
  window.answer = async (offer) => {
    // ①贴入对方的 offer 后执行
    await pc.setRemoteDescription(JSON.parse(offer))
    await pc.setLocalDescription(await pc.createAnswer()) // ②把输出复制回给对方
  }
</script>
```

流程：A 页开出来 → ①的输出整段复制 → B 页 `answer(<粘贴>)` → B 的 localDescription 复制回 A → A 页 `done(<粘贴>)` → 控制台两边互通 hello。打开 `chrome://webrtc-internals` 能看到完整的候选对检查过程——**同一台机器上 host↔host 直连**；把两页放到两台不同 NAT 后的设备上，你会看到 srflx 候选与真实打洞。

## 9.7 产业现状：谁在用 WebRTC

- **视频会议**：Google Meet/Zoom Web/Discord 的点对点模式（三人以上通常转 SFU 服务器转发——纯 P2P 的上行带宽是 O(对端数)，mesh 模式撑不过四五人，这是 P2P 视频的天花板）。
- **WebTorrent**：BitTorrent over WebRTC（ch08 的 swarm 跑在 DataChannel 上，浏览器直接做种）。
- **Cloudflare Calls / Millicast**：边缘 TURN/SFU 的商业化。
- **远控与投屏**：网页远程桌面、云游戏串流（配 WebCodecs 用，DataChannel 只管信令或输入）。

> [!tip] 与 QUIC 的位置关系
> WebRTC（媒体）与 QUIC（HTTP/3）是并行的两条现代化路线：前者为实时 P2P 设计、加密强制、部分可靠；后者为 Web 传输设计、多路复用、可靠优先。两者在"重建传输层以摆脱 TCP 队头阻塞"上殊途同归，深入对比见 [[quic-deep-dive|QUIC 深度探索系列]]。

## 9.8 小结

- 信令刻意留白是架构清醒而非缺陷：标准管 offer/answer 协商，控制面交给业务自己——**贵的数据面才值得去中心化**。
- SDP 三处要害：a=candidate 是 ICE 候选清单（host/srflx/relay），a=fingerprint 锚定 DTLS 证书身份，ice-ufrag/pwd 是连通性检查凭据；trickle ICE 候选到一个传一个，省数秒首帧时间。
- 调试"连不上/卡"看 `chrome://webrtc-internals` 的 selected pair：relay↔relay 意味着走了中继兜底（ch04 的 15% 长尾）；consent 探测约 5 秒一轮维持连接活性。
- 加密无开关：DTLS 强制、SRTP 密钥从 DTLS 派生、指纹双向锚定信令——新协议出生即加密的范式。
- DataChannel = WebSocket 的脸、SCTP over DTLS 的芯；通道间无队头阻塞、可部分可靠，单消息 16 KiB 红线要自己分块。
- P2P 视频的天花板是上行带宽 O(对端数)，多人场景回到 SFU——去中心化与可扩展性的权衡在每一层复现。

至此，连接、组织、应用三个层次都已打通。但整个旅程始终悬着一个我们绕不开的问题：**P2P 网络里的"一个节点"到底是不是一个人？** 女巫攻击、日蚀攻击、索引投毒——没有准入控制的系统如何被这些手段撕裂，又发展出哪些防御，是终章的主题。[[ch10-p2p-security|第十章：P2P 安全与未来——攻击、防御与设计原则]]。
