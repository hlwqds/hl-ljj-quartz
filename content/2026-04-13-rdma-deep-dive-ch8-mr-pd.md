---
title: "RDMA 深度探索 (八)：内存区域与保护域 (MR/MW/PD)"
date: 2026-04-13
tags: [rdma, series, memory-region, protection-domain, lkey, rkey, memory-window]
description: "深入理解 RDMA 内存注册机制、虚拟地址与物理地址映射、lkey/rkey 权限控制、Memory Window 与远程访问控制"
---

> [!info] RDMA 深度探索系列
> 0. [[2026-04-13-rdma-deep-dive-series-index|全栈学习路径总览]]
> 1. [[2026-04-13-rdma-deep-dive-ch1-rdma-overview|第一章：RDMA 概述]]
> 2. [[2026-04-13-rdma-deep-dive-ch2-rdma-architecture|第二章：RDMA 架构]]
> 3. [[2026-04-13-rdma-deep-dive-ch3-infiniband|第三章：InfiniBand 架构]]
> 4. [[2026-04-13-rdma-deep-dive-ch4-roce|第四章：RoCE v1/v2]]
> 5. [[2026-04-13-rdma-deep-dive-ch5-iwarp|第五章：iWARP]]
> 6. [[2026-04-13-rdma-deep-dive-ch6-roce-vs-iwarp|第六章：RoCE vs iWARP 对比]]
> 7. [[2026-04-13-rdma-deep-dive-ch7-queue-pair|第七章：队列对 (QP)]]
> 8. **第八章：内存区域与保护域**

---

## 1. 为什么需要内存注册？

RDMA 操作需要将本地虚拟地址转换为物理地址，供 HCA 执行 DMA。这要求内存预先"注册"（Registered）：

```
应用程序虚拟地址空间                    HCA DMA 引擎
┌────────────────────┐                  ┌─────────────────────┐
│                    │                  │                     │
│  buf (VA) ─────────┼──► 页表解析      │  PA (物理地址)      │
│                    │                  │  ─────────────────  │
│  unregistered      │  ──► ERROR!      │  DMA 直接访问      │
│                    │                  │                     │
│  buf (VA) ─────────┼──► 固定页        │  PA (锁定)          │
│  (已注册 MR)       │  ──► 转换完成    │  可 DMA 访问        │
│                    │                  │                     │
└────────────────────┘                  └─────────────────────┘

关键约束：
- 未注册的内存 HCA 无法 DMA 访问
- 注册后的内存页被锁定（不可换页）
- 硬件记录 VA→PA 映射（Translation Cache Entry）
```

### 1.1 内存注册解决的问题

| 问题 | 解决方案 |
|------|---------|
| 虚拟地址 → 物理地址 | 页表遍历，HCA 直接使用物理地址 |
| 内存被换页 (page out) | 锁页，确保物理页常驻内存 |
| 内存被其他进程访问 | PD 隔离，不同 PD 之间无法交叉访问 |
| 远程访问权限控制 | lkey/rkey 验证，本地/远程权限分离 |

---

## 2. Memory Region (MR)

### 2.1 基本概念

Memory Region (MR) 是一段连续注册过的内存区域：

```c
struct ibv_mr {
    struct ibv_context *context;   // HCA 上下文
    struct ibv_pd      *pd;        // 所属 Protection Domain
    void               *addr;      // 起始虚拟地址
    size_t              length;    // 长度
    uint32_t            lkey;     // 本地访问密钥
    uint32_t            rkey;     // 远程访问密钥
    uint32_t            handle;   // HCA 内部句柄
};
```

### 2.2 创建 MR

```c
// 方法 1: ibv_reg_mr（标准接口）
struct ibv_mr *mr = ibv_reg_mr(pd, buf, size,
    IBV_ACCESS_LOCAL_WRITE |    // 本地写权限
    IBV_ACCESS_REMOTE_READ |   // 远程读权限
    IBV_ACCESS_REMOTE_WRITE);   // 远程写权限

// 方法 2: ibv_reg_mr_iova2（指定 IO virtual address）
struct ibv_mr *mr = ibv_reg_mr_iova2(pd, buf, size,
    IBV_ACCESS_LOCAL_WRITE,
    0 /* iova = 0 表示使用 VA */);
```

### 2.3 访问权限

| 权限标志 | 说明 | 使用场景 |
|---------|------|---------|
| `IBV_ACCESS_LOCAL_WRITE` | 本地可写 | Send/Recv 需要本地写入 |
| `IBV_ACCESS_REMOTE_WRITE` | 远程可写 (rkey) | RDMA Write |
| `IBV_ACCESS_REMOTE_READ` | 远程可读 (rkey) | RDMA Read |
| `IBV_ACCESS_MR_BIND` | 可绑定 Memory Window | MW 动态权限控制 |

### 2.4 lkey 与 rkey

```
lkey (Local Key)
├── 用于：本地 CPU 访问 MR（SG list 中的 lkey 字段）
├── 验证：HCA 硬件在 DMA 读取本地内存时检查
└── 示例：ibv_sge { .addr=buf, .lkey=mr->lkey }

rkey (Remote Key)
├── 用于：远程节点 RDMA Read/Write/Atomic 操作
├── 传递：通过 RDMA CM 连接建立时交换
└── 示例：remote_addr + rkey 告诉对方"你可以访问这段内存"
```

```
交互示例：Node A (本地) → Node B (远程)

Node A:
  local_addr  = 0x7f0001000000
  local_rkey   = 0x12345678

  ibv_post_send(qp, {
      .opcode  = IBV_WR_RDMA_READ,
      .remote_addr = Node_B_addr,   // 对方给的地址
      .rkey    = Node_B_rkey,       // 对方给的 rkey
  })

Node B:
  MR 已注册，rkey = 0x87654321
  rkey 通过连接建立时交换给 Node A
```

---

## 3. Memory Window (MW)

### 3.1 为什么需要 MW？

MR 的 rkey 在整个连接生命周期内固定。Memory Window 允许动态绑定/解绑，提供更灵活的控制：

```
┌─────────────────────────────────────────────────────┐
│                  Memory Window 机制                  │
│                                                      │
│  ┌───────────────────────────────────────────────┐  │
│  │            Memory Region (MR)                 │  │
│  │  addr: 0x7f0001000000  length: 1GB           │  │
│  │                                               │  │
│  │  ┌─────────────────┐  ┌─────────────────┐    │  │
│  │  │ MW 1 绑定 [0-256MB]│  │ MW 2 绑定 [512MB-768MB]│ │
│  │  │ rkey: 0xA1      │  │ rkey: 0xA2      │    │  │
│  │  │ 权限: READ      │  │ 权限: READ+WRITE│    │  │
│  │  └─────────────────┘  └─────────────────┘    │  │
│  └───────────────────────────────────────────────┘  │
│                                                      │
│  MW 可以动态绑定到 MR 的不同区间                      │
│  MW 可以动态调整权限                                  │
│  MW 可以随时解绑                                      │
└─────────────────────────────────────────────────────┘
```

### 3.2 MW 操作

```c
// 分配 MW
struct ibv_mw *mw = ibv_alloc_mw(pd, IBV_MW_TYPE_1);
// 注意：MW 不关联具体内存，只是预分配一个 rkey

// 绑定 MW 到 MR 的特定区间
struct ibv_mw_bind bind_attr = {
    .mr         = mr,                    // 目标 MR
    .addr       = 0x1000,               // 绑定起始地址
    .length     = 4096,                 // 绑定长度
    .bind_flags = IBV_MW_BIND_ACCESS | // 可访问
                  IBV_MW_BIND_REMOTE_WRITE,
};
ibv_bind_mw(qp, mw, &bind_attr);
// 绑定后，mw->rkey 可用于远程访问 [mr->addr+0x1000, 4KB]
```

### 3.3 MR vs MW

| 特性 | Memory Region | Memory Window |
|------|--------------|---------------|
| 粒度 | 整个 region | 可部分绑定 |
| rkey 生命周期 | 创建后固定 | 可动态分配 |
| 权限 | 创建时确定 | 绑定时可调整 |
| 用途 | 固定、长期的内存区域 | 动态、短期的访问授权 |

---

## 4. Protection Domain (PD)

### 4.1 PD 的作用

Protection Domain (PD) 提供资源隔离边界：

```
┌─────────────────────────────────────────────────────────────┐
│                Protection Domain 隔离                        │
│                                                              │
│  PD-A                          PD-B                         │
│  ┌────────────────┐            ┌────────────────┐           │
│  │ QP 1           │            │ QP 3           │           │
│  │ MR 1 (lkey=x) │            │ MR 3 (lkey=y)  │           │
│  │                │            │                │           │
│  │ QP 2           │            │                │           │
│  │ MR 2 (lkey=z)  │            │                │           │
│  └────────────────┘            └────────────────┘           │
│         │                              │                    │
│  PD-A 内的 QP 只能访问 PD-A 内的 MR    │                    │
│  PD-B 内的 QP 只能访问 PD-B 内的 MR    │                    │
│  跨 PD 访问 → ACCESS ERR (硬件级别拒绝)                     │
└─────────────────────────────────────────────────────────────┘
```

### 4.2 创建与使用

```c
// 创建 PD
struct ibv_pd *pd = ibv_alloc_pd(ctx);

// 同一 PD 内的资源可互操作
struct ibv_mr *mr = ibv_reg_mr(pd, buf, size, access_flags);
struct ibv_qp *qp = ibv_create_qp(pd, &qp_init_attr);
```

---

## 5. 地址转换与 DMA

### 5.1 虚拟地址 → 物理地址流程

```
应用程序                     HCA                         NIC/交换机
   │                          │                              │
   │  ibv_reg_mr(buf)         │                              │
   │─────────────────────────►│                              │
   │                          │  页表遍历/锁页                │
   │                          │──────────────────────────────►│
   │                          │  建立 VA→PA 映射              │
   │                          │◄──────────────────────────────│
   │                          │  返回 lkey/rkey               │
   │◄──────────────────────────│                              │
   │  lkey=0x123, rkey=0x456  │                              │
   │                          │                              │
   │  ibv_post_send(RDMA_WRITE│                              │
   │    remote_addr, rkey)    │                              │
   │─────────────────────────►│                              │
   │                          │  DMA: 使用 PA (硬件查表)      │
   │                          │──────────────────────────────►│
   │                          │  写入远端物理内存              │
```

### 5.2 一个具体例子

```
场景：Node A (IP 192.168.1.10) 想 RDMA Write Node B 的 buf

Node B 端：
  buf = malloc(4096);
  mr = ibv_reg_mr(pd, buf, 4096, IBV_ACCESS_REMOTE_WRITE);
  // mr->rkey = 0xabcd1234
  // 通过 RDMA CM 连接建立交换 rkey=0xabcd1234 给 Node A

Node A 端：
  remote_addr = 0x7f0001000000  // Node B 告知的虚拟地址
  rkey        = 0xabcd1234      // Node B 注册时分配的 rkey

  ibv_post_send(qp, {
    .opcode       = IBV_WR_RDMA_WRITE,
    .remote_addr  = 0x7f0001000000,
    .rkey         = 0xabcd1234,
    .wr_id        = 123,
  });
  // HCA 使用 rkey 验证访问权限
  // HCA 通过内部 VA→PA 表找到物理地址，执行 DMA
```

---

## 6. 注册标志与优化

### 6.1 常见注册标志

```c
// 零拷贝优化
IBV_ACCESS_ZERO_BASED   // 从地址 0 开始计算偏移（某些 HCA 更高效）

// 远程访问
IBV_ACCESS_REMOTE_ATOMIC // 远程原子操作权限

// DMA 引擎
IBV_ACCESS_HUGETLB      // 大页内存（减少 TLB miss）
```

### 6.2 大页 (Hugepage) + RDMA

```
使用大页注册 MR 的优势：

普通 4KB 页：
  1GB 内存 → 262144 个页表项
  TLB 压力巨大

Hugepage 2MB：
  1GB 内存 → 512 个页表项
  TLB miss 大幅减少

注册方式：
  hugetlb_buf = mmap(NULL, size, PROT_READ|PROT_WRITE,
                     MAP_ANONYMOUS|MAP_HUGETLB, -1, 0);
  mr = ibv_reg_mr(pd, hugetlb_buf, size, access);
```

---

## 7. 常见问题

**Q: 注册的内存可以 free 吗？**
A: 不行。必须先 `ibv_dereg_mr(mr)` 解除注册，才能释放内存。HCA 内部的 VA→PA 映射必须先清理。

**Q: lkey/rkey 冲突怎么办？**
A: 几乎不可能冲突。lkey/rkey 是 HCA 分配的 32-bit 值，每次注册生成不同值。验证发生在 DMA 之前，冲突会导致错误。

**Q: 可以注册重叠的内存区域吗？**
A: 可以。同一个虚拟地址范围可以多次注册为不同 MR（只要在相同或不同 PD 中）。但会导致 rkey 歧义——应避免。

**Q: MW 类型 Type 1 和 Type 2 的区别？**
A: Type 1 是传统 MW，需绑定到整个 MR。Type 2 允许更细粒度的部分绑定（RoCEv2 支持）。大多数现代 HCA 支持 Type 2。

**Q: 一个 MR 可以被多少个 MW 绑定？**
A: 取决于 HCA，通常没有硬性限制，但 MW 数量会影响 HCA TLB 压力。
