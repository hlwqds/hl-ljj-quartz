---
title: "RDMA 第三章：InfiniBand 架构——链路层、网络层与传输层"
date: 2026-04-13 19:00:00
tags: [rdma, infiniband, ib, architecture, lid, gid, qpn, transport-layer]
description: "深入 InfiniBand 协议栈：物理层、链路层（LRH）、网络层（GRH）、传输层（IBA），LID/GID 地址，QPN 概念，以及 IB 的可靠传输机制。"
---

# RDMA 第三章：InfiniBand 架构——链路层、网络层与传输层

> [!abstract] 核心要点
> InfiniBand（IB）是 RDMA 的原生网络，拥有完整自定义的协议栈：物理层、链路层（Link Layer）、网络层（Global Route Header）、传输层。本章详解 IB 四层协议、数据包格式、LID/GID 地址机制、QPN 与 PSN，以及可靠传输的工作原理。

---

## 1. InfiniBand 协议栈总览

IB 从上到下分为四层：

```
┌──────────────────────────────────────────────────────────────┐
│                    InfiniBand Transport                      │
│                    (传输层 - IBA Transport)                  │
│              RC / UC / UD / RD 操作、可靠传输                 │
├──────────────────────────────────────────────────────────────┤
│                    InfiniBand Network                         │
│                    (网络层 - GRH)                            │
│                   全局路由、路径记录                          │
├──────────────────────────────────────────────────────────────┤
│                    InfiniBand Link                           │
│                    (链路层 - LRH)                            │
│                    本地路由、LID、VL、CRC                     │
├──────────────────────────────────────────────────────────────┤
│                    InfiniBand Physical                        │
│                    (物理层)                                  │
│               QSFP+/QSFP28/HSQC4, 1x/4x/8x/12x               │
└──────────────────────────────────────────────────────────────┘
```

与 OSI 模型对比：

| IB 层 | 对应 OSI |
|-------|----------|
| Transport | L4 (Transport) |
| Network | L3 (Network) |
| Link | L2 (Data Link) |
| Physical | L1 (Physical) |

---

## 2. 物理层（Physical Layer）

### 2.1 速率与编码

| 世代 | 速率/通道 | 编码 | 说明 |
|------|----------|------|------|
| SDR | 8 Gbps | 8b/10b | Single Data Rate |
| DDR | 16 Gbps | 8b/10b | Double Data Rate |
| QDR | 32 Gbps | 8b/10b | Quad Data Rate |
| FDR | 56 Gbps | 64b/66b | Fourteen Data Rate |
| EDR | 100 Gbps | 64b/66b | Enhanced Data Rate |
| HDR | 200 Gbps | 64b/66b | High Data Rate |
| NDR | 400 Gbps | 64b/66b | Next Data Rate |

### 2.2 物理接口

- **QSFP+**（QSFP28）：常见于 EDR/HDR 网卡和交换机
- **QSFP28**：单通道 28 Gbps，用于 NDR 400G
- **Cable 类型**：Copper Twin-Ax（DAC，超过 3m）、Active Optical Cable（AOC）

### 2.3 通道宽度

IB 支持 1x（1 通道）、4x（4 通道）、8x、12x 链路宽度。常用的是 4x（4 通道同时传输）。

---

## 3. 链路层（Link Layer）

### 3.1 LRH（Local Route Header）

每个 IB 数据包在链路层携带 LRH：

```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
┌─────────┬─────────┬─────────┬───────────────────────────────┐
│  VL (4) │  LVER   │  DL (2) │         DL (2)               │
│         │  (4)    │         │                               │
├─────────┴─────────┴─────────┴───────────────────────────────┤
│                     Destination LID (16)                    │
├─────────────────────────────────────────────────────────────┤
│                       Source LID (16)                        │
├─────────────────────────────────────────────────────────────┤
│                     Packet Type (8)                          │
└─────────────────────────────────────────────────────────────┘
```

| 字段 | 说明 |
|------|------|
| **VL** | Virtual Lane，虚拟通道，0-15 |
| **DL** | Destination/Source LID length |
| **LID** | Local ID，本地端口标识（12-bit） |
| **Packet Type** | 数据包类型（见下文） |

### 3.2 LID（Local ID）

每个物理端口有一个 LID（12-bit，本地唯一）。IB 网络中，交换机根据 LID 转发数据包——这是 L2 地址。

- **LID 范围**：1–0xFFFF（0 保留）
- **广播 LID**：0xFFFF 表示广播
- **多播**：通过多播组 GID 实现（非 LID）

### 3.3 链路层可靠传输

IB 链路层提供基于 Credit 的流量控制（不是 PFC）：

```
发送方维护每个 VL 的 Credit Counter
接收方定期发送 FBL（Flow Control Long）/ FBS（Flow Control Short）
发送方收到 Credit 后才继续发送
```

链路层还包含 CRC（ICRC 32-bit）校验，检测传输错误。

---

## 4. 网络层（Network Layer）

### 4.1 GRH（Global Route Header）

跨子网通信需要 GRH（用于路由器间的 IB 路由）：

```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
┌─────────┬─────────┬───────────────┬───────────────────────┐
│   IPVer │  TClass │        Hop Limit (8)                  │
├─────────┴─────────┴───────────────┴───────────────────────┤
│                      GID (128-bit)                          │
│                 (Source GID 96-127)                        │
├─────────────────────────────────────────────────────────────┤
│                      GID (128-bit)                          │
│               (Destination GID 0-31)                        │
└─────────────────────────────────────────────────────────────┘
```

### 4.2 GID（Global ID）

GID 是 IB 的 L3 地址（128-bit IPv6 格式），每个端口有一个或多个 GID：

```
GID = EUI-64 格式（基于供应商 MAC）
或
GID = IPv6 映射地址（fe80::/64 前缀 + 64-bit GUID）
```

本地通信主要用 GID，路由通信也用 GID。GID 的存在使得 IB 可以跨子网（subnet）路由。

### 4.3 Subnet Manager（子网管理器）

IB 是有fabric 拓扑（不像 Ethernet 可以自发广播）。每个 IB 子网必须有一个 **Subnet Manager (SMAD)**，负责：

- 发现拓扑
- 分配 LID
- 配置交换机路由表
- 管理多播组

SM 类似于 Ethernet 的 STP，但更强大——它是集中控制面的主动配置协议。

---

## 5. 传输层（Transport Layer）

### 5.1 IBA 传输层

IB 传输层（IBA — InfiniBand Architecture）是 RDMA 能力的核心，提供：

- **可靠连接（RC）**：每个数据包有序列号（PSN），丢包重传
- **可靠数据报（RD）**：基于数据报的可靠传输
- **不可靠连接（UC）**：无重传
- **不可靠数据报（UD）**：无连接、无确认

### 5.2 QPN（Queue Pair Number）

每个 QP 在整个 fabric 中有一个全局唯一的标识：**QPN**（24-bit）。在 IB 可靠传输中，QPN 用于标识连接。

### 5.3 PSN（Packet Sequence Number）

每个发送的数据包携带 PSN（24-bit），接收方根据 PSN 排序：

- **重传**：如果 PSN 间隙过大（丢失包），接收方发送 NAK，请求重传
- **重复检测**：如果 PSN 已收到，丢弃重复包
- **Ack/Nak**：接收方定期发送 ACK 或 NAK

### 5.4 可靠传输流程

```
Sender                                           Receiver
   │                                                │
   │  SN=100 ──────────────────────────────────→   │  检查 SN=100
   │  SN=101 ──────────────────────────────────→   │  检查 SN=101
   │  SN=102 ──── [packet lost] ──────────────→   │  检测间隙
   │                                                │  ←── NAK {expected=102} ──
   │  SN=102 (retransmit) ──────────────────────→  │  检查 SN=102 ✓
   │  SN=103 ──────────────────────────────────→   │
   │  SN=104 ──────────────────────────────────→   │
   │                                                │  ←── ACK {up to=104} ──
```

### 5.5 传输层数据包类型

| Opcode | 名称 | 说明 |
|--------|------|------|
| RC Sendreq | RC 发送请求 | 含 RDMA 操作的请求 |
| RC SendFirst/Middle/Last | 分段发送 | 大于 MTU 的消息 |
| RC ACK | 应答 | 确认收到 |
| RC NAK | 否定应答 | 请求重传 |
| RDMA Read Request | 读请求 | 读取远程内存 |
| RDMA Write Request | 写请求 | 写入远程内存 |
| Atomic Fetch & Add | 原子取加 | |
| Atomic Compare & Swap | 原子比较交换 | |

---

## 6. 完整数据包结构

```
┌─────────────────────────────────────────────────────────────┐
│ LRH (16 bytes)          │ 本地路由：VL, SL, LID              │
├─────────────────────────────────────────────────────────────┤
│ GRH (40 bytes, optional)│ 全球路由：GID, Hop Limit          │
├─────────────────────────────────────────────────────────────┤
│ ICRC (4 bytes)          │ 链路层 CRC（LRH 之后）             │
├─────────────────────────────────────────────────────────────┤
│ Transport Header (12B)  │ BTH: Base Transport Header        │
│                         │ (OpCode, PSN, QPN, Dest QP, ...)  │
├─────────────────────────────────────────────────────────────┤
│ RDMA Extended Header    │ (可选: RDMA 操作的额外字段)        │
├─────────────────────────────────────────────────────────────┤
│ Payload (0–4096 bytes)  │ 实际数据                          │
├─────────────────────────────────────────────────────────────┤
│ Invariant CRC (4 bytes) │ 端到端 CRC                        │
├─────────────────────────────────────────────────────────────┤
│ Variant CRC (2 bytes)   │ 链路层 CRC                        │
└─────────────────────────────────────────────────────────────┘
```

---

## 7. IB 寻址总结

| 地址类型 | 长度 | 范围 | 作用 |
|----------|------|------|------|
| **LID** | 16-bit | 1–0xFFFF | 本地子网内 L2 寻址 |
| **GID** | 128-bit | — | 全局 L3 寻址，IPv6 格式 |
| **QPN** | 24-bit | — | 标识 Queue Pair |
| **PSN** | 24-bit | — | 数据包序列号 |
| **GUID** | 64-bit | — | HCA/Port 全球唯一标识 |

---

## 8. IB 与 RoCE/iWARP 的关系

IB 传输层（RC/UD/RD 操作）被 **直接复用** 在 RoCE 和 iWARP 中：

```
RoCE:    IB Transport → IB Network → RoCE Encapsulation → Ethernet
iWARP:   IB Transport → DDP → RDMAP → TCP/UDP
```

也就是说，**IB 传输层是 RDMA 的核心语义层**，RoCE 和 iWARP 本质上是将 IB 传输层封装到 Ethernet 或 TCP 上。

---

## 9. 总结

IB 协议栈四层各有分工：

| 层级 | 核心功能 | 关键头部 |
|------|----------|----------|
| **Transport** | 可靠传输、RDMA 操作、原子操作 | BTH |
| **Network** | 全局路由、跨子网 | GRH (GID) |
| **Link** | 本地交换、LID 寻址、Credit 流控 | LRH |
| **Physical** | 高速串行、编码、信号 | — |

> [!next] 下一章
> 第四章聚焦 RoCE v1/v2——如何将 IB 传输层运行在 Ethernet 上，以及 PFC、ECN、DCB 等无损网络机制。
