---
title: "RDMA 第三十六章：SRQ 共享接收队列——多 QP 共享与资源优化"
date: 2026-04-14
tags: [rdma, SRQ, shared-receive-queue, QP, scalability, resources, roce, infiniband]
description: "详解 RDMA SRQ 共享接收队列：SRQ 与 per-QP RQ 的对比、SRQ 创建与配置、SRQ + UC/RC/RD 支持、SRQ 性能优化、以及 SRQ 在大规模部署中的最佳实践。"
---

> [!abstract] 核心要点
> SRQ 是 RDMA 中优化接收侧资源的关键机制——多个 QP 共享一个接收队列，大幅降低高并发场景下的内存开销。本章详解 SRQ 的工作原理、与 per-QP RQ 的对比、libibverbs API 使用、以及大规模部署中的最佳实践。

---

## 1. 为什么需要 SRQ？

### 1.1 Per-QP 接收队列的扩展性问题

在标准 RC/UC QP 模型中，每个 QP 都有独立的 Send Queue (SQ) 和 Receive Queue (RQ)：

```
传统模型（每个 QP 独立 RQ）：

  QP1:  SQ + RQ（各 N WQE）
  QP2:  SQ + RQ（各 N WQE）
  QP3:  SQ + RQ（各 N WQE）
  ...
  QP10000: SQ + RQ（各 N WQE）

问题：
- 10,000 个 QP × N × sizeof(WQE) = 巨大内存
- 每个 RQ 即使空转也要预留空间
- 连接数增长时内存不可扩展
```

### 1.2 SRQ 的解决思路

SRQ（Shared Receive Queue）允许**多个 QP 共享一个接收队列**：

```
SRQ 模型：

  SRQ（共享 RQ，M WQE）
    ↑
  QP1: SQ
  QP2: SQ
  QP3: SQ
  ...
  QP10000: SQ

优势：
- 内存大幅降低：M × sizeof(WQE) vs 10000 × N × sizeof(WQE)
- 动态调整：根据实际负载分配 WQE
- 更高效的资源利用
```

### 1.3 SRQ 典型应用场景

- **Kubernetes 多租户 RDMA**：每个 Pod 一个 QP，共享节点级 SRQ
- **高性能计算（HPC）**：大规模 MPI 通信，QPs 数量巨大
- **RDMA 数据库**：数千并发连接共享接收资源
- **Web 服务器**：短生命周期 RDMA 连接

---

## 2. SRQ 工作原理

### 2.1 SRQ 与 QP 的关系

SRQ 本质上是一个**共享的接收缓冲区**，与普通 QP 的 RQ 有以下区别：

| 特性           | Per-QP RQ    | SRQ          |
| -------------- | ------------ | ------------ |
| 绑定方式       | QP 私有      | 多个 QP 共享 |
| WQE 数量       | 静态配置     | 动态调整     |
| 内存开销       | O(N × QP数)  | O(SRQ_WQE)   |
| Post Rx 灵活性 | 仅 QP 所有者 | 任何共享 QP  |
| 支持类型       | RC/UC/UD     | RC/UC/RD/UD  |

### 2.2 SRQ 的工作流程

```
1. 创建 SRQ
   ├── ibv_create_srq() / ibv_create_srq_ex()
   └── 配置 SRQ 属性（max_wr, max_sge, srq_type）

2. 创建 QP 时关联 SRQ
   ├── ibv_create_qp_attr.srq = SRQ
   └── QP 的 RQ 不再独立分配，而是指向 SRQ

3. Post Receive 操作
   ├── ibv_post_srq_recv()  ← 多个 QP 的接收请求都 post 到同一个 SRQ
   └── 所有共享该 SRQ 的 QP 都可以消费 SRQ 中的 WQE

4. 接收数据
   ├── 网卡收到数据包，根据 LID/GID 找到目标 QP
   ├── QP 查找关联的 SRQ，从 SRQ 中取出 WQE 处理
   └── 完成通知通过对应 QP 的 CQ
```

### 2.3 SRQ WQE 消费顺序

SRQ 中的 WQE 由**共享该 SRQ 的任意 QP** 按到达顺序消费：

```
SRQ（WQE 队列）:
  WQE[0] → QP1 的接收缓冲区
  WQE[1] → QP3 的接收缓冲区
  WQE[2] → QP7 的接收缓冲区
  WQE[3] → QP2 的接收缓冲区

数据包路由：
  Packet → 目标 QP → 从 SRQ 取出下一个可用 WQE → 填充数据
```

---

## 3. SRQ API 与创建

### 3.1 SRQ 创建

```c
// 标准 SRQ 创建（libibverbs）
struct ibv_srq_init_attr srq_init_attr = {
    .attr.max_wr  = 1000,     // SRQ 最大 WQE 数
    .attr.max_sge = 1,        // 每个 WQE 最大 SGE 数
    .attr.srq_type = IBV_SRQT_BASIC,  // 基本 SRQ
};

struct ibv_srq *srq = ibv_create_srq(pd, &srq_init_attr);
if (!srq) {
    perror("Failed to create SRQ");
}

// 扩展 SRQ 创建（支持 RD/更多特性）
struct ibv_srq_init_attr_ex srq_init_attr_ex = {
    .attr.max_wr        = 1000,
    .attr.max_sge       = 1,
    .srq_type           = IBV_SRQT_BASIC,
    .pd                 = pd,
    .comp_mask          = IBV_SRQT_TYPE,
};

struct ibv_srq *srq = ibv_create_srq_ex(ctx, &srq_init_attr_ex);
```

### 3.2 SRQ 属性查询与修改

```c
// 查询 SRQ 属性
struct ibv_srq_attr srq_attr;
ibv_query_srq(srq, &srq_attr);

// 修改 SRQ（例如动态调整 max_wr）
struct ibv_srq_attr attr = {
    .max_wr = 2000,  // 新的最大 WQE 数
};
ibv_modify_srq(srq, &attr, IBV_SRQ_LIMIT_MASK);
```

### 3.3 QP 关联 SRQ

```c
// 创建 QP 时关联 SRQ
struct ibv_qp_init_attr qp_init_attr = {
    .send_cq = cq,
    .recv_cq = cq,
    .srq     = srq,         // 关联 SRQ
    .cap     = {
        .max_send_wr = 100,
        .max_send_sge = 1,
        .max_inline_data = 0,
    },
    .qp_type = IBV_QPT_RC,
};

struct ibv_qp *qp = ibv_create_qp(pd, &qp_init_attr);
```

### 3.4 Post Receive 到 SRQ

```c
// Post WQE 到 SRQ（多个 QP 共享同一个 SRQ）
struct ibv_recv_wr wr = {
    .wr_id   = (uint64_t)context,
    .sg_list = &sge,
    .num_sge = 1,
};

struct ibv_recv_wr *bad_wr;
int ret = ibv_post_srq_recv(srq, &wr, &bad_wr);

if (ret) {
    fprintf(stderr, "Failed to post SRQ receive: %d\n", ret);
}
```

---

## 4. SRQ 类型与扩展

### 4.1 SRQ Type: Basic (IBV_SRQT_BASIC)

最基本的 SRQ 类型，所有共享 QP 按序消费 WQE。

```c
struct ibv_srq_init_attr attr = {
    .attr.max_wr  = 1000,
    .attr.max_sge = 1,
    .srq_type     = IBV_SRQT_BASIC,
};
```

### 4.2 SRQ Type: RD (Reliable Datagram)

RD 类型 SRQ 支持 Reliable Datagram QP，允许更灵活的接收处理。

```c
// RD SRQ 创建
struct ibv_srq_init_attr_ex attr_ex = {
    .attr.max_wr        = 1000,
    .attr.max_sge       = 1,
    .srq_type           = IBV_SRQT_RD,
    .pd                 = pd,
    .comp_mask          = IBV_SRQT_TYPE,
};
```

### 4.3 SRQ 扩展：Threshold 与限速

```c
// 设置 SRQ 的最小阈值（当 WQE 数量低于此值时产生异步事件）
struct ibv_srq_attr attr = {
    .srq_limit = 10,  // 当 SRQ 只有 10 个 WQE 时通知
};
ibv_modify_srq(srq, &attr, IBV_SRQ_LIMIT_MASK);

// 异步事件：SRQ_LIMIT_REACHED
// 应用收到事件后应尽快补充 WQE
```

---

## 5. SRQ 性能优化

### 5.1 SRQ Size 规划

SRQ 大小规划是性能关键：

```
规划原则：
- SRQ WQE 数 = 预期并发接收数 × 峰值系数
- 太小：丢包重传，延迟增加
- 太大：内存浪费

经验公式：
SRQ_size = max_outstanding_recvs × 1.5

示例：
- 1000 个 QP 共享 SRQ
- 每个 QP 预期 10 个并发接收
- SRQ_size = 1000 × 10 × 1.5 = 15000 WQE
```

### 5.2 SRQ WQE 动态调整

在高负载场景下动态增加 SRQ 容量：

```bash
# 查看 SRQ 统计
$ perfmon query SRQ

# 动态调整 SRQ 大小（需要厂商支持）
```

```c
// 监控 SRQ 填充率
struct ibv_srq_attr attr;
ibv_query_srq(srq, &attr);

// 如果 current_wr > 0.8 * max_wr，考虑扩展
if (attr.curr_wq_wr > 0.8 * attr.max_wr) {
    // 扩展 SRQ
    struct ibv_srq_attr new_attr = {
        .max_wr = attr.max_wr * 2,
    };
    ibv_modify_srq(srq, &new_attr, IBV_SRQ_MAX_WR_MASK);
}
```

### 5.3 SRQ 与 CQ 的配合

```
推荐配置：

  场景                SRQ Size    CQ 策略
  ─────────────────────────────────────────
  高并发短连接        大 SRQ      共享 CQ（降低中断）
  低延迟交易          小 SRQ      独立 CQ（快速响应）
  HPC MPI             中等 SRQ    多 CQ（按优先级）
```

### 5.4 SRQ + UD QP 的特殊考虑

UD QP 使用 SRQ 时需要注意：

```c
// UD QP + SRQ
struct ibv_qp_init_attr qp_attr = {
    .qp_type = IBV_QPT_UD,
    .srq     = srq,  // UD QP 也可以关联 SRQ
    // UD QP 需要额外配置：
    .cap.max_send_wr = 0,  // UD 不使用 send queue
    .cap.max_send_sge = 0,
};

// UD SRQ WQE 需要处理 GRH（全局路由头）
// 应用需要解析收到的UD包的元数据
```

---

## 6. SRQ 最佳实践

### 6.1 典型部署模式

```
Kubernetes RDMA 部署（SRQ 优化）：

  节点级 SRQ
  ├── Container A (QP1) ──┐
  ├── Container B (QP2) ──┼──→ 共享 SRQ（1000 WQE）
  └── Container C (QP3) ──┘

优势：
- Pod 启动快（QP 创建快，不需要预分配大 RQ）
- 节点内存可控（SRQ 统一管理）
- 调度灵活（Pod 迁移时 SRQ 动态调整）
```

### 6.2 代码示例：SRQ 服务器

```c
// SRQ 服务器初始化
int init_srq_server(struct rdma_context *ctx)
{
    // 1. 创建 Protection Domain
    ctx->pd = ibv_alloc_pd(ctx->ib_ctx);

    // 2. 创建 CQ
    ctx->cq = ibv_create_cq(ctx->ib_ctx, 100, NULL, NULL, 0);

    // 3. 创建 SRQ（关键优化）
    struct ibv_srq_init_attr srq_attr = {
        .attr.max_wr  = 8192,   // 共享接收队列大小
        .attr.max_sge = 1,
        .srq_type     = IBV_SRQT_BASIC,
    };
    ctx->srq = ibv_create_srq(ctx->pd, &srq_attr);

    // 4. 预先填充 SRQ WQE（最佳实践）
    for (int i = 0; i < 4096; i++) {
        post_srq_recv(ctx->srq, &ctx->recv_mr, i);
    }

    // 5. 创建 QP 并关联 SRQ
    struct ibv_qp_init_attr qp_attr = {
        .send_cq = ctx->cq,
        .recv_cq = ctx->cq,
        .srq     = ctx->srq,  // 关联 SRQ
        .cap     = {...},
        .qp_type = IBV_QPT_RC,
    };
    ctx->qp = ibv_create_qp(ctx->pd, &qp_attr);

    return 0;
}

// SRQ 接收处理（所有 QP 共享）
void handle_completion(struct ibv_wc *wc)
{
    if (wc->opcode == IBV_WC_RECV) {
        // 根据 wr_id 识别是哪个 QP 的请求
        uint64_t conn_id = wc->wr_id;
        process_received_data(wc->sg_list, wc->byte_len);
    }
}
```

### 6.3 常见错误与避免

```
错误 1: SRQ WQE 耗尽
  症状：ibv_post_srq_recv 返回 ENOMEM
  解决：确保 SRQ 足够大，或持续补充 WQE

错误 2: SRQ 与 QP 不匹配类型
  症状：QP 创建失败
  解决：RD SRQ 只能关联 RD QP，Basic SRQ 关联 RC/UC/UD QP

错误 3: 忘记 Post SRQ Recv
  症状：接收超时，无数据到达
  解决：SRQ 初始必须预填充 WQE
```

---

## 7. SRQ 监控与调试

### 7.1 SRQ 统计

```bash
# 使用 perfmon 查看 SRQ 统计
$ perfmon query SRQ

# 示例输出
SRQ0:
  cur_wq_wr: 5000      # 当前 WQE 数
  max_wq_wr: 8192      # 最大 WQE 数
  wq_srq_limit: 100    # 阈值

# 使用 ibv_devinfo 查看 SRQ 详情
$ ibv_devinfo -s mlx5_0
```

### 7.2 SRQ 问题诊断

```bash
# SRQ 耗尽诊断
$ perfmon query SRQ | grep -E "cur_wq_wr|max_wq_wr"

# 查看 SRQ 相关错误
$ ibdiagnet --device mlx5_0 --report level=verbose | grep -i srq

# 验证 SRQ 配置
$ ibv_srq_dump <srq_handle>
```

---

## 8. 小结

- **SRQ 核心价值**：多个 QP 共享接收队列，大幅降低内存开销，提升扩展性
- **SRQ 类型**：Basic（RC/UC/UD）和 RD（可靠数据报）两种
- **API 关键点**：`ibv_create_srq()`、`ibv_post_srq_recv()`、`ibv_query_srq()`
- **最佳实践**：SRQ 大小规划、预填充 WQE、阈值监控、动态调整
- **典型场景**：K8s RDMA、HPC MPI、大规模数据库连接

---

> [!tip] 延伸阅读
>
> - [[ch7-queue-pair|第七章：队列对 (QP)]] —— QP 机制的完整说明
> - [[ch9-verbs-api|第九章：Verbs API]] —— libibverbs API 详解
> - [[ch24-rdma-cni|第二十四章：RDMA CNI]] —— K8s 中的 SRQ 应用
