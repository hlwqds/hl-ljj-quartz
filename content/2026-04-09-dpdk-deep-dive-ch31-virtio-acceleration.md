---
title: "DPDK 深度探索 (三十一)：Virtio 加速与性能优化"
date: 2026-04-10 11:00:00
tags: [dpdk, series, virtio, vhost-user, packed-ring, vector-pmd, vdpa, virtio-user]
description: "深入解析 DPDK Virtio 性能优化：split/packed ring、Vector PMD 原理、vhost-user 架构、virtio-user 容器网络"
---

> [!info] DPDK 深度探索系列 0. [[2026-04-09-dpdk-deep-dive-series-index|全栈学习路径总览]]
> 1-30. 前三十章已完成 31. **第三十一章：Virtio 加速与性能优化**

---

## 1. Virtio 数据路径总览

Virtio 是云环境虚拟化网络的标准方案。理解它的性能，先看数据从网卡到 VM 的完整路径：

```
物理网卡 (NIC)
    │
    ▼
Host 内核 / DPDK (vhost)
    │
    │  virtqueue (shared memory ring)
    │
    ▼
Guest (VM) 中的 virtio PMD
```

每一段都有开销。Virtio 性能优化的核心就是**减少每一跳的代价**。

### 1.1 Virtio PMD 的收发路径

```
DPDK Virtio PMD 内部路径选择:

                    virtio_dev_start()
                         │
              ┌──────────┴──────────┐
              │                      │
         split ring              packed ring
         (virtio 1.0)            (virtio 1.1)
              │                      │
     ┌────────┼────────┐      ┌──────┼──────┐
     │        │        │      │      │      │
   vector  inorder merge  vector  normal merge
   (SSE)           (mrg)  (AVX512)       (mrg)
```

```
                  RX burst 函数选择
                  ─────────────────

split + vector:    virtio_recv_pkts_vec        ← SSE/NEON 批量解析
split + inorder:   virtio_recv_pkts_inorder     ← in-order 特性
split + mergeable: virtio_recv_mergeable_pkts   ← 大包合并
split + normal:    virtio_recv_pkts             ← 基本路径

packed + vector:   virtio_recv_pkts_packed_vec  ← AVX512
packed + normal:   virtio_recv_pkts_packed      ← packed 基本路径
packed + merge:    virtio_recv_mergeable_pkts_packed
```

Vector 路径能选上的条件比较苛刻（后面 2.3 节详述），大多数场景走 scalar 路径。

---

## 2. Split Ring vs Packed Ring

### 2.1 Split Ring (virtio 1.0)

Split ring 用**三个独立的环形缓冲区**：

```
┌─────────────────────────────────────────────────────────────────────┐
│                    Split Ring 结构                                  │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  Available Ring           Descriptor Table        Used Ring        │
│  (Driver 写)              (共享内存)               (Device 写)      │
│                                                                     │
│  ┌───────────┐            ┌───────────┐           ┌───────────┐    │
│  │ flags     │            │ desc[0]   │           │ flags     │    │
│  │ idx       │            │  addr     │           │ idx       │    │
│  │ ring[0] ──┼──→ 0      │  len      │           │ ring[0]   │    │
│  │ ring[1] ──┼──→ 1      │  flags    │           │ ring[1]   │    │
│  │ ring[2]   │            │  next     │           │ ring[2]   │    │
│  │ ...       │            │ desc[1]   │           │ ...       │    │
│  └───────────┘            │  ...      │           └───────────┘    │
│                           │ desc[N]   │                            │
│  Driver 告诉 Device       └───────────┘           Device 告诉      │
│  "这些 desc 可用"          每个 desc 描述一个       Driver            │
│                           buffer 的地址/长度       "这些已处理"      │
│                                                                     │
│  一次收包:                                                          │
│  1. Driver 把 desc 放进 Available Ring                              │
│  2. kick 通知 Device                                                 │
│  3. Device 从 desc 描述的地址 DMA 读写数据                          │
│  4. Device 把已处理的 desc 索引放进 Used Ring                       │
│  5. interrupt 或 kick 通知 Driver                                   │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

缺点：每个 desc 需要 `addr + len + flags + next` 共 16 字节，链式描述需要 `next` 指针跳转。

#### Split Ring 的 Cache 问题

Split ring 之所以 cache 不友好，是因为**三个 ring 在物理内存上位于三个不同的地址区域**：

```
物理内存布局 (split ring):

地址 0x1000 0000:  Available Ring
  ┌─────────────┐
  │ flags, idx   │
  │ ring[0..N]   │  ← Driver 读/写
  └─────────────┘

地址 0x2000 0000:  Descriptor Table
  ┌─────────────┐
  │ desc[0..N]   │  ← Driver + Device 都读
  │ 每个 16 字节  │
  └─────────────┘

地址 0x3000 0000:  Used Ring
  ┌─────────────┐
  │ flags, idx   │
  │ ring[0..N]   │  ← Device 写
  └─────────────┘
```

处理一个包的 CPU 访存路径：

```
1. 读 Available Ring[idx]   → 拿到 desc 编号 (如 3)
   Cache line 加载地址 0x1000 0000 附近 ✓

2. 读 Descriptor Table[3]   → 拿到 addr, len
   Cache line 加载地址 0x2000 0000 附近 ← 新的 cache line，可能 miss

3. 写 Used Ring[idx]        → 标记已处理
   Cache line 加载地址 0x3000 0000 附近 ← 又一次 cache miss

处理 N 个包 → 在三个区域之间反复跳转 → 大量 cache miss
```

三个 ring 不合并成一片连续内存，是因为 virtio 规范的设计：**生产者-消费者解耦**。Driver 只写 Available Ring、只读 Used Ring；Device 只写 Used Ring、只读 Available Ring。分开之后双方的写操作互不干扰，不需要锁。但代价就是 CPU cache 需要频繁在不同地址区域之间切换。

### 2.2 Packed Ring (virtio 1.1)

Packed ring 把三个 ring **合并成一个**：

```
┌─────────────────────────────────────────────────────────────────────┐
│                    Packed Ring 结构                                  │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  Ring Descriptor (circular buffer)                                  │
│                                                                     │
│  ┌──────────────┬──────────────┬──────────────┬──────────────┐     │
│  │ desc[0]      │ desc[1]      │ desc[2]      │ desc[3]      │     │
│  │ addr (8B)    │ addr (8B)    │ addr (8B)    │ addr (8B)    │     │
│  │ len  (4B)    │ len  (4B)    │ len  (4B)    │ len  (4B)    │     │
│  │ id   (2B)    │ id   (2B)    │ id   (2B)    │ id   (2B)    │     │
│  │ flags(2B)    │ flags(2B)    │ flags(2B)    │ flags(2B)    │     │
│  └──────────────┴──────────────┴──────────────┴──────────────┘     │
│                                                                     │
│  flags 包含:                                                        │
│  - AVAIL: 此 desc 是否可用 (替代 Available Ring)                    │
│  - USED:  此 desc 是否已处理 (替代 Used Ring)                       │
│  - NEXT:  是否链到下一个 desc (chaining)                            │
│  - WRITE: Device 写 / Driver 写 方向                                │
│                                                                     │
│  优点:                                                              │
│  - 只有一个 ring，cache 友好                                        │
│  - 无 next 指针跳转 (连续排列)                                      │
│  - 批量处理时顺序访问                                               │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

#### Packed Ring 为什么 Cache 友好

Packed ring 把所有信息合并到一个**连续的数组**中：

```
物理内存布局 (packed ring):

地址 0x1000 0000:  一整块连续的 desc 数组
  ┌──────────────┬──────────────┬──────────────┬──────────────┐
  │ desc[0] 16B  │ desc[1] 16B  │ desc[2] 16B  │ desc[3] 16B  │
  │ addr+len+id  │ addr+len+id  │ addr+len+id  │ addr+len+id  │
  │ +flags       │ +flags       │ +flags       │ +flags       │
  └──────────────┴──────────────┴──────────────┴──────────────┘
  └──────────── 一条 cache line (64 字节) ────────────────────┘

  ┌──────────────┬──────────────┬──────────────┬──────────────┐
  │ desc[4] 16B  │ desc[5] 16B  │ desc[6] 16B  │ desc[7] 16B  │
  └──────────────┴──────────────┴──────────────┴──────────────┘
  └──────────── 下一条 cache line ─────────────────────────────┘
```

关键数据：

| 指标                  | 值             |
| --------------------- | -------------- |
| 一个 packed desc 大小 | 16 字节        |
| 一条 cache line 大小  | 64 字节        |
| 一条 cache line 容纳  | 恰好 4 个 desc |

处理 N 个包的 CPU 访存路径：

```
1. 读 desc[0..3] → 一次 cache line 加载，拿到 4 个 desc 的全部信息
   (addr, len, id, flags 全在这 64 字节里)

2. 读 desc[4..7] → 顺序访问，CPU 硬件预取器自动预取下一条 cache line

3. 不需要在 Available / Descriptor / Used 之间跳转
   因为 AVAIL/USED flags 就在每个 desc 自己的 flags 字段里

→ 连续顺序访问 → 硬件预取器高效工作 → 极少 cache miss
```

### 2.3 对比

| 维度         | Split Ring                                                             | Packed Ring                                                       |
| ------------ | ---------------------------------------------------------------------- | ----------------------------------------------------------------- |
| virtio 版本  | 1.0                                                                    | 1.1                                                               |
| ring 数量    | 3 个 (available + desc + used)                                         | 1 个                                                              |
| desc 大小    | 16 字节                                                                | 16 字节                                                           |
| cache 友好性 | 差 (3 个 ring 在不同地址，处理每个包需在 Available→Desc→Used 之间跳转) | 好 (1 个连续数组，1 条 cache line 容纳 4 个 desc，硬件预取器高效) |
| vector RX    | SSE (x86), NEON (ARM)                                                  | AVX512 (x86), NEON (ARM)                                          |
| vector TX    | 无                                                                     | AVX512/NEON                                                       |
| 成熟度       | 高                                                                     | 较新                                                              |

---

## 3. Vector PMD：SIMD 批量解析 descriptor

### 3.1 原理

Vector PMD **不是用 SIMD 做 memcpy**，而是用 SIMD **批量解析 virtio descriptor 的 len/flags 字段**，直接写入 mbuf 的对应位置。

```
Scalar 路径 (逐个处理):
  for i in 0..7:
    len = used_ring[i].len             ← 每次一条 cache line
    mbuf[i].data_len = len - hdr_size  ← 每次一次内存写
    mbuf[i].pkt_len  = len - hdr_size
  → 8 次循环，8 次分散读写

Vector 路径 (SSE 批量处理):
  1. _mm_loadu_si128 加载 2 个 used descriptor (16 字节)
     一次读出 2 个 desc 的 index + len
  2. _mm_shuffle_epi8 用 shuffle mask 提取 len 字段
     放到 mbuf->rx_descriptor_fields1 的正确偏移
  3. _mm_add_epi16 减去 virtio header size
  4. _mm_storeu_si128 写入 mbuf 元数据

  → 一次处理 2 个 desc，4 轮处理 8 个
  → 没有 per-packet 分支
  → 顺序访问 used ring，cache 友好
```

每次循环处理 `RTE_VIRTIO_DESC_PER_LOOP = 8` 个 descriptor。

### 3.2 Vector 路径选上的条件

Vector RX 不是默认开启，条件比较苛刻：

```
启用条件 (split ring vector RX):

1. devargs 里指定 vectorized=1:
   --vdev=net_virtio_user0,path=/tmp/vhost.sock,packed_vq=0,vectorized=1
   或 PCI 设备通过 devargs

2. 编译时 CPU 支持对应 SIMD:
   x86: SSE2 (split) / AVX512 (packed)
   ARM: NEON

3. 运行时 SIMD bitwidth 允许:
   rte_vect_get_max_simd_bitwidth() >= 128 (split) / 512 (packed)

4. 以下特性不能启用:
   - VIRTIO_NET_F_MRG_RXBUF (mergeable buffer)
   - RX checksum offload
   - TCP_LRO
   - VLAN strip

   → 因为 vector 路径没有逐包处理这些特性的逻辑
```

### 3.3 实际函数

```c
// drivers/net/virtio/virtio_ethdev.h 声明

// Split ring vector RX (SSE/NEON/AltiVec)
uint16_t virtio_recv_pkts_vec(void *rx_queue,
        struct rte_mbuf **rx_pkts, uint16_t nb_pkts);

// Packed ring vector RX (AVX512/NEON)
uint16_t virtio_recv_pkts_packed_vec(void *rx_queue,
        struct rte_mbuf **rx_pkts, uint16_t nb_pkts);

// Packed ring vector TX (AVX512/NEON)
uint16_t virtio_xmit_pkts_packed_vec(void *tx_queue,
        struct rte_mbuf **tx_pkts, uint16_t nb_pkts);

// 标准路径
uint16_t virtio_xmit_pkts(void *tx_queue,
        struct rte_mbuf **tx_pkts, uint16_t nb_pkts);
uint16_t virtio_recv_pkts(void *rx_queue,
        struct rte_mbuf **rx_pkts, uint16_t nb_pkts);
```

---

## 4. vhost-user：Host 侧加速

### 4.1 架构

Virtio 的性能瓶颈通常不在 Guest，而在 **Host 侧**。vhost-user 是关键优化：

```
方案 A: QEMU 软件转发 (最慢)

NIC → Host kernel → QEMU 进程 → virtqueue → VM
              ↑
         每包两次用户态/内核态切换


方案 B: vhost-net 内核转发 (中等)

NIC → Host kernel → vhost-net kernel module → virtqueue → VM
              ↑
         零次用户态切换，但仍在内核


方案 C: vhost-user DPDK 转发 (最快)

NIC (DPDK PMD) → DPDK vhost-user 库 → virtqueue (shared memory) → VM
              ↑
         全程用户态、零拷贝、poll mode
```

```
vhost-user 数据路径:

Host (DPDK)                              Guest (VM)
┌─────────────────────┐                  ┌──────────────────┐
│                     │                  │                  │
│  NIC RX             │                  │  Virtio PMD      │
│  rte_eth_rx_burst() │                  │  rx_burst()      │
│       │             │                  │       ▲          │
│       ▼             │                  │       │          │
│  vhost-user         │   shared memory  │  virtqueue       │
│  enqueue to vring ──┼─── hugepage ────┼──► read desc     │
│       │             │                  │       │          │
│       ▼             │                  │       ▼          │
│  kick (eventfd) ────┼──────────────────┼──► VM processes  │
│                     │                  │                  │
└─────────────────────┘                  └──────────────────┘

关键:
  - virtqueue 在 hugepage 共享内存上
  - Host 写 desc + kick，Guest 读 desc + process
  - 无数据拷贝，只有指针传递
```

### 4.2 vhost-user 启动配置

Host 侧 (DPDK vhost-user 应用):

```c
// DPDK vhost-user 库
#include <rte_vhost.h>

// 注册 vhost-user 回调
static const struct rte_vhost_device_ops vhost_device_ops = {
    .new_device  = virtio_new_device,
    .destroy_device = virtio_destroy_device,
};

// 启动 vhost-user server
rte_vhost_driver_register("/tmp/vhost.sock", 0);
rte_vhost_driver_set_features("/tmp/vhost.sock", vhost_features);
rte_vhost_driver_callback_register("/tmp/vhost.sock", &vhost_device_ops);
rte_vhost_driver_start("/tmp/vhost.sock");
```

Guest 侧 (QEMU 参数):

```bash
qemu-system-x86_64 \
    -chardev socket,id=char0,path=/tmp/vhost.sock \
    -netdev vhost-user,id=net0,chardev=char0,queues=4 \
    -device virtio-net-pci,netdev=net0,mq=on,vectors=10,packed=on
    #                                                    ↑ 启用 packed ring

# 参数说明:
# vectors = 2N+2 (N 个 queue 对 + config + control)
# queues=4: 4 个 TX/RX queue 对
# packed=on: 启用 virtio 1.1 packed ring
```

---

## 5. Virtio-user：容器/进程间通信

### 5.1 什么是 virtio-user

Virtio-user 让两个 DPDK 进程**不经过 QEMU、不经过内核**，直接通过 vhost-user 协议通信：

```
传统方式:
  DPDK App A → NIC → kernel → QEMU → virtqueue → DPDK App B (in VM)
  太重了

vhost-user 方式:
  DPDK App A → vhost-user server ← Unix socket + shared memory → DPDK App B (virtio-user)
  无 QEMU、无内核、无 VM

virtio-user 方式:
  ┌──────────────┐     shared memory     ┌──────────────┐
  │  DPDK App A  │◄─────────────────────►│  DPDK App B  │
  │  vhost-user  │     hugepage           │  virtio-user  │
  │  (backend)   │     Unix socket        │  (frontend)  │
  └──────────────┘                        └──────────────┘
```

适用场景：

- 容器网络 (两个容器间的 DPDK 通信)
- 同一 host 上两个 DPDK 进程通信
- 测试和开发 (不需要物理 NIC)

### 5.2 使用方式

```bash
# 进程 A: vhost-user backend
./dpdk-app --vdev=vhost-user0,socket=/tmp/vhost.sock,client=0

# 进程 B: virtio-user frontend
./dpdk-app --vdev=virtio_user0,path=/tmp/vhost.sock,queues=4,packed_vq=1
```

Virtio-user 支持 3 种 backend：

| Backend        | 路径                   | 场景             |
| -------------- | ---------------------- | ---------------- |
| `vhost-user`   | Unix socket + hugepage | 进程间/容器间    |
| `vhost-kernel` | `/dev/vhost-net`       | 和内核网络栈对接 |
| `vhost-vdpa`   | vDPA 硬件              | 硬件加速转发     |

---

## 6. 多队列配置

### 6.1 正确的多队列配置

```c
// 端口配置
struct rte_eth_conf port_conf = {
    .rxmode = {
        .mq_mode = RTE_ETH_MQ_RX_RSS,
    },
    .rx_adv_conf = {
        .rss_conf = {
            .rss_hf = RTE_ETH_RSS_IP |
                      RTE_ETH_RSS_TCP |
                      RTE_ETH_RSS_UDP,
        },
    },
};

rte_eth_dev_configure(port_id, num_queues, num_queues, &port_conf);

// 每个 queue 的配置
struct rte_eth_dev_info dev_info;
rte_eth_dev_info_get(port_id, &dev_info);

struct rte_eth_rxconf rxq_conf = dev_info.default_rxconf;
rxq_conf.offloads = port_conf.rxmode.offloads;

struct rte_eth_txconf txq_conf = dev_info.default_txconf;
txq_conf.offloads = port_conf.txmode.offloads;

for (int i = 0; i < num_queues; i++) {
    rte_eth_rx_queue_setup(port_id, i, 256, SOCKET_ID_ANY,
            &rxq_conf, mbuf_pool);
    rte_eth_tx_queue_setup(port_id, i, 256, SOCKET_ID_ANY, &txq_conf);
}
```

### 6.2 QEMU 多队列参数

```bash
# vectors = 2 * queues + 2 (RX+TX 中断 + config + control)
qemu-system-x86_64 \
    -netdev vhost-user,id=net0,chardev=char0,queues=4 \
    -device virtio-net-pci,netdev=net0,mq=on,vectors=10
```

---

## 7. Mergeable Buffer

### 7.1 原理

标准模式下每个 descriptor 只能描述一个连续 buffer。大包（jumbo frame）需要多个 descriptor 链式连接。Mergeable Buffer 让 Guest 动态决定用多少个 buffer 来接收一个包。

```
标准模式:
  desc[0] → buffer (1518B) → 一包刚好一个 desc

大包标准模式:
  desc[0] → buffer[0] (1518B)
         → desc[1] → buffer[1] (1518B)    ← 链式，需要 next 指针
                   → desc[2] → buffer[2] (剩余)

Mergeable Buffer:
  Host 告诉 Guest: "这个包 4000 字节"
  Guest 根据需要从 pool 分配多个 mbuf 链接起来
  适合大小变化的流量
```

### 7.2 注意

Mergeable Buffer 和 vector 路径**互斥**：

```
VIRTIO_NET_F_MRG_RXBUF 启用时:
  → virtio_recv_mergeable_pkts (scalar 路径)
  → 无法使用 virtio_recv_pkts_vec (vector 路径)

原因: mergeable 需要逐包解析 descriptor chain 长度
      vector 路径假设每个包只占一个 descriptor
```

所以如果追求极致小包 PPS，**不要启用 mergeable buffer**。如果需要大包支持，则必须接受 scalar 路径。

---

## 8. 配置优化清单

### 8.1 Guest 内优化

```bash
# 1. 禁用 irqbalance (避免中断漂移)
systemctl stop irqbalance

# 2. 禁用透明大页
echo never > /sys/kernel/mm/transparent_hugepage/enabled

# 3. 预留 hugepage
echo 1024 > /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages

# 4. 绑定 virtio 中断到非数据面核心
for irq in $(grep virtio /proc/interrupts | awk -F: '{print $1}' | tr -d ' '); do
    echo "1" > /proc/irq/$irq/smp_affinity
done
```

### 8.2 DPDK EAL 参数

```bash
# Guest 内 DPDK 应用
./dpdk-app \
    -l 2-5                      \   # 数据面 lcore
    -n 4                        \   # 内存通道
    --socket-mem 1024           \   # hugepage 内存
    --no-pci                    \   # 如果只用 virtio-user
    -- \
    --portmask 0x1

# 或使用 PCI virtio:
./dpdk-app \
    -l 2-5 \
    -n 4 \
    --
```

### 8.3 Virtio PMD devargs

```bash
# PCI virtio devargs (通过 --vdev 或 PCI devargs)
# 启用 vectorized 路径
--vdev=net_virtio_user0,path=/tmp/vhost.sock,vectorized=1

# packed ring
--vdev=net_virtio_user0,path=/tmp/vhost.sock,packed_vq=1

# speed / link status
--vdev=net_virtio_user0,path=/tmp/vhost.sock,speed=10000
```

---

## 9. 调试

### 9.1 确认当前使用哪条路径

```c
// 查看 port 的 RX/TX burst 函数
#include <rte_ethdev.h>

// 没有公开 API 直接获取 burst 函数名
// 但可以在 debug 日志中看到:
// --log-level=pmd.net.virtio:debug
// 启动时会打印选择的路径
```

```bash
# 启用 virtio PMD debug 日志
./dpdk-app --log-level=pmd.net.virtio:debug

# 会看到类似:
# VIRTIO: vector Rx enabled
# VIRTIO: using packed ring
# VIRTIO: mergeable buffer enabled
```

### 9.2 性能不达预期排查

```
检查清单:

1. 是否用了 packed ring?
   → QEMU 参数 packed=on
   → Guest devargs packed_vq=1

2. 是否用了 vector 路径?
   → devargs vectorized=1
   → 检查 debug 日志确认
   → mergeable buffer 必须关闭
   → checksum/vlan offload 必须关闭

3. 多队列是否生效?
   → QEMU: mq=on, queues=N
   → Guest: RSS 配置
   → 多个 lcore 轮询不同 queue

4. vhost-user 是否正常?
   → Host: 检查 vhost session 是否建立
   → 检查 hugepage 共享是否成功

5. virtqueue 大小是否合理?
   → 默认 256，可以增大到 1024 或 4096
   → 需要更多 mbuf pool 空间
```

---

## 10. 小结

1. **Virtio PMD 有多条收发路径**：split/packed ring × scalar/vector × mergeable/inorder，由 feature negotiation 和 devargs 共同决定。

2. **Packed ring (virtio 1.1)** 把三个 ring 合成一个，cache 更友好，是现代首选。

3. **Vector PMD 用 SIMD 批量解析 descriptor**，一次处理 8 个，不是做 memcpy。条件苛刻：不能开 mergeable buffer、不能开 checksum offload。

4. **vhost-user 是 Host 侧关键优化**，让 DPDK 直接和 VM 的 virtqueue 通信，无内核参与。

5. **virtio-user 绕过 QEMU**，让两个 DPDK 进程直接通过 shared memory 通信，适合容器网络。

6. **多队列 + RSS** 是基本性能要求，QEMU 和 Guest 都要配置。

7. **Mergeable buffer 和 vector 互斥**，小包 PPS 场景不要开 mergeable。

---

> 参考：
>
> - [[2026-04-09-dpdk-deep-dive-ch30-performance-tuning|DPDK 深度探索 (三十)：性能调优]]
> - DPDK Virtio PMD, https://doc.dpdk.org/guides/nics/virtio.html
> - DPDK Vhost Library, https://doc.dpdk.org/guides/prog_guide/vhost_lib.html
> - DPDK Virtio-user for Container Networking, https://doc.dpdk.org/guides/howto/virtio_user_for_container_networking.html
> - Virtio Specification v1.1, https://docs.oasis-open.org/virtio/virtio/v1.1/virtio-v1.1.html
> - DPDK API: `drivers/net/virtio/virtio_ethdev.h`, `virtio_rxtx_simple_sse.c`
