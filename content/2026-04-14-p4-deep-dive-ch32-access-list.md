---
title: "P4 深度探索 (三十二)：P4 ACL 编程——访问控制列表、防火墙、Exact/Ternary Match、五元组过滤"
date: 2026-04-14
tags: [p4, series, acl, firewall, ternary, exact-match, five-tuple, security, p4-16]
description: "P4 ACL 访问控制列表编程深度解析——Exact/Ternary Match、ACL 表设计、五元组过滤、状态防火墙、单播反向路径过滤 (uRPF)、ACL 优先级与 TCAM 压缩"
---

> [!info] P4 深度探索系列
> 0. [[2026-04-14-p4-deep-dive-series-index|全栈学习路径总览]]
> 1. [[2026-04-14-p4-deep-dive-ch1-p4-overview|第一章：P4 概述——诞生背景与协议无关包处理]]
> 2. [[2026-04-14-p4-deep-dive-ch2-p4-architecture|第二章：P4 架构模型——PSA/V1Model、Ingress/Egress]]
> 3. [[2026-04-14-p4-deep-dive-ch3-p4-vs-ebpf|第三章：P4 vs eBPF——适用场景与硬件/软件对比]]
> ...
> 30. [[2026-04-14-p4-deep-dive-ch30-p4-control-plane-advanced|第三十章：P4 控制面高级主题]]
> 31. [[2026-04-14-p4-deep-dive-ch31-basic-routing|第三十一章：P4 基础路由编程]]
> 32. **第三十二章：P4 ACL 编程——访问控制列表、防火墙、Exact/Ternary Match、五元组过滤**

---

## 1. 概述：ACL 的作用与分类

**ACL (Access Control List)** 是网络安全的核心组件，用于**过滤/允许**通过交换机的流量。

```
ACL 在 Pipeline 中的位置:
==========================

  Packet
    |
    v
  [Parser] --> Extract headers
    |
    v
  [Ingress ACL] --> 早期安全过滤 (在路由查找之前)
    |
    v
  [L3 Route Lookup] --> 路由转发
    |
    v
  [Egress ACL] --> 出口过滤 (路由之后)
    |
    v
  [Egress Processing]
    |
    v
  Packet Out
```

### 1.1 ACL 类型

| ACL 类型 | 匹配字段 | 典型用途 |
|---------|---------|---------|
| **MAC ACL** | src/dst MAC, EtherType | L2 过滤 |
| **VLAN ACL** | VLAN ID, MAC, EtherType | VLAN 内过滤 |
| **IPv4/IPv6 ACL** | IP 地址, Protocol, Ports | L3/L4 过滤 |
| **Mixed ACL** | 组合多种字段 | 全面过滤 |

---

## 2. Match 类型详解

### 2.1 Exact Match (精确匹配)

**Exact Match** 要求 key 与表项**完全一致**，常用于 MAC 地址、端口号等场景：

```c
// Exact Match 表：基于 MAC 地址过滤
table mac_filter {
    key = {
        hdr.ethernet.srcAddr: exact;  // 精确匹配
        hdr.ethernet.dstAddr: exact;
    }
    actions = {
        allow;
        deny;
    }
}
```

### 2.2 Ternary Match (三元匹配)

**Ternary Match** 支持**掩码**操作，可以匹配一段范围：

```c
// Ternary Match 表：基于 IP 地址段过滤
table ip_filter {
    key = {
        hdr.ipv4.srcAddr: ternary;   // 带掩码的匹配
        hdr.ipv4.dstAddr: ternary;
        hdr.ipv4.protocol: ternary;   // 协议掩码
    }
    actions = {
        allow;
        deny;
        send_to_cpu;  // 镜像到控制面
    }
}

// P4 Runtime 配置示例
// 匹配 10.0.0.0/8 整个网段
message TernaryMatch {
    bytes addr = 1;       // 10.0.0.0
    bytes mask = 2;       // 255.0.0.0 (/8)
}
```

### 2.3 Ternary Match 的硬件实现

```
Ternary Match (TCAM):
=====================

  +--------+--------+--------+
  | Key    | Mask   | Action |
  +--------+--------+--------+
  | 10.0.0.0 | FF000000 | Allow  |  <-- /8 网络
  +--------+--------+--------+
  | 10.1.2.0 | FFFFFFC0 | Allow  |  <-- /26 子网
  +--------+--------+--------+
  | 10.1.2.0 | FFFFFF00 | Deny   |  <-- /24 子网 (更具体)
  +--------+--------+--------+
  | 0.0.0.0  | 0.0.0.0  | Deny   |  <-- 默认拒绝
  +--------+--------+--------+

  TCAM 按优先级排序（最长掩码 = 最高优先级）
```

---

## 3. 五元组 ACL 设计

### 3.1 五元组定义

**五元组 (5-tuple)** 唯一标识一个网络 flow：

| 字段 | 说明 | 示例 |
|------|------|------|
| **Src IP** | 源 IP 地址 | 192.168.1.100 |
| **Dst IP** | 目标 IP 地址 | 10.0.0.1 |
| **Protocol** | L4 协议 (TCP/UDP/ICMP) | TCP (6) |
| **Src Port** | 源端口 | 80 |
| **Dst Port** | 目标端口 | 443 |

### 3.2 五元组 ACL 表

```c
// 五元组 ACL 表
table acl_5tuple {
    key = {
        // 使用 Ternary 支持范围匹配
        hdr.ipv4.srcAddr:       ternary;
        hdr.ipv4.dstAddr:       ternary;
        hdr.ipv4.protocol:      ternary;   // TCP=6, UDP=17, ICMP=1
        // L4 Ports (需要先解析 TCP/UDP header)
        hdr.tcp.srcPort:        ternary;
        hdr.tcp.dstPort:        ternary;
    }
    actions = {
        allow;
        deny;
        log_and_allow;          // 记录日志后允许
        send_to_cpu;            // 镜像到控制面
    }
    default_action = deny();    // 默认拒绝
}
```

### 3.3 TCP/UDP Port 范围匹配

```c
// Port 范围匹配需要特殊的掩码技巧
// 例如：匹配 1024-65535 (所有高端口)

// 方法 1: 使用多个精确匹配
table high_port_filter {
    key = {
        hdr.tcp.dstPort: ternary;  // mask = 0xFC00, value = 0x0400
                                    // 匹配 1024-2047
    }
    // ...
}

// 方法 2: 组合多个 /10 子网
// 1024-65535 = 10.0.0.0/10 + 172.16.0.0/12 + 192.168.0.0/16 (端口无关)

// 方法 3: 预定义常用端口组
enum bit<16> well_known_port {
    HTTP  = 80,
    HTTPS = 443,
    SSH   = 22,
    DNS   = 53,
    SMTP  = 25,
    // ...
}
```

---

## 4. ACL 表优先级与顺序

### 4.1 ACL 规则顺序

ACL 规则按**从上到下**的顺序匹配，**第一条匹配的规则生效**：

```
ACL 规则处理:
==============

Rule 1: permit tcp 10.0.0.0/8 any      <-- 先匹配
Rule 2: deny   tcp 10.1.0.0/16 any     <-- 永不匹配 (被 Rule 1 覆盖)
Rule 3: deny   tcp any any

处理 10.1.2.3 -> 任意端口 的 TCP 流量:
  1. 检查 Rule 1: 10.1.2.3 ∈ 10.0.0.0/8? ✅ 匹配 -> Allow
  2. Rule 2, Rule 3 不会执行
```

### 4.2 ACL 表级联设计

```c
// 级联 ACL 表：先粗后细
control acl_chain(packet_in packet,
                  inout headers hdr,
                  inout metadata_t meta) {

    // 第一级：网络层 ACL (粗粒度)
    table acl_network {
        key = {
            hdr.ipv4.srcAddr: ternary;
            hdr.ipv4.dstAddr: ternary;
            hdr.ipv4.protocol: ternary;
        }
        actions = { allow; deny; continue; }  // continue 表示继续匹配
        default_action = continue;
    }

    // 第二级：传输层 ACL (细粒度)
    table acl_transport {
        key = {
            hdr.tcp.srcPort: ternary;
            hdr.tcp.dstPort: ternary;
            hdr.tcp.flags: ternary;         // TCP flags (SYN, ACK, FIN)
        }
        actions = { allow; deny; }
    }

    apply {
        // 先检查网络层 ACL
        if (acl_network.apply().hit) {
            // 如果命中且动作是 deny，直接拒绝
            return;
        }

        // 网络层允许，继续检查传输层 ACL
        if (hdr.tcp.isValid()) {
            acl_transport.apply();
        }
    }
}
```

---

## 5. 状态防火墙 (Stateful Firewall)

### 5.1 无状态 vs 有状态

| 类型 | 说明 | 示例 |
|------|------|------|
| **无状态 ACL** | 逐包检查，不考虑会话状态 | 传统 ACL |
| **有状态防火墙** | 跟踪会话状态，只允许响应流量 | Stateful Firewall |

### 5.2 有状态防火墙实现

```c
// 有状态防火墙需要跟踪会话状态
// 使用 Register 或外部状态表

// 会话表 (Connection Tracking Table)
table session_table {
    key = {
        hdr.ipv4.srcAddr:       exact;   // 源 IP
        hdr.ipv4.dstAddr:       exact;   // 目标 IP
        hdr.tcp.srcPort:        exact;   // 源端口
        hdr.tcp.dstPort:        exact;   // 目标端口
        hdr.ipv4.protocol:      exact;   // 协议
    }
    actions = {
        established_session;    // 已建立会话
        new_session;            // 新建会话
        invalid;                // 无效会话
    }
}

// TCP 状态机
enum tcp_state {
    INVALID,
    NEW_SYN,           // 收到 SYN
    SYN_ACK_SENT,      // 发送 SYN-ACK
    ESTABLISHED,       // 会话建立
    FIN_WAIT,          // 等待关闭
    CLOSED
}

// 新建会话检查
action check_new_session() {
    // 检查是否是 SYN 包
    if (hdr.tcp.syn == 1 && hdr.tcp.ack == 0) {
        // 新建会话，允许并记录
        session_table.add();
    } else {
        // 非 SYN 包，拒绝
    }
}

// 会话验证
action verify_session() {
    // 检查会话是否存在且状态为 ESTABLISHED
    // 检查是否为合法的响应包
}
```

### 5.3 TCP 状态机转换

```
TCP 状态转换 (P4 有状态防火墙):
================================

  Client                         Server
    |                               |
    | ---- SYN ----------------->   | NEW_SYN
    |                               |
    | <--- SYN-ACK --------------- | SYN_ACK_SENT
    |                               |
    | ---- ACK ----------------->   | ESTABLISHED
    |                               |
    | ====== Data Flow ========>>   |
    |                               |
    | ---- FIN ----------------->   | FIN_WAIT
    |                               |
    | <--- ACK ------------------- |
    |                               |
    | <--- FIN --------------- ---- | CLOSE_WAIT
    |                               |
    | ---- ACK ----------------->   | CLOSED
    |                               |
```

---

## 6. 单播反向路径过滤 (uRPF)

### 6.1 什么是 uRPF？

**uRPF (unicast Reverse Path Forwarding)** 防止**源地址欺骗**攻击：

```
uRPF 工作原理:
==============

     Attacker                    Router
        |                          |
        | --- Spoofed Packet ---> |
        |    src=10.0.0.1          |
        |                          | 检查: 10.0.0.1 是否可从
        |                          | 收到该包的接口到达?
        |                          |
        | <--- ICMP Unreachable ---|
        |    (默认拒绝)

合法数据包:
     10.0.0.0/8                     Router
        |                          |
        | --- Packet ---------->   |
        |    src=10.1.2.3          |
        |                          | 检查: 10.1.2.3 是否可从
        |                          | 收到该包的接口到达? ✅
        |                          |
        |                          | Forward
```

### 6.2 P4 uRPF 实现

```c
// uRPF 检查表
table urpf_check {
    key = {
        // 使用 RPF 接口组
        hdr.ipv4.srcAddr: lpm;   // 源地址 LPM 查找
    }
    actions = {
        urpf_pass;               // 通过检查
        urpf_fail_drop;          // 失败丢弃
    }
}

// uRPF 动作实现
action urpf_pass() {
    // RPF 检查通过，继续处理
    meta.urpf_result = true;
}

action urpf_fail_drop() {
    // RPF 检查失败，丢弃并可能发送 ICMP
    // log_and_drop();
}
```

---

## 7. ACL 日志与镜像

### 7.1 命中统计

```c
// ACL 命中计数的 Direct Counter
direct_counter acl_counter32) with {
    table ipv4_acl;
}

table ipv4_acl {
    counters = acl_counter;

    key = {
        hdr.ipv4.srcAddr: ternary;
        hdr.ipv4.dstAddr: ternary;
    }
    actions = { allow; deny; }
}

// 每次 ACL 命中自动计数
```

### 7.2 镜像到 CPU

```c
// 特定流量镜像到控制面分析
action mirror_to_cpu() {
    // 创建数据包副本发送到 CPU 端口
    // 用于入侵检测、威胁分析
    clone_preserving_field_list(
        CloneType.I2E,           // Ingress to Egress
        CPU_MIRROR_SESSION_ID,    // 镜像会话 ID
        CPU_METADATA_FIELD_LIST   // 包含必要元数据的字段列表
    );
}
```

---

## 8. TCAM 资源压缩

### 8.1 TCAM 限制

TCAM 资源有限，需要压缩：

| 优化技术 | 说明 |
|---------|------|
| **合并相似规则** | 使用通配符减少规则数 |
| **使用 LPM 替代 Ternary** | /24 可以用 LPM 替代多个 /32 |
| **规则分组** | 按优先级分离表，减少单表大小 |
| **默认路由压缩** | 使用默认动作用于常见情况 |

### 8.2 压缩示例

```c
// 原始 ACL (16 条规则)
/*
deny   ip 10.0.0.0/8   any
deny   ip 172.16.0.0/12 any
deny   ip 192.168.0.0/16 any
permit ip 10.0.0.0/8   10.0.0.0/8
permit ip 10.1.0.0/16  10.1.0.0/16
...
*/

// 压缩后的 ACL (4 条规则)
// 合并私有地址段为一个更大的 CIDR
deny   ip 10.0.0.0/7    any          // 10.0.0.0/7 覆盖 10.x.x.x 和 11.x.x.x
deny   ip 172.16.0.0/11  any          // 172.16.0.0/11 覆盖 172.16-31.x.x
deny   ip 192.168.0.0/14  any         // 192.168.0.0/14 覆盖 192.168-171.x.x
permit ip 0.0.0.0/0      0.0.0.0/0    // 允许其他所有
```

---

## 9. ACL 与 QoS 集成

```c
// ACL 可以设置 QoS 优先级
action set_qos_and_allow(bit<3> pcp, bit<3> dscp) {
    // 设置 VLAN PCP (802.1p)
    hdr.vlan.pcp = pcp;

    // 设置 IP DSCP
    hdr.ipv4.diffserv = dscp << 2;  // DSCP 左移 2 位

    // 允许通过
}

// ACL 规则示例：VoIP 流量高优先级
table voip_acl {
    key = {
        hdr.ipv4.srcAddr:    ternary;
        hdr.ipv4.dstAddr:    ternary;
        hdr.ipv4.protocol:   ternary;  // UDP
        // 音频端口范围
    }
    actions = {
        set_qos_and_allow;   // EF (Expedited Forwarding)
        allow;               // 普通优先级
        deny;
    }
}
```

---

## 10. 总结

本章涵盖 P4 ACL 编程的核心内容：

1. **Match 类型**：Exact (精确)、Ternary (带掩码)、LPM (最长前缀)
2. **五元组过滤**：src/dst IP, Protocol, src/dst Port
3. **ACL 优先级**：规则顺序、级联表设计
4. **有状态防火墙**：会话跟踪、TCP 状态机
5. **uRPF 防欺骗**：源地址反向路径验证
6. **TCAM 压缩**：规则合并与优化
7. **ACL 与 QoS 集成**：安全与服务质量结合

ACL 是 P4 交换机的核心安全功能，与路由转发、QoS 等其他功能紧密配合。
