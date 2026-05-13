---
title: "RDMA 第四章：RoCE v1/v2——以太网之上的 RDMA"
date: 2026-04-13 19:30:00
tags: [rdma, roce, ethernet, pfc, ecn, dcb, roce-v1, roce-v2]
description: "深入 RoCE 协议：RoCE v1（链路层）和 RoCE v2（UDP/IP 层）详解，PFC 流控、ECN 拥塞通知、DCB 数据中心桥接，以及与 InfiniBand 的差异对比。"
---

# RDMA 第四章：RoCE v1/v2——以太网之上的 RDMA

> [!abstract] 核心要点
> RoCE（RDMA over Converged Ethernet）将 IB 传输层运行在标准 Ethernet 上。RoCE v1 是链路层协议（VLAN-aware），RoCE v2 是网络层协议（UDP/IP，可路由）。两者都需要 DCB（PFC + ECN）构建无损网络。

---

## 1. RoCE 协议设计动机

InfiniBand 需要专用网络设备和 IB 交换机。RoCE 的目标是：**在已有的 Ethernet 基础设施上运行 RDMA**，无需重新布线和更换交换机。

但 Ethernet 本身是"尽力而为"的网络——可能丢包、不保证顺序。RoCE 通过以下机制解决：

- **PFC（Priority Flow Control）**：链路层反压，防止缓冲区溢出丢包
- **ECN（Explicit Congestion Notification）**：IP 层拥塞通知，触发拥塞源降速
- **无损网络**：PFC + ECN 共同构建 RoCE 的无损传输基础

---

## 2. RoCE v1（Ethernet 链路层）

### 2.1 协议栈

```
┌──────────────────────────────────────────────┐
│              IB Transport (RC/UD/...)        │
├──────────────────────────────────────────────┤
│         IB Network Layer (GRH)              │  ← 保留，但可选
├──────────────────────────────────────────────┤
│         RoCE v1 Frame (Ethertype 0x8915)     │
├──────────────────────────────────────────────┤
│         Ethernet MAC + VLAN                  │
└──────────────────────────────────────────────┘
```

RoCE v1 使用 Ethertype **0x8915**（专用 Ethertype），直接在 Ethernet 链路层承载 IB 传输层。

### 2.2 RoCE v1 帧格式

```
┌──────────┬──────────┐
│ Ethernet │ VLAN Tag │  ← 可选 VLAN
│ Header   │ (0x8100) │
├──────────┴──────────┴──────────────────────────────────────────┐
│  RoCE Header (8 bytes)                                        │
│  ┌──────────────────────────────────────────────────────────┐ │
│  │  IB Transport Header (BTH) + Payload                     │ │
│  └──────────────────────────────────────────────────────────┘ │
├───────────────────────────────────────────────────────────────┤
│  ICRC (4 bytes)          ← Ethernet 后面是 ICRC，不是以太网 CRC │
├───────────────────────────────────────────────────────────────┤
│  Ethernet CRC (4 bytes)                                       │
└───────────────────────────────────────────────────────────────┘
```

### 2.3 局限性

RoCE v1 是**纯 L2 协议**，没有 IP 层：
- 无法跨 VLAN 路由（除非同一 VLAN）
- 无法跨路由器
- 使用 BTH 中的 GID 进行寻址（而非 IP）

这在现代数据中心是一个严重限制——大多数多租户环境需要 L3 路由。

---

## 3. RoCE v2（UDP/IP 层）

### 3.1 协议栈

```
┌──────────────────────────────────────────────┐
│              IB Transport (RC/UD/...)        │
├──────────────────────────────────────────────┤
│         BTH (Base Transport Header)          │
├──────────────────────────────────────────────┤
│         UDP Header (Dst Port 4791)          │
├──────────────────────────────────────────────┤
│         IP Header                            │
├──────────────────────────────────────────────┤
│         Ethernet Header + VLAN               │
└──────────────────────────────────────────────┘
```

RoCE v2 在 UDP/IP 之上运行，**UDP 目标端口固定为 4791**。

### 3.2 RoCE v2 数据包格式

```
┌──────────────┬───────────────┐
│ Ethernet Hdr │ VLAN (opt)   │
├──────────────┴───────────────┴───────────────────────────────┐
│                    IP Header                                  │
├───────────────────────────────────────────────────────────────┤
│  UDP Header (Dst=4791, Src=ephemeral)                       │
├───────────────────────────────────────────────────────────────┤
│  RoCE v2 Header                                               │
│  ┌─────────────────────────────────────────────────────────┐ │
│  │  RGMP / Reserved                                         │ │
│  └─────────────────────────────────────────────────────────┘ │
│  IB BTH + Transport Headers + Payload                        │
├───────────────────────────────────────────────────────────────┤
│  ICRC (4 bytes)                                               │
├───────────────────────────────────────────────────────────────┤
│  Ethernet CRC (4 bytes)                                       │
└───────────────────────────────────────────────────────────────┘
```

### 3.3 拥塞管理：ECN

RoCE v2 使用 IP ECN（RFC 3168）进行拥塞通知：

```
ECN 字段（IP Header TOS 字节的低 2 位）：
  00 = Non-ECT（非 ECN -capable transport）
  01 = ECT(0)（ECN capable, codepoint 0）
  10 = ECT(1)（ECN capable, codepoint 1）
  11 = CE（Congestion Experienced）

RoCE v2 中：
  - 交换机检测拥塞 → 将 ECN 标记为 CE
  - 接收方收到 CE → 通过 RoCE v2 CNP（Congestion Notification Packet）通知发送方
  - 发送方降低发送速率
```

### 3.4 CNP（Congestion Notification Packet）

```
RoCE v2 CNP：
  - BTH Opcode = 0xC0（RoCE v2 CNP）
  - 仅 42 字节（无 payload）
  - 接收方检测到 ECN CE 标记时生成
  - 发回给发送方（相同 QP）
```

### 3.5 多路径 RoCE（RoCE v3 / MRMP）

2024 年后，RoCE v3 引入了**多路径 RoCE（Multipath RDMA over Conifer，MRMP）**，允许同一个 RDMA 连接跨越多条物理路径：

- 解决单路径 ECMP 负载不均问题
- 进一步提升网络利用率

---

## 4. PFC（Priority Flow Control）

### 4.1 为什么需要 PFC

Ethernet 在拥塞时会丢包（tail-drop），这对 RDMA 是致命的——RC 传输依赖可靠传输，丢包触发重传，延迟急剧上升。

PFC 在**链路层**实现反压（pause 机制），防止缓冲区溢出：

```
Host A ────── Switch ────── Host B
         (拥塞)
         
         Switch 检测到队列超过阈值
         → 发送 PFC PAUSE 帧给 Host A
         → Host A 暂停发送该 Priority 的流量
         → 拥塞消除后，Switch 发送 PFC RESUME
```

### 4.2 802.1Qbb PFC

PFC 允许在 8 个 Priority（对应 802.1Q VLAN PCP）中独立暂停每个 Priority。RoCE 通常使用 **Priority 3**（可配置）。

```
PFC 帧格式（Ethernet Pause Frame, EtherType 0x8808）：
┌─────────┬──────────┬───────────────┐
│ MAC     │ Opcode   │ Priority      │
│ DA=01-80-C2-00-00-01 │ 0x0101     │ Enable Map  │
├─────────┴──────────┴───────────────┤
│  PAUSE_TIME (2 bytes per priority) │
└─────────────────────────────────────┘
```

### 4.3 PFC 的问题

| 问题 | 说明 |
|------|------|
| **Head-of-Line Blocking** | 暂停整个 priority，可能阻塞同一 priority 的其他流 |
| **PFC 风暴** | 配置错误时，PFC 帧在交换机间形成环，引发网络wide pause |
| **不公平性** | 多个发送方同时 pause/restume，可能导致某些流饿死 |
| **Undead** | 发送方故障未发送 RESUME，导致永久暂停 |

PFC 的运维复杂度是 RoCE 部署的主要挑战。

---

## 5. DCB（Data Center Bridging）

DCB 是 IEEE 802.1 系列标准，RoCE 依赖以下 DCB 特性：

| 特性 | 标准 | 作用 |
|------|------|------|
| **PFC** | 802.1Qbb | 链路层流控，防丢包 |
| **ETS** | 802.1Qaz | 带宽分配，RoCE 通常保证 50%+ 带宽 |
| **DCBX** | 802.1Qaz | 交换机和网卡之间交换 DCB 配置（LLDP） |
| **ECN** | RFC 3168 / 802.1Qau | IP 层拥塞通知 |

### 5.2 DCBX 协商

DCBX 允许交换机和网卡自动协商 PFC/ETS 配置：

```
Switch ←────── LLDP + DCBX TLV ──────→ NIC

交换机向网卡通告：
  - PFC 启用哪些 priority
  - ETS 各 priority 的带宽分配
```

---

## 6. RoCE 完整协议栈

```
┌─────────────────────────────────────────────────────────────┐
│                   Application                               │
├─────────────────────────────────────────────────────────────┤
│                   libibverbs / librdmacm                   │
├─────────────────────────────────────────────────────────────┤
│              IB Transport (RC/UD/atomic)                   │
├─────────────────────────────────────────────────────────────┤
│              BTH (Base Transport Header)                   │
├─────────────────────────────────────────────────────────────┤
│              RoCE v2: UDP + IP                              │
│              RoCE v1: Ethernet (no IP)                     │
├─────────────────────────────────────────────────────────────┤
│              Ethernet + VLAN + PFC                         │
└─────────────────────────────────────────────────────────────┘
```

---

## 7. RoCE vs InfiniBand

| 维度 | InfiniBand | RoCE v2 |
|------|-------------|---------|
| **网络类型** | 专用 IB 网络 | 标准 Ethernet |
| **物理层** | IB 物理层（8b/10b） | 10/25/40/100/200/400 GbE |
| **路由** | 子网内 LID，跨子网 GID | IP 路由 |
| **拥塞控制** | IB Credit-based | ECN + CNP |
| **流控** | IB Credit (链路层) | PFC (802.1Qbb) |
| **延迟** | ~0.5 μs（HDR） | ~1–2 μs |
| **配置复杂度** | SM 自动管理 | 需配置 DCB/PFC/ECN |
| **规模** | 受 SM 管理规模限制 | 受 IP 路由规模限制 |
| **多租户** | 受 VLAN 限制 | 原生 IP 路由，支持多租户 |

---

## 8. RoCE 网络配置要点

### 8.1 交换机配置

```
1. 启用 DCB：
   - DCBX 模式：auto（与 NIC 协商）或 configure
   - ETS：RoCE priority 预留带宽（如 50%）

2. 启用 PFC：
   - PFC 模式：on（对 RoCE priority 开启）
   - 通常使用 priority 3 作为 RoCE traffic class

3. 启用 ECN：
   - 阈值配置（wred）
   - ECN-marking 启用
```

### 8.2 网卡配置

```
# 查看 RoCE 状态（Mellanox）
mlnx_qos -i eth0

# 启用 RoCE
cma_roce_tos -d mlx5_0 --set 3

# 查看 GID
show_gids
```

### 8.3 验证无损网络

```
# 丢包测试
rdma_xclient -s <server_ip> -c 1000

# 拥塞测试
perftest -z -F -g <gid> -b <bandwidth>
```

---

## 9. 总结

RoCE 将 IB 传输层带入 Ethernet 世界：

| 特性 | RoCE v1 | RoCE v2 |
|------|---------|---------|
| **层级** | L2（Ethernet） | L3（UDP/IP） |
| **路由能力** | 无 | IP 路由 |
| **拥塞通知** | PFC only | ECN + CNP |
| **多租户** | 受 VLAN 限制 | 原生支持 |
| **使用场景** | 同 VLAN 小规模 | 主流云/数据中心 |

RoCE 的挑战在于无损网络配置——PFC 和 ECN 的正确调优是生产部署的关键。

> [!next] 下一章
> 第五章介绍 iWARP——另一种运行在 Ethernet 上的 RDMA 协议，使用 TCP/UDP 作为传输层。
