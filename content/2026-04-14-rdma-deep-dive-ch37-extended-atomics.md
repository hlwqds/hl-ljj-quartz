---
title: "RDMA 第三十七章：扩展原子操作——64位原子、FAA、CAS与内存序"
date: 2026-04-14
tags: [rdma, extended-atomics, 64-bit, fetch-and-add, compare-and-swap, memory-ordering, one-sided, roce, infiniband]
description: "详解 RDMA 扩展原子操作：64位 Fetch-Add、Compare-and-Swap、原子掩码操作、内存序语义、以及在分布式数据结构中的应用。"
---

> [!abstract] 核心要点
> RDMA 扩展原子操作是 InfiniBand Verbs 的高级特性，支持 64 位原子操作和更复杂的原子语义，比基础原子操作（Fetch-Add、CAS）提供更强大的单边编程能力。本章详解扩展原子的类型、语义、API 使用、以及在高性能分布式算法中的应用。

---

## 1. 扩展原子操作概述

### 1.1 为什么需要扩展原子？

标准 RDMA 原子操作（第三章介绍）仅支持 32 位 Fetch-Add 和 Compare-and-Swap：

```
标准原子操作限制：
- Fetch-Add:   32 位整数
- Compare-and-Swap: 32 位整数

实际需求：
- 64 位计数器（长时间运行的统计）
- 128 位 CAS（双宽比较）
- 原子掩码操作（位操作）
- 更复杂的原子语义
```

### 1.2 扩展原子操作类型

```
RDMA 扩展原子操作类型：

  ① 64 位原子
  │    ├── Fetch-Add (64-bit)
  │    └── Compare-and-Swap (64-bit)
  │
  ② 双宽原子（128位）
  │    └── Compare-and-Swap (128-bit)
  │
  ③ 掩码原子
  │    ├── Fetch-And-Add-Masked
  │    └── Compare-And-Swap-Masked
  │
  ④ 原子操作组合
       └── 多种原子类型的组合支持
```

### 1.3 扩展原子与标准原子的区别

| 特性 | 标准原子 | 扩展原子 |
|------|---------|---------|
| 数据宽度 | 32 位 | 64 位/128 位 |
| 操作类型 | FA, CAS | FA, CAS, Masked FA, Masked CAS |
| 内存一致性 | 单核单序 | 多核多序 |
| 硬件要求 | 基本 RDMA | 需要扩展原子支持 |
| 性能开销 | 略高 | 略高 |

---

## 2. 64 位原子操作

### 2.1 64 位 Fetch-And-Add

64 位 Fetch-And-Add 在标准 32 位基础上扩展，支持更大的计数器和累加器：

```
64 位 FA 操作语义：

  Remote Memory Location:  0x12345678_9ABCDEF0

  执行:  RDMA_EXT_FA(remote_addr, 100)

  Before: 0x12345678_9ABCDEF0
  After:  0x12345678_9ABCDEF0 + 100 = 0x12345678_9ABE0094

  返回值: 原始值 0x12345678_9ABCDEF0
```

### 2.2 64 位 Compare-And-Swap

64 位 CAS 支持更大的原子比较单位：

```
64 位 CAS 操作语义：

  Remote Memory Location:  0x12345678_9ABCDEF0

  执行:  RDMA_EXT_CAS(remote_addr, compare=0x12345678_9ABCDEF0, swap=0xFFFFFFFF_00000000)

  Case 1: compare 匹配
    Before: 0x12345678_9ABCDEF0
    After:  0xFFFFFFFF_00000000
    返回:  0x12345678_9ABCDEF0 (原始值，表示成功)

  Case 2: compare 不匹配
    Before: 0x12345678_9ABCDEF0
    After:  保持不变
    返回:  0x12345678_9ABCDEF0 (当前值，表示失败)
```

### 2.3 64 位原子的应用场景

- **大规模计数器**：超过 32 位上限的统计（如网络流量、字节计数）
- **时间戳管理**：64 位纳秒时间戳的原子更新
- **分布式锁**：更宽的锁状态存储
- **指针操作**：在 64 位系统中原子操作指针

---

## 3. 双宽原子（128 位 CAS）

### 3.1 128 位 CAS 动机

64 位系统上，128 位 CAS 是实现无锁数据结构的关键：

```
128 位 CAS 应用：双宽比较和交换

  Location: [127:64] [63:0]
            0xAAAA   0xBBBBBBBB

  操作: CAS(location, [0xAAAA, 0xBBBBBBBB], [0xCCCC, 0xDDDDDDDD])

  成功条件：整个 128 位值匹配
  失败条件：任何 64 位部分不匹配
```

### 3.2 128 位 CAS 语义

```
128 位 CAS 操作流程：

  1. 读取远程 128 位值
  2. 比较 compare[127:0] 与远程值
  3. 如果匹配，写入 swap[127:0]
  4. 返回原始值

  用途：
  - 实现 MPMC（多生产者多消费者）队列
  - 实现无锁哈希表
  - 实现无锁链表
  - 实现复杂的同步原语
```

### 3.3 128 位原子的硬件实现

```
128 位原子实现注意：

  InfiniBand:
  - 硬件直接支持 128 位 CAS
  - 需要 IB 设备支持 extended atomics
  - 性能与 64 位原子相近

  RoCE:
  - 部分 NIC 不支持 128 位原子
  - 需要查设备规格确认
  - 可能回退到软件模拟
```

---

## 4. 掩码原子操作

### 4.1 掩码 Fetch-And-Add

掩码 FA 只在指定位上执行加法：

```
掩码 FA 语义：

  Remote Value:  0xFFFF_FFFF_0000_0000
  Mask:          0x0000_FFFF_0000_0000
  Addend:        100

  操作：将 addend 加到 masked 位置

  结果：
  Before: 0xFFFF_FFFF_0000_0000
  After:  0xFFFF_FFFF_0064_0000 (0x64 = 100)

  应用：原子更新结构体中的特定字段
```

### 4.2 掩码 CAS

掩码 CAS 只比较和交换指定位：

```
掩码 CAS 语义：

  Remote Value:  0x1234_5678_9ABC_DEF0
  Mask:          0x0000_FFFF_0000_0000
  Compare:       0x0000_0000_9ABC_0000
  Swap:          0x0000_0000_1234_0000

  操作：only masked bits 参与比较和交换

  Before: 0x1234_5678_9ABC_DEF0
  After:  0x1234_5678_1234_DEF0  (中间16位被替换)

  应用：
  - 原子更新结构体中的特定字段
  - 细粒度锁的部分更新
  - 标志位原子修改
```

### 4.3 掩码原子的典型应用

```c
// 掩码原子应用：原子更新统计结构体
struct stats {
    uint64_t rx_bytes;    // 偏移 0
    uint64_t tx_bytes;    // 偏移 8
    uint64_t rx_packets; // 偏移 16
    uint64_t tx_packets; // 偏移 24
};

// 使用掩码 FA 原子更新 rx_bytes
uint64_t mask = 0xFFFFFFFF00000000;  // 只操作高 32 位
// 但实际应用中，掩码 FA 通常按自然对齐进行
```

---

## 5. 内存序与原子操作

### 5.1 RDMA 内存序模型

RDMA 原子操作的内存序比普通内存操作更严格：

```
RDMA 内存序保证：

  1. 原子性保证
     - 原子操作是原子的，不会被其他操作拆分
     - 不会出现部分更新

  2. 排序保证
     - 同一 QP 内的操作按顺序提交
     - 不同 QP 的操作无序

  3. 持久性保证
     - 需要 WRITE_WITH_IMM 或 Signaled 操作
     - 确认数据已写入内存
```

### 5.2 原子操作与 Memory Barrier

```c
// 正确的原子操作顺序
struct operation {
    // 1. 先发布原子操作
    rdma_ext_cas64(qp, remote_addr, old_val, new_val);

    // 2. 内存屏障（如果需要）
    // IB 自动保证 ordering

    // 3. 后续操作可以依赖原子操作结果
};
```

### 5.3 原子操作与 CQ

```c
// 原子操作的完成通知
struct ibv_wc wc;

while (ibv_poll_cq(cq, 1, &wc)) {
    if (wc.status == IBV_WC_SUCCESS) {
        switch (wc.opcode) {
        case IBV_WC_EXT_COMP:
            // 扩展原子操作完成
            // wc.ex.imm_data 或 wc.wr_id 携带返回值
            break;
        }
    }
}
```

---

## 6. 扩展原子 API

### 6.1 扩展原子操作函数

```c
// 64 位 Fetch-And-Add（扩展原子）
int ibv_post_ext_send(struct ibv_qp *qp,
                       struct ibv_send_wr *wr,
                       struct ibv_send_wr **bad_wr);

// 扩展原子使用 send_wr 配置
struct ibv_send_wr ext_wr = {
    .wr_id = (uint64_t)context,
    .opcode = IBV_WR_EXT_ATOMIC_FA,  // 64位 FA
    .wr.atomic.remote_addr = remote_addr,
    .wr.atomic.rkey = rkey,
    .wr.atomic.compare_add = addend,  // 64位加数
    .wr.atomic.swap = 0,               // 不使用
    .wr.atomic.compare_len = IBV_EXT_ATOMIC_64BIT,  // 64位
};
```

### 6.2 128 位 CAS 操作

```c
// 128 位 CAS 需要特殊处理
// 使用 ibv_post_send + IBV_WR_EXT_COMP_AND_ADD

struct {
    uint64_t[2] compare;  // 128 位比较值
    uint64_t[2] swap;     // 128 位交换值
} ext_cas128;

// 128 位原子需要两次本地操作：
// 1. 先读取远程 128 位值
// 2. 再执行 CAS（软件保证原子性）
```

### 6.3 掩码原子操作

```c
// 掩码原子操作（需要支持掩码的硬件）
struct ibv_send_wr masked_wr = {
    .opcode = IBV_WR_EXT_MASKED_ATOMIC_CAS,  // 或 IBV_WR_EXT_MASKED_ATOMIC_FA
    .wr.masked_atomic.remote_addr = remote_addr,
    .wr.masked_atomic.rkey = rkey,
    .wr.masked_atomic.compare_mask = mask,
    .wr.masked_atomic.compare_add = value,
    .wr.masked_atomic.swap_mask = mask,
    .wr.masked_atomic.swap = new_value,
};
```

---

## 7. 分布式算法中的应用

### 7.1 64 位计数器

```c
// 高精度流量统计（64 位原子计数器）
struct flow_counter {
    uint64_t packet_count;
    uint64_t byte_count;
};

// 原子更新
rdma_ext_fa64(qp, counter_addr + offsetof(byte_count), bytes);

// 原子读取
rdma_ext_load64(qp, counter_addr);
```

### 7.2 无锁 MPMC 队列

```c
// 使用 128 位 CAS 实现无锁队列
struct queue_node {
    uint64_t data;
    uint64_t next;  // 指向下一个节点或特殊标记
};

// 入队操作：CAS tail->next 从 NULL 到新节点
cas128(tail_addr, [old_tail, NULL], [new_node, new_node]);

// 出队操作：CAS head->next 从旧节点到新节点
cas128(head_addr, [old_head, old_next], [new_next, new_next]);
```

### 7.3 分布式锁

```c
// 64 位自旋锁实现
#define LOCK_FREE 0
#define LOCK_TAKEN 1

// 获取锁
while (ext_cas64(lock_addr, LOCK_FREE, LOCK_TAKEN) != LOCK_FREE) {
    //忙等待或退避
}

// 释放锁
ext_cas64(lock_addr, LOCK_TAKEN, LOCK_FREE);
```

---

## 8. 硬件支持与限制

### 8.1 扩展原子支持查询

```bash
# 查询设备扩展原子支持
$ ibv_devinfo -v mlx5_0 | grep -i atomic

# 示例输出
Atomic capabilities:
    support_ext_atomics: true
    64-bit atomics:      supported
    128-bit atomics:     supported
    masked atomics:       supported
```

### 8.2 常见硬件限制

```
扩展原子硬件限制：

  Mellanox ConnectX-6/7:
  - 64 位原子：完全支持
  - 128 位原子：完全支持
  - 掩码原子：部分支持

  Intel Omni-Path:
  - 扩展原子支持有限
  - 建议查看具体规格

  RoCE vs IB:
  - InfiniBand 通常完整支持
  - RoCE 可能部分支持
```

---

## 9. 小结

- **扩展原子价值**：64/128 位操作、掩码操作，提供更强大的单边编程能力
- **64 位原子**：支持更大的计数器和数据结构的原子更新
- **128 位 CAS**：实现无锁数据结构的关键（队列、哈希表）
- **掩码原子**：细粒度原子更新特定位字段
- **内存序**：RDMA 原子提供强于普通内存操作的顺序保证
- **硬件依赖**：需要查询设备规格确认支持情况

---

> [!tip] 延伸阅读
> - [[2026-04-13-rdma-deep-dive-ch11-atomics|第十一章：RDMA 原子操作]] —— 标准原子操作介绍
> - [[2026-04-13-rdma-deep-dive-ch7-queue-pair|第七章：队列对 (QP)]] —— QP 与原子操作的关系
> - [[2026-04-13-rdma-deep-dive-ch3-infiniband|第三章：InfiniBand 架构]] —— IB 协议层原子支持
