---
title: "P4 深度探索 (三十四)：P4 负载均衡编程——ECMP、Flowlet 负载均衡、ATP 保序感知负载均衡"
date: 2026-04-14
tags: [p4, series, load-balancer, ecmp, flowlet, atp, network, hashing, p4-16]
description: "P4 负载均衡编程深度解析——ECMP 等价多路径哈希、Flowlet 检测与调度、ATP (Application Transparent Proxy) 保序感知负载均衡、会话保持、Maglev 一致性哈希"
---

> [!info] P4 深度探索系列 0. [[p4-deep-dive|全栈学习路径总览]]
>
> 1. [[ch1-p4-overview|第一章：P4 概述——诞生背景与协议无关包处理]]
> 2. [[ch2-p4-architecture|第二章：P4 架构模型——PSA/V1Model、Ingress/Egress]]
> 3. [[ch3-p4-vs-ebpf|第三章：P4 vs eBPF——适用场景与硬件/软件对比]]
>    ...
> 4. [[ch30-p4-control-plane-advanced|第三十章：P4 控制面高级主题]]
> 5. [[ch31-basic-routing|第三十一章：P4 基础路由编程]]
> 6. [[ch32-access-list|第三十二章：P4 ACL 编程]]
> 7. [[ch33-vlan-vxlan|第三十三章：P4 VLAN/VXLAN 编程]]
> 8. **第三十四章：P4 负载均衡编程——ECMP、Flowlet 负载均衡、ATP 保序感知负载均衡**

---

## 1. 概述：负载均衡的类型

**负载均衡 (Load Balancing)** 将流量分配到多个后端服务器/链路，核心挑战是**如何分配**且**如何保证顺序**。

```
负载均衡架构:
=============

       Client
          |
          v
    +-------------+
    | Load Balancer |
    | (P4 Switch)  |
    +-------------+
      |    |    |
      v    v    v
   +---+ +---+ +---+
   |srv1| |srv2| |srv3|
   +---+ +---+ +---+

负载均衡算法:
  - ECMP: 基于流哈希
  - Flowlet: 基于流片检测
  - ATP: 保序感知
  - Least-Connection: 最少连接
```

### 1.1 负载均衡类型对比

| 类型                 | 说明              | 保序性           | 适用场景        |
| -------------------- | ----------------- | ---------------- | --------------- |
| **ECMP**             | 基于 5-tuple 哈希 | 同一 Flow 内保序 | L3 链路负载均衡 |
| **Flowlet**          | 基于流间隙检测    | 流内可能乱序     | 短流场景        |
| **ATP**              | 代理层保序        | 完全保序         | TCP 应用        |
| **Least-Connection** | 动态计数          | 保序             | HTTP 长连接     |

---

## 2. ECMP (Equal Cost Multi-Path)

### 2.1 ECMP 原理

ECMP 将**相同 cost** 的多条路径视为等价，通过**哈希**将同一 flow 的流量分配到同一路径：

```
ECMP 哈希分配:
==============

Flow Hash = hash(src_ip, dst_ip, protocol, src_port, dst_port)

Paths:
  path[hash % 4] = { nexthop_1, nexthop_2, nexthop_3, nexthop_4 }

示例:
  Client 1.1.1.1 -> Server 2.2.2.2, TCP 80
  Hash = f(src=1.1.1.1, dst=2.2.2.2, proto=6, port=12345, dst=80)
  hash % 4 = 2 --> 选择 nexthop_2
```

### 2.2 P4 ECMP 实现

```c
// ECMP 组表定义
struct ecmp_metadata_t {
    bit<16> ecmp_group_id;       // ECMP 组 ID
    bit<8>  ecmp_member_count;   // 组内成员数
    bit<16> ecmp_hash;           // 计算的哈希值
    bit<8>  selected_nhop_index; // 选中的下一跳索引
}

// ECMP 组表: group_id -> {member_ips}
table ecmp_group_table {
    key = {
        meta.ecmp_group_id: exact;
    }
    actions = {
        set_ecmp_members;  // 设置组成员
    }
}

// ECMP 成员选择表
table ecmp_select_table {
    key = {
        meta.ecmp_group_id:   exact;
        meta.selected_nhop_index: exact;
    }
    actions = {
        set_nexthop;         // 设置选中的下一跳
        drop;
    }
}

// ECMP 哈希计算
action compute_ecmp_hash() {
    hash(
        meta.ecmp_hash,
        HashAlgorithm.crc16,
        /* base = */ (bit<16>)0,
        {
            hdr.ipv4.srcAddr,
            hdr.ipv4.dstAddr,
            hdr.ipv4.protocol,
            hdr.tcp.srcPort,
            hdr.tcp.dstPort
        },
        /* max = */ 256  // 哈希范围
    );
}

// ECMP 主控制逻辑
control ecmp(inout headers hdr,
             inout metadata_t meta,
             inout standard_metadata_t sm) {

    // L3 路由表返回 ECMP 组 ID
    table l3_route {
        key = {
            hdr.ipv4.dstAddr: lpm;
        }
        actions = {
            // 找到 ECMP 组
            set_ecmp_group_id;  // 设置 meta.ecmp_group_id
            set_nexthop;        // 单一下一跳（非 ECMP）
            drop;
        }
    }

    apply {
        // Step 1: 路由查找
        l3_route.apply();

        // Step 2: 如果是 ECMP 路径
        if (meta.ecmp_group_id != 0) {
            // Step 2a: 计算哈希
            compute_ecmp_hash();

            // Step 2b: 获取组成员数量
            ecmp_group_table.apply();

            // Step 2c: 选择下一跳
            meta.selected_nhop_index = (bit<8>)(meta.ecmp_hash % meta.ecmp_member_count);
            ecmp_select_table.apply();
        }
    }
}
```

---

## 3. Flowlet 负载均衡

### 3.1 Flowlet 概念

**Flowlet** 是 flow 中的**一片连续数据包**，以**间隙 (gap)** 分割：

```
Flow vs Flowlet:
================

Flow (传统):                    FlowLet:
+---------+---------+---------+    +------+  +------+  +------+
| pkt 1   | pkt 2   | pkt 3   |    |let 1 |  |let 2 |  |let 3 |
+---------+---------+---------+    +------+  +------+  +------+
|<------- flow time -------->|    |<--gap-->|<--gap-->|
(所有包必须同一条路径)            (间隙允许换路)

Flowlet 优势:
  - 短间隙的包可以换路，提高负载均衡效果
  - 长连接的包不会乱序
```

### 3.2 Flowlet 检测

```c
// Flowlet 检测状态
struct flowlet_state_t {
    bit<32> last_pkts_time;      // 上一包时间戳
    bit<8>  last_path;           // 上一包走的路径
    bit<16> flowlet_id;          // Flowlet ID (递增)
    bool    active;              // Flow 是否活跃
}

// Flowlet 检测表
table flowlet_table {
    key = {
        hdr.ipv4.srcAddr:   exact;
        hdr.ipv4.dstAddr:   exact;
        hdr.ipv4.protocol: exact;
        hdr.tcp.srcPort:    exact;
        hdr.tcp.dstPort:    exact;
    }
    actions = {
        // 更新 flowlet 状态
        update_flowlet;
        create_new_flowlet;
    }
}

// Flowlet 检测逻辑
action check_flowlet_gap() {
    bit<32> current_time = sm.timestamp;

    // 计算与上一包的时间差
    bit<32> gap = current_time - meta.flowlet_last_time;

    // 如果 gap > 阈值 (例如 100ms)，创建新的 flowlet
    if (gap > FLOWLET_GAP_THRESHOLD) {
        meta.flowlet_id = meta.flowlet_id + 1;
        meta.new_flowlet = true;
    } else {
        meta.new_flowlet = false;
    }

    meta.flowlet_last_time = current_time;
}

// Flowlet 路径选择
action select_path_for_flowlet(bit<8> path_id) {
    meta.selected_path = path_id;
    // 更新 flowlet 状态
    meta.flowlet_last_path = path_id;
}
```

### 3.3 Flowlet 调度

```c
// Flowlet 路径分配表
table flowlet_path_table {
    key = {
        // Flow 的 5-tuple
        hdr.ipv4.srcAddr:   exact;
        hdr.ipv4.dstAddr:   exact;
        hdr.tcp.srcPort:    exact;
        hdr.tcp.dstPort:    exact;
        // Flowlet ID (同一 flow 的不同 flowlet 可能走不同路径)
        meta.flowlet_id:    exact;
    }
    actions = {
        assign_path;         // 为该 flowlet 分配路径
        drop;
    }
}

// Flowlet 负载均衡控制
control flowlet_lb(inout headers hdr,
                   inout metadata_t meta,
                   inout standard_metadata_t sm) {

    // 活跃流表
    table active_flow_table {
        key = { /* 5-tuple */ }
        actions = { no_action; }
    }

    apply {
        // Step 1: 检查是否是活跃 flow
        active_flow_table.apply();

        // Step 2: 如果是新包，检查是否需要新建 flowlet
        if (sm.pkt_length > 0) {
            check_flowlet_gap();
        }

        // Step 3: 为该 flowlet 分配路径
        if (meta.new_flowlet || !meta.path_assigned) {
            // 重新计算哈希，选择路径
            compute_flowlet_hash();
            flowlet_path_table.apply();
        }
    }
}
```

---

## 4. ATP (Application Transparent Proxy)

### 4.1 ATP 原理

**ATP (Application Transparent Proxy)** 是 L4 负载均衡器，在**不修改客户端/服务器**的情况下实现：

- **连接聚合**：多个客户端连接到 LB，LB 聚合到少量服务器连接
- **保序**：同一客户端的包必须保序发送
- **连接复用**：复用服务器连接提高效率

```
ATP 架构:
=========

  Client A          Client B          Client C
     |                 |                 |
     +-----------------+-----------------+
                       |
                       v
              +-----------------+
              |   ATP/LB (P4)   |
              |                 |
              |  - 客户端侧监听  |
              |  - 服务器侧连接  |
              |  - 数据包转发    |
              +-----------------+
                       |
                       v
                  Server Farm

ATP 连接映射:
  Client A:port1 <--> LB <--> Server X:port1
  Client B:port1 <--> LB <--> (复用 Server X:port1)
  Client C:port1 <--> LB <--> Server Y:port1
```

### 4.2 ATP 连接表

```c
// ATP 元数据
struct atp_metadata_t {
    bit<32> client_ip;
    bit<16> client_port;
    bit<32> server_ip;
    bit<16> server_port;

    bit<32> atp_conn_id;         // ATP 连接 ID
    bit<1>  is_client_side;      // 是客户端侧还是服务器侧
    bit<2>  conn_state;           // 连接状态
}

// ATP 连接表 (客户端侧)
table atp_client_table {
    key = {
        hdr.ipv4.srcAddr: exact;   // 客户端 IP
        hdr.tcp.srcPort:  exact;   // 客户端端口
    }
    actions = {
        // 查找对应的服务器连接
        lookup_server_conn;
        // 新建连接
        create_server_conn;
        drop;
    }
}

// ATP 连接表 (服务器侧)
table atp_server_table {
    key = {
        hdr.ipv4.dstAddr: exact;   // 服务器 IP
        hdr.tcp.dstPort:  exact;   // 服务器端口
    }
    actions = {
        // 查找对应的客户端连接
        lookup_client_info;
        drop;
    }
}

// 连接状态
enum atp_conn_state_t {
    SYN_SENT,         // 等待服务器 SYN-ACK
    ESTABLISHED,      // 连接已建立
    CLOSING           // 正在关闭
}
```

### 4.3 ATP 包处理

```c
// ATP 客户端侧处理
control atp_client_side(inout headers hdr,
                        inout metadata_t meta,
                        inout standard_metadata_t sm) {

    // 服务器选择表
    table server_selection {
        key = {
            // 可以使用加权 Least-Connection
            meta.server_weight: exact;
            meta.active_conns:  exact;
        }
        actions = {
            select_server;
        }
    }

    action handle_client_syn() {
        // 客户端 SYN：创建 ATP 连接记录
        // 选择一个服务器
        server_selection.apply();

        // 记录客户端信息
        meta.client_ip = hdr.ipv4.srcAddr;
        meta.client_port = hdr.tcp.srcPort;
        meta.atp_conn_state = SYN_SENT;

        // 转发到服务器，替换源地址为 LB VIP
        hdr.ipv4.srcAddr = VIP;
        // 记录 NAT 映射用于回程
    }

    action handle_client_data() {
        // 客户端数据包
        // 查表找到对应的服务器连接
        atp_client_table.apply();

        // 替换源地址为 VIP
        hdr.ipv4.srcAddr = VIP;
        // 替换源端口为连接 ID (用于追踪)
        hdr.tcp.srcPort = meta.atp_conn_id;
    }

    apply {
        if (hdr.tcp.syn == 1 && hdr.tcp.ack == 0) {
            handle_client_syn();
        } else if (hdr.tcp.isValid()) {
            handle_client_data();
        }
    }
}

// ATP 服务器侧处理
control atp_server_side(inout headers hdr,
                        inout metadata_t meta,
                        inout standard_metadata_t sm) {

    action handle_server_syn_ack() {
        // 服务器 SYN-ACK：查找对应的客户端
        atp_server_table.apply();

        // 替换目标地址为客户端
        hdr.ipv4.dstAddr = meta.client_ip;
        hdr.tcp.dstPort = meta.client_port;

        meta.atp_conn_state = ESTABLISHED;
    }

    action handle_server_data() {
        // 服务器数据包
        // 查表找到客户端信息
        atp_server_table.apply();

        // 替换目标地址
        hdr.ipv4.dstAddr = meta.client_ip;
        hdr.tcp.dstPort = meta.client_port;
    }

    apply {
        if (hdr.tcp.syn == 1 && hdr.tcp.ack == 1) {
            handle_server_syn_ack();
        } else if (hdr.tcp.isValid()) {
            handle_server_data();
        }
    }
}
```

---

## 5. 一致性哈希 (Maglev)

### 5.1 Maglev 概述

**Maglev** 是 Google 开发的负载均衡器，使用**一致性哈希**实现：

- **最小化重映射**：后端变更时，只影响少数 flow
- **无需查表**：通过计算直接得到目标服务器
- **服务器权重**：支持不同容量服务器不同权重

```
Maglev 一致性哈希:
==================

  查找表 (Lookup Table) 大小 M = 65537
  每个服务器在表中出现 N 次 (N 约 100-200)

  服务器 A: [h1_A, h2_A, ..., hN_A]  (基于 hash 生成位置)
  服务器 B: [h1_B, h2_B, ..., hN_B]
  ...

  查找: packet --> hash --> offset = hash % M --> table[offset]
```

### 5.2 P4 Maglev 实现

```c
// Maglev 表定义
table maglev_table {
    key = {
        // 使用 flow hash 作为 offset
        // (实际需要 Pre-LB 哈希计算)
        sm.packet_offset: exact;  // M-sized table 的 offset
    }
    actions = {
        set_backend_server;
        drop;
    }
}

// Maglev 偏移计算
action compute_maglev_offset() {
    hash(
        meta.maglev_offset,
        HashAlgorithm.crc32,
        0,
        {
            hdr.ipv4.srcAddr,
            hdr.ipv4.dstAddr,
            VIP,
            hdr.tcp.srcPort,
            hdr.tcp.dstPort
        },
        MAGLEV_M_SIZE  // 65537
    );
}

// 服务器加权选择
action select_weighted_server(bit<16> server_id) {
    meta.selected_server = server_id;
    // 服务器 ID 用于后续处理
}
```

---

## 6. 会话保持 (Session Persistence)

### 6.1 会话保持需求

某些应用需要同一客户端的请求都发送到**同一后端服务器**：

- **购物车**：会话状态存储在服务器
- **SSL 握手**：TLS 会话票证
- **长连接**：WebSocket

### 6.2 会话保持实现

```c
// 会话保持表 (基于 Cookie 或 IP)
table persistence_table {
    key = {
        // 方法 1: 基于 Cookie
        hdr.http.cookie: exact;
        // 方法 2: 基于源 IP
        hdr.ipv4.srcAddr: lpm;
    }
    actions = {
        set_sticky_server;   // 设置固定的服务器
        create_sticky_entry; // 新建绑定
    }
}

// Cookie 解析
header http_t {
    bit<16> srcPort;
    bit<16> dstPort;
    // ... HTTP header fields
    bit<512> cookie;         // Cookie header
}

action extract_sticky_cookie() {
    // 从 HTTP Cookie 中提取会话 ID
    // 例如: JSESSIONID=ABC123
    meta.session_id = extract_session_id(hdr.http.cookie);
}
```

---

## 7. DSR (Direct Server Return)

### 7.1 DSR 架构

**DSR** 模式下，负载均衡器只处理**入方向**，**出方向**直接由服务器返回：

```
DSR 架构:
=========

  Request:                    Response:
  Client --> LB --> Server    Server ---> Client (直接)
         (VIP)                     (源IP = VIP)
```

### 7.2 P4 DSR 实现

```c
// DSR 入向处理
control dsr_ingress(inout headers hdr,
                     inout metadata_t meta,
                     inout standard_metadata_t sm) {

    // DSR VIP 路由表
    table dsr_vip_table {
        key = {
            hdr.ipv4.dstAddr: exact;  // 匹配 VIP
        }
        actions = {
            dsr_select_backend;
            drop;
        }
    }

    action dsr_select_backend(bit<32> server_ip) {
        // 替换目的 IP 为选中的服务器 IP
        hdr.ipv4.dstAddr = server_ip;

        // 保持源 IP 为客户端 IP
        // 记录服务器 MAC 用于后续处理
        meta.backend_mac = server_mac_table.lookup(server_ip);
    }

    // 服务器 MAC 表
    table server_mac_table {
        key = { server_ip: exact; }
        actions = { set_mac; }
    }
}
```

---

## 8. 总结

本章涵盖 P4 负载均衡编程的核心内容：

1. **ECMP**：基于 5-tuple 哈希的等价多路径负载均衡
2. **Flowlet**：基于流间隙检测的细粒度负载均衡，提高链路利用率
3. **ATP**：L4 代理式负载均衡，实现连接复用与保序
4. **Maglev**：一致性哈希，最小化后端变更影响
5. **会话保持**：Cookie/IP 绑定确保同一客户端访问同一服务器
6. **DSR**：直接服务器返回，减少 LB 负载

这些技术组合使用，可以构建高性能、可扩展的 L4/L7 负载均衡系统。
