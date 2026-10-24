---
title: "ONVIF 深度解析（二）：WS-Discovery——UDP 组播里的设备自荐"
date: 2026-10-10 12:00:00
description: "发现层解剖：SOAP over UDP 的组播世界（239.255.255.250:3702）、Probe/ProbeMatch/Hello/Bye 四种报文与各自的时机、types（dn:NetworkVideoTransmitter）与 scopes 的过滤语法、ProbeMatch 里 XAddrs 的落点；MX 随机延迟为什么是组播礼仪；与 mDNS/SSDP/LLDP 的家族对照；tcpdump/Wireshark 过滤器的观察实验。"
tags: [onvif, ws-discovery, udp, multicast, soap, series]
---

> [!info] ONVIF 深度解析系列 0. [[onvif-deep-dive|系列索引]] 1. [[ch01-onvif-overview|第一章]] 2. **第二章：WS-Discovery**

# ONVIF 深度解析（二）：WS-Discovery——UDP 组播里的设备自荐

接入一台 ONVIF 设备的第一步不是 HTTP 也不是 RTSP，而是一个 UDP 组播包。这一章拆 WS-Discovery：报文形态（2.1）、四种消息各自的时机（2.2）、types/scopes 的过滤语法（2.3）、以及它与 mDNS/SSDP 的家族对照（2.4）——你会发现它就是 [[p2p-deep-dive|P2P 系列]]ch02「UDP 广播发现」思想的标准化版本，连报文节奏都似曾相识。

---

## 2.1 SOAP over UDP：把 XML 塞进数据报

WS-Discovery 的工作场景：**同一个二层网络里，客户端还不知道任何设备的 IP，如何让它们自己站出来**。答案是约定一个组播地址——`239.255.255.250:3702`（IPv4；IPv6 有对应的链路本地组播地址），谁想找设备就往这儿喊，所有加入了该组的设备都能听见。

报文本体是 **SOAP 1.2 的 UDP 封装版**——没有 HTTP 头（UDP 里没有），XML 直接躺在数据报里，靠信封里的命名空间区分语义：

```xml
<!-- Probe：客户端的喊话（发往组播地址） -->
<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope"
            xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery"
            xmlns:dn="http://www.onvif.org/ver10/network/wsdl">
  <s:Body>
    <d:Probe>
      <d:Types>dn:NetworkVideoTransmitter</d:Types>   <!-- 我在找网络视频发送端 -->
      <d:Scopes>onvif://www.onvif.org/Profile/Streaming</d:Scopes> <!-- 可选：按 scope URI 过滤（2.3） -->
    </d:Probe>
  </s:Body>
</s:Envelope>
```

两个工程细节值得停一下：其一，**UDP 报文有 MTU 天花板**（规范限制 SOAP-over-UDP 报文不超约 64KB，但实践中 ProbeMatch 带 scopes 长列表时逼近 1500 是常态，还规定了报文过大时的 UDP 分片处理）；其二，**UDP 不可靠**，所以 WS-Discovery 定义了自己的重发礼仪（Probe 可重复发、响应带 MX 随机延迟，见 2.2）。

## 2.2 四种消息：各自的出场时机

| 报文           | 方向              | 时机                       | 载荷要点                          |
| -------------- | ----------------- | -------------------------- | --------------------------------- |
| **Probe**      | 客户端 → 组播     | 客户端要找设备（随时可发） | Types/Scopes 过滤条件             |
| **ProbeMatch** | 设备 → 客户端单播 | 收到匹配的 Probe 后        | 自己的地址、Types、Scopes、XAddrs |
| **Hello**      | 设备 → 组播       | 设备上线/加入组播组时      | 同 ProbeMatch——主动自荐           |
| **Bye**        | 设备 → 组播       | 设备正常下线前             | 告诉大家我走了，缓存可以作废      |

ProbeMatch 的灵魂字段是 **XAddrs**：设备的 HTTP 服务端点（`http://192.168.1.64/onvif/device_service`）——**发现层的全部产出就是把这个 URL 递到客户端手里**，之后控制面的一切对话都冲着它去。还有一个容易被忽略的字段 **MX**：ProbeMatch 的发送要随机延迟 0–MX 毫秒——如果一百台设备同时收到 Probe 同时应答，客户端会被瞬间打爆；随机错峰是组播世界的礼貌（与 [[p2p-deep-dive|P2P 系列]]ch05 泛洪的 TTL 节流同一哲学：**广播类协议都要内置退避**）。

Hello/Bye 的存在让客户端可以维护一张「活设备表」：启动时 Probe 一次建底账，之后靠 Hello/Bye 增量维护——但 UDP 会丢、设备会断电（Bye 发不出来），所以**缓存不可全信，用前要验**（对 XAddrs 发个 GetSystemDateAndTime 探活，ch03 的免鉴权四连问登场）。

## 2.3 Types 与 Scopes：过滤的两把尺子

- **Types** 是「设备类别」：`dn:NetworkVideoTransmitter`（能发视频的，摄像机/NVR 都算）、`tds:Device`（实现了设备服务的）。一个设备可同时报多个类型——找摄像机用前者，找一切 ONVIF 设备用后者；
- **Scopes 是「自定义标签」**：设备预置的分层标识，值是空格分隔的 URI 列表——ONVIF 侧按 `onvif://www.onvif.org/...` 约定组织（型号/硬件/名称/位置/Profile 等）。怎么算「匹配」由 Probe 的 `<d:Scopes MatchBy="规则URI">` 属性指定：缺省规则是 RFC 3986 的按段前缀匹配（Probe 里的 scope 是设备 scope 的前缀即命中），另有区分大小写的全字符串精确比较（strcmp0）、UUID、LDAP 等规则 URI 可选。集成商靠它做「只找 3 号楼的摄像头」这类筛选。

对照记忆：Types 像接口（implements 什么），Scopes 像注解（打了什么标签）——前者是标准词汇表，后者是部署现场的灵活位。

## 2.4 家族对照：mDNS、SSDP、LLDP

WS-Discovery 不是孤岛，「二层网络里的服务自发现」是一个大家族，四兄弟一张表认清：

| 协议         | 组播地址/端口                 | 报文          | 生态主场                  |
| ------------ | ----------------------------- | ------------- | ------------------------- |
| WS-Discovery | 239.255.255.250:3702          | SOAP/XML      | ONVIF、部分工业 WS-\*     |
| SSDP         | 239.255.255.250:1900          | HTTP 风格文本 | UPnP（家里的播放器/投屏） |
| mDNS         | 224.0.0.251:5353              | DNS 风格报文  | Bonjour/Avahi（.local）   |
| LLDP         | 01:80:c2:00:00:0e（以太组播） | 二进制 TLV    | 交换机组网（网管的视角）  |

四个协议的共性正是 [[p2p-deep-dive|P2P 系列]]ch02 总结的发现三步走：**广播/组播喊话 → 单播应答 → 记入同伴表**；差异全在报文编码与语义粒度。对照着学一次搞定一族——这也是「组播发现」作为通用零件的价值（[[wifi-coproc|WiFi 协处理器系列]]ch02 的 DRDY、这里的 MX 延迟，都是「广播礼仪」的不同侧面）。

## 2.5 观察实验：亲眼看一次发现

不需要 ONVIF 设备也能观察这套机制在跑（家用网络里常有 UPnP 设备在 SSDP 上刷屏）；有摄像机则更直接：

```bash
# 抓 3702 端口的组播（WS-Discovery 全部流量）
tcpdump -i eth0 -vvv -s0 'udp port 3702'
# Wireshark 过滤器（自带 ws-discovery 解析器，报文直接展开成树）
#   ipv6 || ip.addr == 239.255.255.250 && udp.port == 3702
```

看点清单：设备上电时的 Hello（谁在自荐）、客户端探测时的 Probe→若干 ProbeMatch 的应答延迟分布（MX 的错峰效果肉眼可见）、断电重启时有没有 Bye（多半没有——这就是缓存不可全信的证据）。

## 2.6 小结

- WS-Discovery = SOAP 1.2 over UDP 组播（239.255.255.250:3702）：发现层的全部产出是把 XAddrs（HTTP 服务端点）递到客户端手里。
- 四种消息按时机分工：Probe/ProbeMatch 是问答，Hello/Bye 是增量的上下线通知；MX 随机延迟是组播礼仪（退避防打爆）。
- Types 是标准类别词（NetworkVideoTransmitter），Scopes 是现场标签（空格分隔的 onvif:// URI 列表；匹配规则由 Probe 的 MatchBy 属性指定，缺省 RFC 3986 前缀匹配）；缓存不可全信，用前以轻量请求探活。
- 家族四兄弟（WS-Discovery/SSDP/mDNS/LLDP）共享「组播喊话-单播应答-记表」的骨架，编码与生态各异——与 P2P 系列的发现三步走同宗。

发现给了我们一个 XAddrs，下一章就冲着它发出第一个 HTTP 请求：SOAP 信封的解剖、WSDL 与命名空间的阅读法、以及免鉴权四连问（GetSystemDateAndTime/GetDeviceInformation/GetServices/GetCapabilities）——从「知道你在」到「知道你是谁、你有什么」。[[ch03-soap-services|第三章：SOAP 服务全景]]。
