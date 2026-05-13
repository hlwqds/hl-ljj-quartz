---
title: "RDMA 深度探索 (十一)：RDMA 原子操作"
date: 2026-04-13
tags: [rdma, series, atomics, compare-and-swap, fetch-and-add, one-sided, synchronization]
description: "深入理解 RDMA 原子操作——Compare & Swap (CAS)、Fetch & Add (FA)、原子语义、内存顺序、以及在分布式算法中的应用"
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
> 8. [[2026-04-13-rdma-deep-dive-ch8-mr-pd|第八章：内存区域与保护域]]
> 9. [[2026-04-13-rdma-deep-dive-ch9-verbs-api|第九章：Verbs API]]
> 10. [[2026-04-13-rdma-deep-dive-ch10-ud-rc|第十章：UD vs RC]]
> 11. **第十一章：RDMA 原子操作**

---

## 1. 为什么需要 RDMA 原子操作？

传统分布式计数器实现需要：

```
传统方式（需要远端 CPU 参与）：
  Node A                              Node B
    │                                    │
    │  1. READ counter (RDMA Read)       │
    │──────────────────────────►│        │
    │  返回: count = 100                │
    │◄──────────────────────────│        │
    │                                    │
    │  2. increment                    │
    │  count = count + 1               │
    │                                    │
    │  3. WRITE counter (RDMA Write)    │
    │──────────────────────────►│        │
    │                                count = 101
    │
    问题：竞态条件！
    如果 Node C 同时执行相同操作：
    - Node A 读到 100
    - Node C 读到 100
    - Node A 写回 101
    - Node C 写回 101  ← 丢失一次更新！

原子操作（远端 CPU 无需参与）：
  Node A                              Node B
    │                                    │
    │  FETCH_AND_ADD(counter, 1)         │
    │  ─────────────────────────►│      │
    │  返回旧值: 100  硬件原子地执行     │
    │◄────────────────────────────────│
    │  counter 已变为 101 (硬件保证)   │
    │
    即使 Node C 同时执行，最终结果也是 102
```

### 1.1 原子操作的核心价值

| 特性 | 说明 |
|------|------|
| **远端无感知** | 远端 CPU 完全不知道有人改了它的内存 |
| **硬件保证原子性** | 不会出现读-改-写竞态条件 |
| **一致性** | 保证线性化顺序，无锁实现分布式数据结构 |
| **低延迟** | 单次网络往返完成原子修改 |

---

## 2. 两种原子操作类型

### 2.1 Fetch & Add (FA)

```c
// 操作语义：atomic(*addr += val);
// 返回修改前的旧值

// Verbs API
struct ibv_send_wr atomic_wr = {
    .opcode      = IBV_WR_ATOMIC_FETCH_AND_ADD,
    .wr_id       = 123,
    .remote_addr = remote_counter_addr,
    .rkey        = remote_counter_rkey,
    .fetch_add   = 1,    // 加 1
};
```

**执行流程：**

```
Node A                                  Node B (counter 物理地址)
  │                                        │
  │  FETCH_AND_ADD(addr, 1)               │
  │──────────────────────────────────────►│
  │                                        │
  │  硬件原子操作:                         │
  │  old = *addr;    // 读取               │
  │  *addr = old+1;  // 修改               │
  │                                        │
  │  返回 old (旧值)                      │
  │◄──────────────────────────────────────│
  │  收到: old = 100                      │
  │  远端 counter = 101 (由硬件修改)       │
  │                                        │
```

**应用：分布式计数器、令牌桶、流量控制**

### 2.2 Compare & Swap (CAS)

```c
// 操作语义：atomic(if (*addr == compare) *addr = swap; return old;)
// 如果当前值等于 compare，则替换为 swap；否则不变
// 返回修改前的旧值

struct ibv_send_wr atomic_wr = {
    .opcode      = IBV_WR_ATOMIC_CMP_AND_SWP,
    .wr_id       = 456,
    .remote_addr = remote_addr,
    .rkey        = remote_rkey,
    .compare_add = expected_old_value,   // 期望值
    .swap        = new_value,             // 新值
};
```

**执行流程：**

```
Node A                                  Node B (内存地址)
  │                                        │
  │  CMP_AND_SWP(addr, expect=100, new=200)│
  │──────────────────────────────────────►│
  │                                        │
  │  硬件原子操作:                         │
  │  old = *addr;                         │
  │  if (old == expect) *addr = swap;    │
  │                                        │
  │  返回 old                             │
  │◄──────────────────────────────────────│
  │  收到: old = 100 (匹配，修改成功)      │
  │  或:   old = 101 (不匹配，修改失败)    │
```

**应用：实现互斥锁、无锁数据结构、标志位操作**

---

## 3. 原子操作 API

### 3.1 Verbs API 使用

```c
// 内存必须有 IBV_ACCESS_REMOTE_ATOMIC 权限
struct ibv_mr *mr = ibv_reg_mr(pd, buf, size,
    IBV_ACCESS_LOCAL_WRITE |
    IBV_ACCESS_REMOTE_READ |
    IBV_ACCESS_REMOTE_WRITE |
    IBV_ACCESS_REMOTE_ATOMIC);

// FETCH_AND_ADD
struct ibv_send_wr wr = {
    .wr_id       = 1,
    .opcode      = IBV_WR_ATOMIC_FETCH_AND_ADD,
    .sg_list     = &local_sge,    // 本地：存储返回值
    .num_sge     = 1,
    .remote_addr = remote_addr,
    .rkey        = remote_rkey,
    .fetch_add   = 1,
    .send_flags  = IBV_SEND_SIGNALED,
};

// CMP_AND_SWP
struct ibv_send_wr wr = {
    .wr_id       = 2,
    .opcode      = IBV_WR_ATOMIC_CMP_AND_SWP,
    .sg_list     = &local_sge,
    .num_sge     = 1,
    .remote_addr = remote_addr,
    .rkey        = remote_rkey,
    .compare_add = expected_value,  // 比较值
    .swap        = new_value,        // 交换值
    .send_flags  = IBV_SEND_SIGNALED,
};

struct ibv_send_wr *bad_wr;
ibv_post_send(qp, &wr, &bad_wr);
```

### 3.2 32-bit vs 64-bit

```
原子操作数据大小取决于硬件：

64-bit HCA（如 ConnectX-6/7）:
  - FETCH_AND_ADD: 64-bit (8字节)
  - CMP_AND_SWP: 64-bit

32-bit HCA（旧型号）:
  - FETCH_AND_ADD: 32-bit 或 64-bit（分两次操作）
  - CMP_AND_SWP: 32-bit

注意：64-bit 原子需要内存地址 8 字节对齐
```

### 3.3 接收原子操作结果

```c
// local_sge 指向的内存存储返回值
// 即原子操作的"旧值"

char result_buf[8];
struct ibv_sge sge = {
    .addr   = (uint64_t)result_buf,
    .length = 8,       // 64-bit 原子 → 8 字节
    .lkey   = mr->lkey,
};

struct ibv_send_wr wr = {
    .opcode      = IBV_WR_ATOMIC_FETCH_AND_ADD,
    .sg_list     = &sge,
    .num_sge     = 1,
    .fetch_add   = 1,
    ...
};

// Completion 后
struct ibv_wc wc;
ibv_poll_cq(cq, 1, &wc);
// result_buf 中就是原子操作的旧值
uint64_t old_value = *(uint64_t *)result_buf;
```

---

## 4. 用 CAS 实现分布式锁

### 4.1 互斥锁（Spinlock）

```
无锁互斥锁实现（基于 CAS）：

    0 = 未锁定
    1 = 锁定

Node A 获取锁:
  ┌─────────────────────────────────────────────────────┐
  │  while (CMP_AND_SWP(lock_addr, 0, 1) != 0) {       │
  │      // 锁已被持有，自旋等待                       │
  │      usleep(1);                                   │
  │  }                                                │
  │  // 获得锁，临界区操作                            │
  │  ...                                              │
  │  RDMA_WRITE(lock_addr, 0); // 释放锁              │
  └─────────────────────────────────────────────────────┘

特点：
- 无锁（lock-free）：不会阻塞线程
- 公平性：不保证（可能饥饿）
- 远端无感知：被锁定节点不知道谁在等锁
```

### 4.2 完整代码示例

```c
// 远端内存布局（Node B）
struct remote_data {
    uint64_t lock;      // 0=unlocked, 1=locked
    uint64_t counter;   // 共享计数器
    uint64_t queue[16]; // 无锁队列
};

// 获取锁（自旋等待）
int acquire_lock(struct ibv_qp *qp, struct ibv_mr *mr,
                 uint64_t lock_addr, uint32_t rkey) {
    uint64_t zero = 0;
    char result[8];

    while (1) {
        struct ibv_sge sge = {
            .addr   = (uint64_t)result,
            .length = 8,
            .lkey   = mr->lkey,
        };
        struct ibv_send_wr wr = {
            .opcode      = IBV_WR_ATOMIC_CMP_AND_SWP,
            .wr_id       = 0,
            .sg_list     = &sge,
            .num_sge     = 1,
            .remote_addr = lock_addr,
            .rkey        = rkey,
            .compare_add = 0,    // 期望：未锁定
            .swap        = 1,     // 设置为：锁定
            .send_flags  = IBV_SEND_SIGNALED,
        };
        struct ibv_send_wr *bad_wr;
        ibv_post_send(qp, &wr, &bad_wr);

        // 等待 CQE
        struct ibv_wc wc;
        ibv_poll_cq(cq, 1, &wc);

        uint64_t old = *(uint64_t *)result;
        if (old == 0) {
            return 0;  // 获得锁
        }
        // 自旋等待（可加退避）
    }
}

// 释放锁
void release_lock(struct ibv_qp *qp, uint64_t lock_addr, uint32_t rkey) {
    struct ibv_send_wr wr = {
        .opcode      = IBV_WR_RDMA_WRITE,
        .wr_id       = 0,
        .remote_addr = lock_addr,
        .rkey        = rkey,
        // 写入 0 即释放锁
        .send_flags  = IBV_SEND_SIGNALED,
    };
    struct ibv_send_wr *bad_wr;
    ibv_post_send(qp, &wr, &bad_wr);
}
```

---

## 5. 无锁数据结构

### 5.1 原子计数器

```c
// 分布式计数器（多个节点并发 +1）
// 每次 FETCH_AND_ADD 返回旧值

Node A: FETCH_AND_ADD(counter, 1) → 返回 99
Node B: FETCH_AND_ADD(counter, 1) → 返回 100
Node C: FETCH_AND_ADD(counter, 1) → 返回 101
// 最终 counter = 102，无丢失更新
```

### 5.2 无锁队列（入队）

```
基于 CAS 的无锁入队（Michael-Scott 队列）：

  HEAD                       TAIL
   │                           │
   ▼                           ▼
 ┌───┐   ┌───┐   ┌───┐   ┌───┐
 │ A │──►│ B │──►│ C │──►│ ? │  ← 新节点
 └───┘   └───┘   └───┘
                      TAIL
                       │
                       ▼
                 原子 CMP_AND_SWP:
                 if (tail.next == NULL)
                     tail.next = new_node
                 tail = tail.next
```

### 5.3 参考实现：分布式信号量

```c
// 远端信号量
struct semaphore {
    uint64_t count;   // 可用资源数
};

// P() 操作（获取资源）
uint64_t wait_semaphore(struct ibv_qp *qp, uint64_t sem_addr) {
    while (1) {
        uint64_t old;
        char result[8];

        // 读取当前值
        read_remote(qp, sem_addr, &old);

        if (old > 0) {
            // 尝试原子减 1
            struct ibv_sge sge = { .addr = (uint64_t)result, ... };
            struct ibv_send_wr wr = {
                .opcode = IBV_WR_ATOMIC_CMP_AND_SWP,
                .compare_add = old,
                .swap = old - 1,
                ...
            };
            ibv_post_send(qp, &wr, &bad_wr);
            ibv_poll_cq(cq, 1, &wc);

            if (*(uint64_t *)result == old) {
                return old;  // 成功获取
            }
        }
        // 否则重试
    }
}

// V() 操作（释放资源）
void signal_semaphore(uint64_t sem_addr) {
    // FETCH_AND_ADD(sem, 1)
    struct ibv_send_wr wr = {
        .opcode = IBV_WR_ATOMIC_FETCH_AND_ADD,
        .fetch_add = 1,
        ...
    };
}
```

---

## 6. 内存顺序与一致性

### 6.1 RC QP 的 Ordering 保证

```
RC QP 保证按发送顺序到达到接收方：

  发送顺序: WR1 → WR2 → WR3
  接收顺序: WR1 → WR2 → WR3  (保证有序)

但原子操作不遵循这个顺序！原子操作独立处理。
```

### 6.2 FENCE 操作

```c
// 强制之前的所有 WR 在此原子操作之前完成
struct ibv_send_wr wr = {
    .opcode      = IBV_WR_ATOMIC_FETCH_AND_ADD,
    ...
    .send_flags  = IBV_SEND_FENCE,  // 强制排序
};
```

### 6.3 原子操作的顺序规则

| 操作类型 | Ordering 保证 |
|---------|--------------|
| Send/Recv | 同一 QP 内按顺序 |
| RDMA Read | 不保证顺序（独立操作） |
| RDMA Write | 不保证顺序（独立操作） |
| Atomic | 不保证顺序（独立操作） |

**注意**：同一 QP 内的多个原子操作**不保证**按提交顺序完成。需要在应用层通过 CAS 变体实现顺序保证。

---

## 7. 原子操作与网络延迟

### 7.1 延迟分析

```
单次原子操作延迟（ConnectX-7, RoCEv2）:

  FETCH_AND_ADD: ~2-3μs (单向)
  CMP_AND_SWP:   ~2-3μs (单向)

对比：
  RDMA Read:     ~1.5μs
  RDMA Write:    ~1.5μs
  原子操作略高（需要 RTT + 硬件原子语义处理）
```

### 7.2 批量原子操作

```c
// 链式提交多个原子操作
struct ibv_send_wr wr1 = {
    .wr_id  = 1,
    .opcode = IBV_WR_ATOMIC_FETCH_AND_ADD,
    .next   = &wr2,
    ...
};
struct ibv_send_wr wr2 = {
    .wr_id  = 2,
    .opcode = IBV_WR_ATOMIC_FETCH_AND_ADD,
    .next   = NULL,
    ...
};
ibv_post_send(qp, &wr1, &bad_wr);
```

---

## 8. Extended Atomics (可选特性)

### 8.1 什么是 Extended Atomics？

一些高端 HCA（如 ConnectX-7）支持扩展原子操作：

| 基础原子 | 扩展原子 |
|---------|---------|
| Fetch & Add (64-bit) | Fetch & Add (64-bit) |
| CMP_AND_SWP (64-bit) | CMP_AND_SWP (64-bit) |
| - | STORE (单向存储) |
| - | LOAD (单向加载) |
| - | MASKED_CMP_AND_SWP (32-bit 掩码) |

### 8.2 验证支持

```c
struct ibv_device_attr_ex attr;
ibv_query_device_ex(ctx, NULL, &attr);

if (attr.orig_attr.device_cap_flags & IBV_DEVICE_EXT_ATOMICS) {
    printf("支持 Extended Atomics\n");
} else {
    printf("仅支持基础原子操作\n");
}
```

---

## 9. 常见问题

**Q: 原子操作失败（返回值不匹配）怎么办？**
A: 这是正常的（CAS 的预期行为）。应用应该根据返回值决定重试（自旋/退避）。典型模式：
```c
do {
    old = result;
    new = compute(old);
} while (CMP_AND_SWP(addr, old, new) != old);
```

**Q: 原子操作能保证公平性吗？**
A: 不能。多个节点同时 CAS 同一个地址，只有一个会成功，其他需要重试。这是无锁算法的特性，不保证 FIFO 顺序。

**Q: 原子操作支持的数据类型？**
A: 主流 HCA 支持 64-bit 原子（8字节）。部分支持 32-bit（通过 Extended Atomics）。不支持更大结构（需要应用层拆分）。

**Q: 原子操作的 rkey 需要什么权限？**
A: 需要 `IBV_ACCESS_REMOTE_ATOMIC` 权限。这是在注册 MR 时指定的：
```c
ibv_reg_mr(pd, buf, size, IBV_ACCESS_REMOTE_ATOMIC | ...);
```

**Q: 原子操作会被网络丢包影响吗？**
A: RC QP 的原子操作是可靠的。HCA 负责重传，直到收到确认。丢包会导致额外延迟，但最终语义保证。
