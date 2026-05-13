---
title: "Kernel Protocol Stack 深度探索 (五)：NAPI 与轮询模式"
date: 2026-04-13
tags: [linux, kernel, networking, series, napi, polling, interrupt-coalescing, dynirq]
description: "深入解析 Linux 内核 NAPI 机制——New API 的完整实现、轮询与中断的动态切换、dynirq 自适应中断合并、GRO 与 NAPI 的协同、以及常见网卡驱动的 NAPI 集成"
---

> [!info] Kernel Protocol Stack 深度探索系列
> 0. [[2026-04-13-kernel-protocol-stack-deep-dive-series-index|全栈学习路径总览]]
> 1. [[2026-04-13-kernel-protocol-stack-deep-dive-ch1-skbuff|第一章：sk_buff 与数据包生命周期]]
> 2. [[2026-04-13-kernel-protocol-stack-deep-dive-ch2-netdevice|第二章：Netdevice 与网卡抽象]]
> 3. [[2026-04-13-kernel-protocol-stack-deep-dive-ch3-ring-buffer|第三章：Ring Buffer 与 DMA]]
> 4. [[2026-04-13-kernel-protocol-stack-deep-dive-ch4-softirq|第四章：软中断与 ksoftirqd]]
> 5. **第五章：NAPI 与轮询模式**
> 6. [[2026-04-13-kernel-protocol-stack-deep-dive-ch6-ethernet|第六章：Ethernet 与 MAC 层]]

---

## 1. 概述：NAPI 解决什么问题？

### 1.1 中断风暴问题

传统中断驱动在高速网卡场景下会遭遇**中断风暴（interrupt storm）**：

```
每秒 1Mpps 吞吐量 → 1,000,000 次/秒 硬件中断
每次中断：50-100 μs 开销
总 CPU 时间：50-100% 仅用于处理中断！
```

**传统 RX 路径的致命缺陷：**

```mermaid
graph LR
    A["包1 到达"] --> B["硬中断"]
    B --> C["处理包1"]
    C --> D["包2 到达"]
    D --> E["硬中断"]
    E --> F["处理包2"]
    F --> G["包3 到达"]
    G --> H["硬中断"]
    H --> I["处理包3"]
    
    style B fill:#FFB6C1
    style E fill:#FFB6C1
    style H fill:#FFB6C1
```

### 1.2 NAPI 的核心思想

**NAPI（New API）** 是 Linux 2.6+ 引入的轮询机制，核心思想是：

1. **第一次包到达**：触发一个硬件中断
2. **关闭后续硬件中断**：防止中断风暴
3. **轮询（polling）**：软中断中批量处理数据包
4. **轮询结束**：重新开启硬件中断

```
┌─────────────────────────────────────────────────────────────┐
│                      NAPI RX 流程                           │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  包1 到达                                                   │
│     │                                                       │
│     ▼ 触发一次硬中断                                         │
│  ┌─────────────────────────────────────────────────────┐     │
│  │ 中断处理程序                                          │     │
│  │ 1. 关闭这个队列的硬件中断                              │     │
│  │ 2. 触发 NET_RX_SOFTIRQ                               │     │
│  │ 3. 触发 NAPI 轮询                                    │     │
│  └─────────────────────────────────────────────────────┘     │
│     │                                                       │
│     ▼ 开始轮询（batch processing）                           │
│  ┌─────────────────────────────────────────────────────┐     │
│  │ net_rx_action → napi_poll()                         │     │
│  │ 处理包 2, 3, 4, 5, ... 直到 budget 耗尽              │     │
│  └─────────────────────────────────────────────────────┘     │
│     │                                                       │
│     ▼ budget 耗尽，退出轮询                                  │
│  重新开启这个队列的硬件中断                                   │
│     │                                                       │
│     ▼ 包6 到达，再次触发硬中断                               │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### 1.3 NAPI 优缺点对比

| 特性 | 传统 netif_rx | NAPI |
|------|--------------|------|
| 中断频率 | 每包一次 | 远少于包数 |
| 批处理 | 无 | 有（减少 cache miss） |
| 延迟 | 低（立即中断） | 略高（等待轮询） |
| CPU 开销 | 高（中断+处理切换） | 低（批量处理） |
| 实现复杂度 | 简单 | 复杂（需要 poll 回调） |
| 适用场景 | < 100Kpps | > 100Kpps |

---

## 2. NAPI 数据结构

### 2.1 napi_struct 定义

```c
// include/linux/netdevice.h
struct napi_struct {
    /* === 链表 === */
    struct list_head    poll_list;          // 连接 softnet_data.poll_list
    
    /* === 状态 === */
    unsigned long       state;              // NAPI_STATE_xxx 标志位
    int                 weight;             // 每次轮询最多处理的包数
    int                 Gro_max_size;       // GRO 最大包大小
    
    /* === 关联 === */
    struct net_device   *dev;               // 关联的 net_device
    struct sk_buff*    (*poll)(struct napi_struct *, int);
                                        // 驱动实现的轮询回调
    
    /* === 统计 === */
    unsigned int        poll_count;         // 轮询次数（调试）
    unsigned int        gro_count;          // GRO 合并次数
    unsigned int        irq_count;          // 中断次数
    
    /* ===dynirq === */
    struct hrtimer      timer;              // dynirq 定时器
    
    /* === 内存 === */
    void                *skb;                // 预分配的 skb（可选）
    
    /* === 私有数据 === */
    void                *ptr;                // 驱动私有数据
};
```

**NAPI 状态标志：**

```c
// include/linux/netdevice.h
enum {
    NAPI_STATE_SCHED,         // 正在等待轮询
    NAPI_STATE_DISABLE,       // 已被禁用
    NAPI_STATE_NPSVC,         // 非抢占服务
    NAPI_STATE_EXCLUSIVE,      // 独占中断
    NAPI_STATE_NO_BUSY_POLL,  // 禁用 busy poll
    NAPI_STATE_IN_BUSY_POLL,  // 正在 busy poll
};
```

### 2.2 NAPI 注册：netif_napi_add

驱动在初始化时通过 `netif_napi_add` 注册 NAPI：

```c
// 驱动初始化（i40e 示例）
void i40e_set_interrupt_capability(struct i40e_pf *pf)
{
    int v_idx, q_vectors;
    
    // 计算需要的向量数
    q_vectors = pf->num_alloc_vsi * pf->num_req_q_vectors;
    
    for (v_idx = 0; v_idx < q_vectors; v_idx++) {
        struct i40e_q_vector *q_vector;
        
        q_vector = kzalloc(sizeof(*q_vector), GFP_KERNEL);
        
        // 初始化 NAPI
        netif_napi_add(pf->netdev, &q_vector->napi,
                      i40e_napi_poll,    // 轮询回调
                      NAPI_POLL_WEIGHT); // 权重
        
        // 设置权重（可选）
        // netif_napi_set_weight(&q_vector->napi, weight);
        
        // 初始化 timer（dynirq）
        hrtimer_init(&q_vector->napi.timer, CLOCK_MONOTONIC,
                     HRTIMER_MODE_REL_PINNED);
        q_vector->napi.timer.function = i40e_napi_poll_wait;
    }
}

// netif_napi_add 内部
void netif_napi_add(struct net_device *dev, struct napi_struct *napi,
                    int (*poll)(struct napi_struct *, int), int weight)
{
    INIT_LIST_HEAD(&napi->poll_list);
    napi->poll = poll;
    napi->weight = weight;
    napi->dev = dev;
    
    // 加入设备的 NAPI 链表
    list_add_tail(&napi->dev_list, &dev->napi_list);
    
    // 设置 GRO 默认值
    napi->Gro_max_size = dev->mtu + dev->hard_header_len + VLAN_HLEN;
}
```

### 2.3 NAPI 启用与禁用

```c
// 设备 open 时启用
int dev_open(struct net_device *dev)
{
    int ret;
    
    ret = __dev_open(dev);
    if (ret < 0)
        return ret;
    
    // 启用所有 NAPI
    list_for_each_entry(napi, &dev->napi_list, dev_list)
        napi_enable(napi);
    
    return 0;
}

// 设备 close 时禁用
int dev_close(struct net_device *dev)
{
    // 禁用所有 NAPI
    list_for_each_entry(napi, &dev->napi_list, dev_list)
        napi_disable(napi);
    
    __dev_close(dev);
}

// napi_enable
void napi_enable(struct napi_struct *napi)
{
    // 确保没有在禁用状态
    BUG_ON(!test_bit(NAPI_STATE_DISABLE, &napi->state));
    
    // 清除 SCHED 标志，允许轮询
    clear_bit(NAPI_STATE_DISABLE, &napi->state);
    smp_mb__after_atomic();
}

// napi_disable
void napi_disable(struct napi_struct *napi)
{
    set_bit(NAPI_STATE_DISABLE, &napi->state);
    
    // 等待正在运行的 poll 退出
    while (test_bit(NAPI_STATE_IN_BUSY_POLL, &napi->state))
        usleep_range(1000, 2000);
    
    // 等待 poll 回调完成
    while (!list_empty(&napi->poll_list))
        usleep_range(1000, 2000);
}
```

---

## 3. NAPI 轮询流程

### 3.1 轮询入口：__napi_schedule

当硬件中断触发 NAPI 时，`__napi_schedule` 将 NAPI 加入 softnet_data 的待轮询列表：

```c
void __napi_schedule(struct napi_struct *napi)
{
    unsigned long flags;
    
    local_irq_save(flags);
    
    // 加入 softnet_data.poll_list
    list_add_tail(&napi->poll_list, &this_cpu_ptr(&softnet_data)->poll_list);
    
    // 设置 SCHED 标志
    set_bit(NAPI_STATE_SCHED, &napi->state);
    
    // 触发 NET_RX_SOFTIRQ
    raise_softirq_irqoff(NET_RX_SOFTIRQ);
    
    local_irq_restore(flags);
}

// NAPI_COMPLETE：轮询完成后调用
void napi_complete_done(struct napi_struct *napi, int work_done)
{
    // 如果有更多工作要做，重新调度
    if (likely(work_done < napi->weight))
        return;
    
    // 从 poll_list 移除
    list_del_init(&napi->poll_list);
    
    // 清除 SCHED 标志
    clear_bit(NAPI_STATE_SCHED, &napi->state);
    
    // 如果在中断上下文中，不重新开启中断
    // 否则重新开启硬件中断
    if (likely(!in_interrupt())) {
        // 重新开启这个队列的硬中断
        irq_arm = true;
        ... // 驱动相关代码
    }
}
```

### 3.2 驱动 poll 回调

驱动必须实现 `napi_struct.poll` 函数，这是 NAPI 的核心：

```c
// Intel i40e NAPI poll 回调
static int i40e_napi_poll(struct napi_struct *napi, int budget)
{
    struct i40e_q_vector *q_vector = container_of(napi, struct i40e_q_vector, napi);
    struct i40e_vsi *vsi = q_vector->vsi;
    bool clean_complete = true;
    int work_done = 0;
    
    // 1. 处理 TX 完成（通常不占 budget）
    if (q_vector->tx.ring) {
        i40e_clean_tx_irq(q_vector->tx.ring);
    }
    
    // 2. 处理 RX（核心）
    if (q_vector->rx.ring) {
        int rx_budget = budget;
        
        // 如果有多队列，根据配置分配 budget
        if (vsi->num_rx_queues > 1)
            rx_budget = budget / 2;
        
        work_done = i40e_clean_rx_irq(q_vector->rx.ring, rx_budget);
        
        // 检查是否需要继续轮询
        if (work_done >= rx_budget)
            clean_complete = false;
    }
    
    // 3. 处理其他任务（如果有）
    if (!list_empty(&q_vector->tx.comphack))
        clean_complete = false;
    
    // 4. 轮询结束
    if (clean_complete) {
        napi_complete_done(napi, work_done);
        
        // 重新开启硬中断
        i40e_enable_vectors(q_vector);
        
        return work_done;
    }
    
    // 5. 还有更多工作，返回 work_done 继续轮询
    return work_done;
}
```

### 3.3 GRO 与 NAPI 的协同

**NAPI 是 GRO（Generic Receive Offload）的执行环境**：

```c
// NAPI poll 中调用 GRO
static int i40e_clean_rx_irq(struct i40e_ring *rx_ring, int budget)
{
    struct sk_buff *skb;
    int packets = 0;
    
    while (likely(packets < budget)) {
        union i40e_rx_desc *desc;
        
        desc = &rx_ring->desc[rx_ring->next_to_clean];
        if (!(desc->wb.status_error & I40E_RXD_STAT_DD))
            break;
        
        // 构建 skb
        skb = i40e_build_skb(rx_ring, desc);
        if (!skb)
            break;
        
        // 设置协议类型
        skb->protocol = eth_type_trans(skb, rx_ring->netdev);
        
        // 送入 GRO 引擎（在协议栈入口合并）
        napi_gro_receive(napi, skb);
        
        packets++;
    }
    
    return packets;
}

// napi_gro_receive 实现
gro_result napi_gro_receive(struct napi_struct *napi, struct sk_buff *skb)
{
    // 重置 GRO 信息
    skb_gro_reset_offset(skb);
    
    // 调用 GRO 引擎
    return dev_gro_receive(napi, skb);
}

// dev_gro_receive：实际 GRO 合并逻辑
gro_result dev_gro_receive(struct napi_struct *napi, struct sk_buff *skb)
{
    struct list_head *head;
    struct packet_type *ptype;
    gro_result_t ret = GRO_NORMAL;
    
    // 遍历注册的协议类型
    rcu_read_lock();
    list_for_each_entry_rcu(ptype, head, list) {
        if (ptype->type != skb->protocol)
            continue;
        
        if (ptype->gro_receive)
            ret = ptype->gro_receive(head, skb);
    }
    rcu_read_unlock();
    
    // 如果 GRO 成功（合并），不送入协议栈
    // 如果 GRO 失败（不匹配），正常送入协议栈
    if (ret == GRO_NORMAL)
        netif_receive_skb(skb);
    
    return ret;
}
```

---

## 4. dynirq：动态中断调整

### 4.1 dynirq 原理

**dynirq（Dynamic Interrupt）** 是一种自适应机制：在流量低时快速响应（高中断频率），流量高时减少中断（低频率大批量处理）。

```c
// dynirq timer 回调
static enum hrtimer_restart i40e_napi_poll_wait(struct hrtimer *hrtimer)
{
    struct i40e_q_vector *q_vector;
    
    q_vector = container_of(hrtimer, struct i40e_q_vector, napi.timer);
    
    // timer 到期，检查是否需要继续轮询
    if (!test_bit(NAPI_STATE_SCHED, &q_vector->napi.state)) {
        // 没有在轮询，重新开启硬中断
        i40e_enable_vectors(q_vector);
    }
    
    return HRTIMER_NORESTART;
}
```

### 4.2 中断合并参数

**驱动通过 ethtool 配置中断合并：**

```c
// ethtool coalesce 参数
struct ethtool_coalesce {
    __u32   rx_coalesce_usecs;         // RX 中断间隔（微秒）
    __u32   rx_max_coalesced_frames;   // 达到 N 帧后中断
    __u32   tx_coalesce_usecs;         // TX 中断间隔
    __u32   tx_max_coalesced_frames;
    __u32   rx_coalesce_usecs_irq;     // 中断服务后重置时间
    __u32   tx_coalesce_usecs_irq;
    __u32   use_adaptive_rx_coalesce;  // 自适应 RX
    __u32   use_adaptive_tx_coalesce;  // 自适应 TX
    __u32   coalesce_usecs_high;       // 高负载时阈值
    __u32   rx_max_coalesced_frames_high;
    __u32   tx_max_coalesced_frames_high;
    __u32   rate_sample_interval;      // 统计采样间隔
};
```

**ethtool 配置示例：**

```bash
# 查看当前中断合并配置
ethtool -c eth0

# 设置固定中断间隔
ethtool -C eth0 rx-usecs 100 tx-usecs 100

# 启用自适应中断合并（推荐）
ethtool -C eth0 adaptive-rx on adaptive-tx on

# 设置中断帧数阈值
ethtool -C eth0 rx-frames 32 tx-frames 32

# 组合：自适应 + 基础阈值
ethtool -C eth0 adaptive-rx on rx-usecs 50 rx-frames 16
```

### 4.3 自适应中断合并实现

```c
// Intel i40e 自适应合并
static void i40e_update_ntuple_adaptive_coalesce(struct i40e_q_vector *q_vector)
{
    struct i40e_ring_container *rx = &q_vector->rx;
    struct i40e_ring_container *tx = &q_vector->tx;
    
    // 统计本周期包数
    u32 rx_packets = q_vector->rx.pkt_count;
    u32 tx_packets = q_vector->tx.pkt_count;
    
    // 清零计数器
    q_vector->rx.pkt_count = 0;
    q_vector->tx.pkt_count = 0;
    
    // 自适应 RX
    if (rx->adaptive) {
        // 高流量：增加合并时间，减少中断
        if (rx_packets > 8000) {
            rx->target_usecs = min(rx->target_usecs + 4, rx->usecs_high);
        }
        // 低流量：减少合并时间，降低延迟
        else if (rx_packets < 1000) {
            rx->target_usecs = max(rx->target_usecs - 2, 4);
        }
    }
    
    // 类似处理 TX
    ...
}
```

---

## 5. NAPI 与 Busy Poll

### 5.1 SO_BUSY_POLL Socket 选项

**Busy poll** 允许应用程序在 socket 层直接轮询，绕过内核软中断，减少延迟：

```c
// 用户态代码
int sock = socket(AF_INET, SOCK_STREAM, 0);

// 设置 busy poll 时间（微秒）
int opt = 200;  // 200 μs
setsockopt(sock, SOL_SOCKET, SO_BUSY_POLL, &opt, sizeof(opt));

// 设置 select timeout
struct timeval tv = { .tv_usec = 200 };
setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

// 之后 recv() 会优先使用 busy poll
```

### 5.2 busy poll 实现

```c
// net/core/sock.c
int sock_busy_loop(struct sock *sk, int nonblock)
{
    struct napi_struct *napi;
    unsigned long dupTime;
    int busy = 0;
    
    // 1. 获取 socket 关联的 NAPI
    napi = sk->sk_napi;
    if (!napi)
        return 0;
    
    // 2. 轮询直到 timeout 或 nonblock
    do {
        // 检查 socket 是否有数据
        if (sk->sk_receive_queue.qlen)
            return 1;
        
        // NAPI poll（不触发软中断）
        if (test_bit(NAPI_STATE_SCHED, &napi->state)) {
            local_bh_disable();
            napi->poll(napi, napi->weight);
            local_bh_enable();
        }
        
        // pause（让出 CPU）
        cpu_relax();
        
    } while (!nonblock && time_before(jiffies, dupTime));
    
    return busy;
}
```

### 5.3 全局 busy poll 配置

```bash
# 启用全局 busy poll
sysctl -w net.core.busy_poll=50
sysctl -w net.core.busy_read=50

# 查看默认值
cat /proc/sys/net/core/busy_poll    # poll timeout（μs）
cat /proc/sys/net/core/busy_read    # recv/poll 每次循环数
```

---

## 6. 多队列 NAPI 配置

### 6.1 RSS 与 NAPI 配合

现代多队列网卡每个队列有独立的 NAPI：

```
┌─────────────────────────────────────────────────────┐
│                 16 队列 网卡                         │
├─────────────────────────────────────────────────────┤
│                                                     │
│  Queue 0  ──► NAPI[0]  ──► CPU 0 softirq           │
│  Queue 1  ──► NAPI[1]  ──► CPU 1 softirq           │
│  Queue 2  ──► NAPI[2]  ──► CPU 2 softirq           │
│  ...                                                │
│  Queue 15 ──► NAPI[15] ──► CPU 15 softirq           │
│                                                     │
│  RSS Hash ─────────────────────────────────────────►│
│  (src IP, dst IP, src port, dst port)               │
│                                                     │
└─────────────────────────────────────────────────────┘
```

### 6.2 网卡配置

```bash
# 查看网卡队列数
ethtool -l eth0

# 设置队列数（需要重启）
ethtool -L eth0 combined 8

# 查看/设置队列权重
ethtool -l eth0

# 查看单队列配置
ethtool -c eth0     # coalesce
ethtool -g eth0      # ring size
```

### 6.3 网卡驱动多队列 NAPI 示例

```c
// i40e 为每个向量创建独立的 NAPI
static int i40e_vsi_request_irq(struct i40e_vsi *vsi)
{
    struct i40e_pf *pf = vsi->back;
    char int_name[IFNAMSIZ + 16];
    
    for (int i = 0; i < vsi->num_q_vectors; i++) {
        struct i40e_q_vector *q_vector = vsi->q_vectors[i];
        
        // 分配 MSI-X 中断向量
        ret = request_irq(pf->msix_entries[vsi->base_q + i].vector,
                         i40e_msix_clean_rings, 0,
                         int_name, q_vector);
        
        // IRQ 亲和性（默认：每个向量绑定一个 CPU）
        irq_set_affinity_hint(
            pf->msix_entries[vsi->base_q + i].vector,
            cpumask_of(i % num_online_cpus())
        );
    }
}
```

---

## 7. 常见问题与调优

### 7.1 NAPI 是否启用检查

```bash
# 查看 NAPI 是否为每个设备启用
cat /sys/class/net/eth0/device/napi_defer_hard_irqs

# 查看设备是否使用 NAPI
grep . /sys/class/net/*/flags 2>/dev/null | grep -v "IFF_UP" | head

# 检查 dmesg 是否有 NAPI 相关日志
dmesg | grep -i napi
```

### 7.2 性能调优建议

```bash
# 1. 调整 NAPI weight（高吞吐场景）
sysctl -w net.core.dev_weight=256

# 2. 启用自适应中断合并
ethtool -C eth0 adaptive-rx on adaptive-tx on

# 3. 设置合适的 coalesce 参数
# 低延迟场景（小包多）
ethtool -C eth0 rx-usecs 25 rx-frames 4
# 高吞吐场景
ethtool -C eth0 rx-usecs 100 rx-frames 32

# 4. 调整 ring buffer 大小
ethtool -G eth0 rx 4096 tx 4096

# 5. 启用多队列 RSS
ethtool -L eth0 combined 8

# 6. 关闭不必要的特性
ethtool -K eth0 gro off tso off   # 如果延迟敏感
```

### 7.3 常见问题排查

```bash
# 1. softirq time_squeeze（说明 budget 不够）
cat /proc/net/softnet_stat | awk '{if($3>0) print}'

# 2. NAPI poll 次数过多（说明中断关闭后流量持续）
cat /proc/net/softnet_stat | awk '{print $2}' | sort | uniq -c

# 3. 查看具体网卡的 NAPI 统计
ethtool -S eth0 | grep -i napi

# 4. 检查是否丢包（RX drops）
ip -s link show eth0

# 5. 查看 CPU 使用分布
mpstat -P ALL 1
# 如果某个 CPU softirq 占用过高，考虑 RSS/RPS
```

---

## 8. NAPI 实现完整示例

### 8.1 简单虚拟网卡 NAPI 实现

```c
// 简化版 virtio-net NAPI 实现
static int virtnet_poll(struct napi_struct *napi, int budget)
{
    struct virtnet_info *vi = container_of(napi, struct virtnet_info, napi);
    int work_done = 0;
    
    // 1. 处理 TX 完成
    virtnet_tx_complete(vi);
    
    // 2. 接收包
    while (work_done < budget) {
        struct sk_buff *skb;
        
        skb = virtnet_get_rx_packet(vi);
        if (!skb)
            break;
        
        skb->protocol = eth_type_trans(skb, vi->dev);
        napi_gro_receive(napi, skb);
        work_done++;
    }
    
    // 3. 如果处理完了，重新开启中断
    if (work_done < budget) {
        napi_complete_done(napi, work_done);
        virtnet_enable_queue(vi);
    }
    
    return work_done;
}

// virtio 中断处理
static irqreturn_t virtnet_interrupt(int irq, void *id)
{
    struct virtnet_info *vi = id;
    
    // 1. 禁用中断
    virtnet_disable_queue(vi);
    
    // 2. 触发 NAPI
    if (napi_schedule_prep(&vi->napi)) {
        __napi_schedule(&vi->napi);
    }
    
    return IRQ_HANDLED;
}
```

---

## 9. 小结与下章预告

本章深入解析了 Linux 内核 NAPI 机制：

1. **问题背景**：中断风暴 → 批处理 → NAPI
2. **数据结构**：`napi_struct`、状态标志、注册流程
3. **轮询流程**：`__napi_schedule` → `net_rx_action` → `napi->poll()`
4. **GRO 集成**：NAPI 是 GRO 的执行环境
5. **dynirq**：动态中断合并，自适应调整
6. **busy poll**：应用层直接轮询，零延迟
7. **多队列**：RSS + 多 NAPI + per-CPU softirq

**下章（Ethernet 与 MAC 层）** 将进入 Part II，开始讲解 L2 链路层——以太网帧格式、MAC 地址学习、ARP 协议、以及交换机基础。

---

## 参考资料

- `include/linux/netdevice.h` — napi_struct 定义
- `net/core/dev.c` — NAPI 核心实现
- `Documentation/networking/napi.rst` — NAPI 官方文档
- `Documentation/networking/intel.rst` — Intel 网卡文档
- drivers/net/ethernet/intel/ — Intel 网卡驱动参考实现
