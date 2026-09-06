---
title: "RDMA 深度探索 (十)：UD vs RC 传输类型"
date: 2026-04-13
tags: [rdma, series, unreliable-datagram, reliable-connection, UD, RC, QP-type]
description: "深入对比 Unreliable Datagram (UD) 与 Reliable Connection (RC) 的语义、特性、适用场景，以及 RDMA CM 连接建立差异"
---

> [!info] RDMA 深度探索系列 0. [[rdma-deep-dive|全栈学习路径总览]]
>
> 1. [[ch1-rdma-overview|第一章：RDMA 概述]]
> 2. [[ch2-rdma-architecture|第二章：RDMA 架构]]
> 3. [[ch3-infiniband|第三章：InfiniBand 架构]]
> 4. [[ch4-roce|第四章：RoCE v1/v2]]
> 5. [[ch5-iwarp|第五章：iWARP]]
> 6. [[ch6-roce-vs-iwarp|第六章：RoCE vs iWARP 对比]]
> 7. [[ch7-queue-pair|第七章：队列对 (QP)]]
> 8. [[ch8-mr-pd|第八章：内存区域与保护域]]
> 9. [[ch9-verbs-api|第九章：Verbs API]]
> 10. **第十章：UD vs RC 传输类型**

---

## 1. 四种 QP 类型总览

RDMA 定义了四种 QP 类型：

| QP Type          | 全称                  | 可靠性    | 连接性 | 特性                                    |
| ---------------- | --------------------- | --------- | ------ | --------------------------------------- |
| `IBV_QPT_RC`     | Reliable Connection   | ✅ 可靠   | 连接型 | 有序、重传、支持 RDMA Read/Write/Atomic |
| `IBV_QPT_UD`     | Unreliable Datagram   | ❌ 不可靠 | 无连接 | 无序、无重传、不支持 RDMA Read/Write    |
| `IBV_QPT_UC`     | Unreliable Connection | ❌ 不可靠 | 连接型 | 有序、无重传                            |
| `IBV_QPT_RAW_IP` | Raw IP                | -         | -      | 原始 IP 报文（特殊用途）                |

最常用的是 **RC** 和 **UD**。

---

## 2. Reliable Connection (RC)

### 2.1 特性

```
┌─────────────────────────────────────────────────────────────┐
│              RC (Reliable Connection) 语义                  │
│                                                              │
│  Node A                                       Node B         │
│  ┌─────────────┐                            ┌─────────────┐ │
│  │ QP 1        │◄══════════════════════════►│ QYP 1       │ │
│  │ (client)   │     双向有序字节流           │ (server)   │ │
│  └─────────────┘                            └─────────────┘ │
│                                                              │
│  特性：                                                      │
│  - 点对点连接（1:1）                                         │
│  - 可靠：丢包自动重传                                        │
│  - 有序：按发送顺序接收                                      │
│  - 支持 RDMA Read/Write/Atomic (One-sided)                  │
│  - 需要连接建立（三次握手）                                  │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 连接建立

RC QP 必须先建立连接才能收发：

```
RDMA CM 连接建立过程：

Client                                  Server
  │                                        │
  │  RESOLVE_ADDR (解析目标地址)            │
  │────────────────────────────────────────►│
  │                                        │
  │  RESOLVE_ROUTE (解析路由)               │
  │────────────────────────────────────────►│
  │                                        │
  │  CONNECT_REQUEST (qp_num, gid, ...)     │
  │────────────────────────────────────────►│
  │                                        │
  │                     ACCEPT (qp_num, ...)│
  │◄────────────────────────────────────────│
  │                                        │
  │  COMPLETE (双方进入 RTS)                │
  │◄────────────────────────────────────────►│

  QP 状态：
  Client: RESET → INIT → RTR → RTS
  Server: RESET → INIT → RTR → RTS
```

### 2.3 支持的操作

| 操作                 | RC 支持 | 说明                       |
| -------------------- | ------- | -------------------------- |
| Send/Recv            | ✅      | 双向消息传递               |
| RDMA Read            | ✅      | One-sided 读（远端无感知） |
| RDMA Write           | ✅      | One-sided 写（远端无感知） |
| Atomic CAS/Fetch&Add | ✅      | 原子操作                   |
| Send with Imm        | ✅      | 带立即数发送               |

### 2.4 代码示例

```c
// 创建 RC QP
struct ibv_qp_init_attr qp_attr = {
    .qp_type = IBV_QPT_RC,
    .cap     = { .max_send_wr = 128, .max_recv_wr = 128 },
    .send_cq = cq,
    .recv_cq = cq,
};
struct ibv_qp *qp = ibv_create_qp(pd, &qp_attr);

// RC QP 修改到 RTS 后即可收发
// RDMA Read/Write 使用 remote_addr + rkey
struct ibv_send_wr rdma_read_wr = {
    .opcode      = IBV_WR_RDMA_READ,
    .remote_addr  = remote_addr,
    .rkey         = remote_rkey,
    ...
};
```

---

## 3. Unreliable Datagram (UD)

### 3.1 特性

```
┌─────────────────────────────────────────────────────────────┐
│              UD (Unreliable Datagram) 语义                   │
│                                                              │
│  Node A                                                     │
│  ┌─────────────┐                                           │
│  │ QP 1        │                                           │
│  │             │──────────────────┐                        │
│  │             │◄─────────────────┤                        │
│  │             │                  │                        │
│  │             │──────────────┐   │                        │
│  │             │◄─────────────┤   │                        │
│  └─────────────┘              │   │   多个远端节点          │
│                               │   │   (无连接)              │
│                               ▼   ▼                         │
│  一个 UD QP 可以与多个节点通信  Node B, C, D ...             │
│                                                              │
│  特性：                                                      │
│  - 无连接：一个 QP 对应多个远端（1:N 或 N:1）                │
│  - 不可靠：可能丢包                                         │
│  - 无序：不保证按发送顺序接收                               │
│  - 只支持 Send/Recv（不支持 RDMA Read/Write）               │
│  - 每个报文携带源 GID/LID                                   │
└─────────────────────────────────────────────────────────────┘
```

### 3.2 为什么需要 GID/LID？

UD 无连接，远端收到报文后需要知道回复给谁。IB 报文头携带源地址：

```c
// 接收 UD 报文时，WC 中包含源地址信息
struct ibv_wc {
    // ...
    union {
        uint32_t  imm_data;    // 接收到的立即数
        struct {
            uint32_t slid;     // 源 LID
            uint32_t dlid;     // 目的 LID (本地)
        } grh;                 // Global Routing Header
    };
    uint16_t  pkey_index;      // Partition Key
    uint32_t  src_qp;          // 源 QP 号（回复时用）
};
```

发送 UD 报文需要指定目标地址（通过 AH - Address Vector）：

```c
struct ibv_ah_attr {
    .dgid     = target_gid;    // 目标 GID
    .flow_label = 0;
    .sfid     = 0;
    .dlid     = target_lid;    // 目标 LID
    .sl       = 0;             // Service Level
    .src_path_bits = 0;
    .port_num = 1;
};

// 创建 Address Handle (AH)
struct ibv_ah *ah = ibv_create_ah(pd, &ah_attr);

// Post UD Send
struct ibv_send_wr wr = {
    .opcode = IBV_WR_SEND,
        .wr.ud = {
            .ah   = ah,       // 路由信息
            .qkey = 0x111111, // Q_Key（类似 UDP port）
            .qp_num = remote_qp_num, // 目标 QP 号
        },
    ...
};
```

### 3.3 Q_Key

UD 模式下，Q_Key 类似于 UDP 的目的端口号，提供额外的隔离机制：

```c
// 接收方需要设置 Q_Key
struct ibv_qp_attr attr;
attr.qp_state = IBV_QPS_INIT;
attr.pkey_index = 0;
attr.port_num = 1;
attr.qkey = 0x111111;  // 必须与发送方匹配
ibv_modify_qp(qp, &attr, IBV_QP_STATE | IBV_QP_PKEY_INDEX |
              IBV_QP_PORT | IBV_QP_QKEY);
```

### 3.4 支持的操作

| 操作          | UD 支持 | 说明     |
| ------------- | ------- | -------- |
| Send/Recv     | ✅      | 消息传递 |
| Send with Imm | ✅      | 带立即数 |
| RDMA Read     | ❌      | 不支持   |
| RDMA Write    | ❌      | 不支持   |
| Atomic        | ❌      | 不支持   |

---

## 4. UD vs RC 对比

| 特性                | UD                       | RC                 |
| ------------------- | ------------------------ | ------------------ |
| **可靠性**          | 不可靠，可能丢包         | 可靠，自动重传     |
| **有序性**          | 无序                     | 有序               |
| **连接性**          | 无连接（多播天然支持）   | 面向连接（1:1）    |
| **RDMA Read/Write** | ❌ 不支持                | ✅ 支持            |
| **Atomic 操作**     | ❌ 不支持                | ✅ 支持            |
| **多播**            | ✅ 原生支持              | ❌ 需要多 QP       |
| **吞吐量**          | 较低（无 ACK 确认）      | 较高               |
| **适用场景**        | 分布式键值存储、路由协议 | HPC、AI 训练、存储 |
| **编程复杂度**      | 较高（需处理丢包）       | 较低（透明可靠）   |

---

## 5. 典型应用场景

### 5.1 RC 典型场景：HPC MPI、AI 训练

```
AI 训练 (NCCL):
  Node 0 ──── RC QP ──── Node 1
    │                         │
    │        RC QP            │
    └──────────────┬──────────┘
                   │
                   ▼
             Ring/Tree AllReduce
             (可靠有序保证)

特点：
- 每个节点对之间建立 RC QP
- 使用 RDMA Write 进行高速数据传输
- 无丢包重传负担
```

### 5.2 UD 典型场景：分布式键值存储

```
分布式 Redis (使用 RDMA):
  Node A ─── UD QP ───┬── Node B
                      │
                      ├── Node C
                      │
                      └── Node D

特点：
- 一个 QP 服务所有节点
- 适合 PUT/GET 请求（单边操作少）
- 丢包需应用层处理（超时重传）
- 多播用于广播新节点列表
```

### 5.3 UD 多播

UD QP 最适合多播，因为一个 QP 可以向多个目标发送：

```
┌─────────────────────────────────────────────────────┐
│              UD 多播                                │
│                                                      │
│  Node A                                             │
│  ┌─────────────┐                                    │
│  │ UD QP       │                                    │
│  │             │──► GID: ff12::xxxx:xxxx:multicast  │
│  │             │   (多播组 GID)                      │
│  └─────────────┘                                    │
│                     Switch                          │
│                     ┌────┬────┬────┐               │
│                     ▼    ▼    ▼                   │
│                   Node B Node C Node D             │
│                   (全部加入同一个多播组)             │
└─────────────────────────────────────────────────────┘
```

Join/Leave 多播组：

```c
struct ibv_qp_attr attr;
attr.qp_state = IBV_QPS_INIT;
ibv_modify_qp(qp, &attr, IBV_QP_STATE);

// 加入多播组
ibv_attach_qp_to_mc(qp, multicast_gid, multicast_lid);

// 发送（目标地址使用多播 GID）
ibv_post_send(qp, &wr, &bad_wr);

// 离开多播组
ibv_detach_qp_from_mc(qp, multicast_gid, multicast_lid);
```

---

## 6. 错误处理差异

### 6.1 RC 错误处理

```c
// 轮询到错误 Completion
struct ibv_wc wc;
ibv_poll_cq(cq, 1, &wc);

if (wc.status == IBV_WC_RETRY_EXC_ERR) {
    // 网络故障或远端无响应，自动重传耗尽
    printf("重试次数耗尽，连接可能已断开\n");
    // 处理：重建连接
} else if (wc.status == IBV_WC_RNR_RETRY_EXC_ERR) {
    // RNR (Receiver Not Ready) 错误
    // 对方未 post Recv WR
    printf("远端未准备接收，重传中...\n");
}
```

### 6.2 UD 错误处理

UD 丢包不重传，需要应用层处理：

```c
// UD 丢包处理（应用层超时）
struct timespec start, now;
clock_gettime(CLOCK_MONOTONIC, &start);

// 发送请求
ibv_post_send(qp, &send_wr, &bad_wr);

// 等待响应
while (waiting) {
    int ne = ibv_poll_cq(cq, 1, &wc);
    if (ne > 0) {
        if (wc.status == IBV_WC_SUCCESS &&
            wc.opcode == IBV_WC_RECV) {
            // 收到响应
            break;
        }
    }
    clock_gettime(CLOCK_MONOTONIC, &now);
    if (elapsed_ms(&now, &start) > TIMEOUT_MS) {
        // 超时重传
        ibv_post_send(qp, &send_wr, &bad_wr);
        clock_gettime(CLOCK_MONOTONIC, &start);
    }
}
```

---

## 7. 性能差异

```
RDMA Send/Recv 延迟对比 (典型 Mellanox ConnectX-7)

RC:
  ┌──────────────────────────────────────────────┐
  │ 单向延迟: ~1.5μs                             │
  │ 双向延迟: ~2.0μs                             │
  │ 吞吐: 接近线速 (100-200 Gb/s)               │
  │                                                │
  │ 时序:                                        │
  │  Client          Server                      │
  │    │─── SEND ────►│                          │
  │    │◄── ACK ──────│                          │
  │    │──────────────│ (可靠，有序)             │
  └──────────────────────────────────────────────┘

UD:
  ┌──────────────────────────────────────────────┐
  │ 单向延迟: ~1.2μs (略低，无 ACK 确认)        │
  │ 吞吐: 略低于 RC (无重传确认)                 │
  │                                                │
  │ 时序:                                        │
  │  Client          Server                      │
  │    │─── DATAGRAM ─►│ (无 ACK)              │
  │    │                │                        │
  │    │───────────────│ (不可靠)               │
  └──────────────────────────────────────────────┘
```

---

## 8. 常见问题

**Q: RDMA Write 只能用 RC QP？**
A: 是的。RDMA Read/Write/Atomic 只支持可靠连接（RC/UC）。UD 不支持这些操作，因为无连接时无法指定 rkey 和远端地址。

**Q: UD 为什么能天然支持多播？**
A: 因为 UD 无连接，一个 QP 可以向任意多个目标发送报文（通过不同 AH）。而 RC 是 1:1 连接，不支持多播。

**Q: 可以同时使用 UD 和 RC 吗？**
A: 可以。很多应用同时使用 UD（控制面/多播）和 RC（数据传输）。例如：MPI 使用 UD 做进程发现，RC 做数据传输。

**Q: UD 的 MTU 限制？**
A: UD 报文不能超过 MTU（通常 4096B）。如果要发送大消息，需要应用层分片。

**Q: 什么时候选 UD 而不是 RC？**
A: 需要多播功能时、接收方不固定时（无连接）、应用层能处理丢包和重传时。
