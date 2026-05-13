---
title: "Kernel Protocol Stack 深度探索 (四十一)：RSS 与 RPS"
date: 2026-04-13
tags:
  [
    linux,
    kernel,
    networking,
    series,
    rss,
    rps,
    receive-side-scaling,
    receive-packet-steering,
    smp,
    irq-affinity,
  ]
description: "深入解析 RSS（硬件 Receive Side Scaling）和 RPS（软件 Receive Packet Steering）——两者的工作原理、哈希计算、CPU 映射、irq affinity 调优，以及与 RFS（Receive Flow Steering）的协同"
---

> [!info] Kernel Protocol Stack 深度探索系列 0. [[2026-04-13-kernel-protocol-stack-deep-dive-series-index|全栈学习路径总览]] 40. [[2026-04-13-kernel-protocol-stack-deep-dive-ch40-gro-gso|第四十章：GRO 与 GSO]] 41. **第四十一章：RSS 与 RPS** 42. [[2026-04-13-kernel-protocol-stack-deep-dive-ch42-tso|第四十二章：TSO 与 UFO]] 43. [[2026-04-13-kernel-protocol-stack-deep-dive-ch43-bpf-hook|第四十三章：Linux BPF 网络钩子]] 44. [[2026-04-13-kernel-protocol-stack-deep-dive-ch44-offload|第四十四章：硬件 offload]]

---

## 1. 多队列网卡与 RSS 概述

现代网卡通常有**多个 RX 队列**（8/16/32/64 个），每个队列绑定到不同的 CPU 核心处理。这种设计解决了单队列网卡在高速网络下成为瓶颈的问题。

**RSS（Receive Side Scaling）** 是网卡的**硬件能力**，通过计算数据包的四元组（src IP, dst IP, src port, dst port）哈希值，将包分配到不同的 RX 队列。

```
多队列网卡（假设 8 个队列）
┌─────────┬─────────┬─────────┬─────────┬─────────┬─────────┬─────────┬─────────┐
│  RX Q0  │  RX Q1  │  RX Q2  │  RX Q3  │  RX Q4  │  RX Q5  │  RX Q6  │  RX Q7  │
└────┬────┴────┬────┴────┬────┴────┬────┴────┬────┴────┬────┴────┬────┬────┘
     │         │         │         │         │         │         │
     ▼         ▼         ▼         ▼         ▼         ▼         ▼
  CPU 0     CPU 1     CPU 2     CPU 3     CPU 4     CPU 5     CPU 6     CPU 7
```

**RPS（Receive Packet Steering）** 是 Linux 内核的**软件实现**，在网卡不支持 RSS 或需要更精细控制时，将 RX 队列的包分发到其他 CPU 处理。

---

## 2. RSS：硬件 Receive Side Scaling

### 2.1 RSS 哈希计算

RSS 使用 Toeplitz 哈希算法将四元组映射到 [0, num_queues-1] 的队列索引：

```c
// 哈希输入：四元组
struct rss_hash_tuple {
    __be32   src_ip;
    __be32   dst_ip;
    __be16   src_port;
    __be16   dst_port;
    __u8     protocol;  // IPPROTO_TCP 或 IPPROTO_UDP
};

// 哈希函数：Toeplitz hash
// 输出：16/32/64 位哈希值 → 取低几位作为队列索引
```

RSS 支持多种哈希类型，通过 `NETIF_F_RXHASH` 特性标志通告：

```bash
# 查看网卡 RSS 相关能力
ethtool -k eth0 | grep -i rss

# 输出示例：
# rx-hashing: on
# rx-hash:    on
# rsshash-l4: on      # 基于四元组（TCP/UDP 5-tuple）
# rsshash-l3: on      # 基于源/目 IP
# rsshash-ip: on      # 简单 IP hash
```

### 2.2 RSS 哈希函数

网卡使用 **Toeplitz 哈希**（也称 RSS hash）：

```c
// Toeplitz 哈希实现
// key: 由网卡固件或驱动程序配置的 40 字节密钥
// skb: 数据包
static u32 toeplitz_hash(const u8 *key, struct sk_buff *skb)
{
    u32 hash = 0;
    u8 hash_key[40];
    int i;

    // 从 skb 提取 5-tuple
    struct iphdr *ip = ip_hdr(skb);
    struct tcphdr *tcp = tcp_hdr(skb);

    // 构造 40-bit tuple 流（src_ip, dst_ip, src_port, dst_port, 4 zero bytes）
    memcpy(hash_key, &ip->saddr, 4);
    memcpy(hash_key + 4, &ip->daddr, 4);
    memcpy(hash_key + 8, &tcp->source, 2);
    memcpy(hash_key + 10, &tcp->dest, 2);

    // Toeplitz 乘加
    for (i = 0; i < 32; i++) {
        if (hash_key[i / 8] & (1 << (i % 8)))
            hash ^= key[i];
    }
    return hash;
}

// 队列选择：hash % num_queues
u32 rss_queue = toeplitz_hash(key, skb) & (num_queues - 1);
```

### 2.3 RSS 间接表

网卡维护一个 **indirection table**（间接表），将哈希值映射到具体的 RX 队列：

```
哈希值 (0-255)
    │
    ▼
indirect table [256 entries] → 队列索引 (0-7)
```

间接表允许管理员控制哪些哈希值映射到哪些队列，实现负载均衡策略调整：

```bash
# 查看 RSS 间接表
ethtool -x eth0

# 输出示例：
# RX queue ring parameters for eth0:
# Cache table size: 256
# Indirection table:
#  0:    0    1    2    3    4    5    6    7    0    1    2    3    4    5    6    7
# 16:    0    1    2    3    4    5    6    7    0    1    2    3    4    5    6    7
# ...

# 设置 RSS 间接表（将某些哈希值映射到指定队列）
ethtool -X eth0 equal 4   # 将 256 个入口均匀映射到 4 个队列
ethtool -X eth0 hfunc toeplitz dst-only  # 只使用目标 IP 计算哈希
```

---

## 3. RPS：软件 Receive Packet Steering

### 3.1 RPS 出现的原因

即使网卡有多队列，在以下场景仍然需要 RPS：

1. **网卡只有单队列**：传统网卡或虚拟网卡（如 virtio-net）
2. **队列数 < CPU 数**：队列数量不足以喂饱所有 CPU
3. **CPU 亲和性需求**：希望特定 flow 绑定到特定 CPU（配合 cache locality）
4. ** NUMA 优化**：将包送到访问 skb 数据所在 NUMA 节点的 CPU

### 3.2 RPS 工作原理

RPS 在 `netif_receive_skb()` 路径上被调用，通过软件方式将 skb 分发到不同 CPU：

```
NAPI poll
    │
    ▼
dev_gro_receive()  ← GRO 合并
    │
    ▼
netif_receive_skb_internal()
    │
    ├──► [RPS 钩子] → 检查是否需要重定向到其他 CPU
    │
    ▼
协议栈处理（当前 CPU）
```

### 3.3 RPS 配置

RPS 通过 `sysfs` 配置，每个 RX 队列有一个对应的 rps_cpus 文件：

```bash
# 查看 eth0 队列 0 的 RPS 配置
cat /sys/class/net/eth0/queues/rx-0/rps_cpus

# rps_cpus 是一个 16 进制掩码，表示哪些 CPU 可以处理这个队列的包
# 例如：ff 表示 CPU 0-7 都可以处理

# 设置 RPS（将包分散到所有 8 个 CPU）
echo f > /sys/class/net/eth0/queues/rx-0/rps_cpus
echo f > /sys/class/net/eth0/queues/rx-1/rps_cpus
# ... 其他队列

# 在生产环境中，通常将 RPS 与 irq affinity 配合：
# 1. 每个 RX 队列的 irq affinity 绑到特定 CPU
# 2. 该 CPU 的 rps_cpus 也包含自己 + 相邻 CPU
```

### 3.4 RPS 分发逻辑

RPS 的核心函数 `get_rps_cpu()`：

```c
// net/core/dev.c
int get_rps_cpu(struct net_device *dev, struct sk_buff *skb,
                struct rps_dev_flow **rflowp)
{
    struct rps_dev_flow_table *table;
    int cpu, idx;

    // 1. 计算 flow hash（与 RSS 相同）
    u32 hash = skb_get_hash(skb);

    // 2. 查找 RPS flow table
    table = dev->rps_dev_flow_table;
    idx = hash & table->mask;
    cpu = table->flows[idx].cpu;

    // 3. 如果 cpu 不可用（offline），查找可用的
    if (unlikely(!cpu_online(cpu))) {
        // 查找 rps_cpus 掩码中第一个在线的 CPU
        cpu = cpumask_first_and(&dev->queues[idx].rps_cpus, cpu_online_mask);
    }

    // 4. 记录本次选择，更新 flow table
    table->flows[idx].cpu = cpu;
    return cpu;
}
```

### 3.5 RPS 的开销

RPS 涉及**跨 CPU 投递 skb**：

1. 调用 `smp_call_function_single_async()` 或 `raise_softirq()` 将包送到目标 CPU
2. 目标 CPU 收到软中断，再次进入 `net_rx_action()`
3. 额外的 cache bouncing（skb 数据在 CPU 间共享）

因此 RPS 主要用于**CPU 绑定的软中断处理**，不应滥用。

---

## 4. RFS：Receive Flow Steering

### 4.1 RFS 原理

**RFS（Receive Flow Steering）** 是 RPS 的增强，尝试将同一个 flow 的包送到**同一 CPU**，利用该 CPU L1/L2 cache 中已有的 socket 数据：

```
RPS: hash % num_cpus → 负载均衡但可能破坏 cache locality

RFS: 根据 flow → 尝试送到处理过该 socket 的 CPU
                  → 更好的 cache locality
```

### 4.2 RFS 实现

RFS 使用一个全局的 `rps_sock_flow_table`，记录每个 flow（hash）上次处理的 CPU：

```c
// net/core/dev.c

// 全局 flow → CPU 映射表
struct rps_sock_flow_table *rps_sock_flow_table;

// 当 socket 处理完一个 skb 后，更新记录
void rps_record_sock_flow(struct rps_sock_flow_table *table, u16 cpu)
{
    u32 hash = skb_get_hash(skb);  // 当前包的 hash
    u32 idx = hash & table->mask;

    table->flows[idx].cpu = cpu;  // 记录该 flow 最后处理的 CPU
}

// RFS 分发时：
int get_rfs_cpu(struct net_device *dev, struct sk_buff *skb)
{
    u32 hash = skb_get_hash(skb);
    u32 idx = hash & rps_sock_flow_table->mask;
    int rfs_cpu = rps_sock_flow_table->flows[idx].cpu;

    // 检查该 CPU 是否在线且在 rps_cpus 掩码中
    if (cpu_online(rfs_cpu) &&
        cpumask_test_cpu(rfs_cpu, dev->queues[0].rps_cpus))
        return rfs_cpu;

    return RPS_NO_CPU;  // 回退到 RPS
}
```

### 4.3 启用 RFS

```bash
# RFS 需要同时启用 RPS
echo f > /sys/class/net/eth0/queues/rx-0/rps_cpus

# 调整 rps_sock_flow_table 大小（默认 32768）
sysctl -w net.core.rps_sock_flow_entries=32768

# 查看
sysctl net.core.rps_sock_flow_entries
```

---

## 5. IRQ Affinity 与队列绑定

### 5.1 查看 IRQ 亲和性

```bash
# 查看网卡 IRQ 分布
cat /proc/interrupts | grep eth0

# 输出：
# 72:   123456   234567   345678   456789   0   0   0   0   eth0-aiortx-0
# 73:   234567   345678   456789   123456   0   0   0   0   eth0-aiortx-1
# ...

# 查看特定 IRQ 的 affinity
cat /proc/irq/72/smp_affinity

# 输出是 16 进制 CPU 掩码：
# 03 → CPU 0 和 1 可以处理
# ff → CPU 0-7 都可以处理
```

### 5.2 设置 IRQ Affinity

```bash
# 将 eth0-RX-0 的 IRQ 绑定到 CPU 0
echo 1 > /proc/irq/72/smp_affinity

# 将 eth0-RX-1 的 IRQ 绑定到 CPU 1
echo 2 > /proc/irq/73/smp_affinity

# 使用 irqbalance 守护进程自动均衡（生产环境推荐）
systemctl enable irqbalance
systemctl start irqbalance
```

### 5.3 最佳实践

对于高性能网络应用，推荐的手动绑定策略：

```bash
# 假设 16 核服务器，16 RX 队列，NUMA 0 有 8 核，NUMA 1 有 8 核

# 1. 将每个 RX 队列的 IRQ 绑定到对应 NUMA 节点的 CPU
# 队列 0-7 → NUMA 0 的 CPU 0-7
# 队列 8-15 → NUMA 1 的 CPU 8-15

# 2. 设置 RPS，使能同 NUMA 节点内的 CPU 扩展
for i in $(seq 0 15); do
    # 每个队列的 rps_cpus 只包含同 NUMA 节点内的 CPU
    echo "ff00" > /sys/class/net/eth0/queues/rx-$i/rps_cpus  # NUMA 0: 0-7
done

# 3. 验证
ethtool -l eth0   # 查看队列数
cat /proc/irq/*/smp_affinity | grep -v "^0" | head -20
```

---

## 6. RSS/RPS 监控与调试

### 6.1 查看每个 CPU 的中断分布

```bash
# 查看 RX 中断在各个 CPU 的分布
cat /proc/softirqs | grep NET_RX

# 输出：
#           CPU0    CPU1    CPU2    CPU3    CPU4    CPU5    CPU6    CPU7
# NET_RX:   12345   23456   34567   45678   12345   23456   34567   45678
# 如果某个 CPU 的 NET_RX 明显高于其他，说明负载不均
```

### 6.2 查看 RPS 统计

```bash
# 查看网卡的 RPS 统计（需要内核支持）
cat /sys/class/net/eth0/queues/rx-0/rps_stats
# packets: 12345    # 这个队列通过 RPS 送出的包数
# missed: 12        # 因 CPU 不可用而回退到本地处理的包数
```

### 6.3 常见问题

| 问题            | 症状                  | 解决方案                            |
| --------------- | --------------------- | ----------------------------------- |
| IRQ 未正确绑定  | 单 CPU softirq 100%   | 设置 irq affinity                   |
| 队列数 < CPU 数 | 部分 CPU 空闲         | 启用 RPS                            |
| RPS 过度使用    | 跨 CPU cache bouncing | 限制 rps_cpus 掩码                  |
| NUMA 不亲和     | 访问远程内存延迟高    | 使用 `numactl` 绑定进程到 local CPU |

---

## 7. 总结

| 机制    | 层次 | 实现                                    | 适用场景               |
| ------- | ---- | --------------------------------------- | ---------------------- |
| **RSS** | 硬件 | 网卡计算哈希，分配到 RX 队列            | 现代多队列网卡         |
| **RPS** | 软件 | 内核在 netif_receive_skb 时重定向       | 单队列网卡、队列数不足 |
| **RFS** | 软件 | 记录 flow→CPU 映射，改善 cache locality | 需要低延迟的应用       |

RSS 和 RPS 的核心思想相同——**通过 flow hash 实现负载均衡**——只是实现层次不同。实际生产中，优先使用 RSS（硬件），RPS 作为补充，RFS 用于需要极致延迟优化的场景。
