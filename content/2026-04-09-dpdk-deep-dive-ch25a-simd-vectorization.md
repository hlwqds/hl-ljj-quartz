---
title: "DPDK 深度探索 (二十五-A)：SIMD 向量化：单核里的数据并行"
date: 2026-04-09
tags: [dpdk, series, simd, vectorization, avx, avx2, avx512, neon, pmd, performance]
description: "从标量循环到 SIMD 向量化，理解 DPDK vector PMD 为什么能降低每包指令数，以及它和 Cache、预取、批处理的关系"
---

> [!info] DPDK 深度探索系列
> 本文是第二十五章 Cache 优化的补充篇。前置阅读：
> [[2026-04-09-dpdk-deep-dive-ch25-cache-optimization|第二十五章：Cache 优化——False Sharing 与预取]]

---

## 1. SIMD 解决什么问题

SIMD 是 **Single Instruction, Multiple Data**：

```text
一条指令，同时处理多个数据。
```

它解决的不是“怎么让多个线程同时跑”，而是：

```text
单个 CPU core 上，
同一段操作要对大量数据重复执行，
每个元素的指令开销太高。
```

最早推动 SIMD 普及的是多媒体和信号处理：

```text
图像:  对每个像素做亮度、滤波、颜色转换
音频:  对每个采样点做滤波、混音、编码
视频:  对像素块做运动补偿、DCT、解码
科学计算: 向量、矩阵、浮点数组运算
```

这些任务有共同特征：

```text
数据量大
元素宽度小，常见 8/16/32/64 bit
每个元素做相同操作
分支少
吞吐比单个元素延迟更重要
```

DPDK 的 RX/TX 热路径正好也有类似特征：

```text
一次 burst 处理多个 descriptor
descriptor 格式固定
mbuf metadata 布局固定
每个包都要做相似的小动作
目标是降低每包 cycles
```

所以 DPDK 很早就引入了 vector PMD。2014 年 ixgbe 10G PMD 的 vectorized RX/TX patch 已经出现在公开邮件列表；DPDK 2.0 的 ixgbe 文档也已经有 Vector PMD 章节。

---

## 2. 标量 vs 向量化

### 2.1 标量循环

普通标量代码一次处理一个元素：

```c
void
add_scalar(uint32_t *dst, const uint32_t *a, const uint32_t *b, int n)
{
    for (int i = 0; i < n; i++) {
        dst[i] = a[i] + b[i];
    }
}
```

逻辑上每个元素都要经历：

```text
load a[i]
load b[i]
add
store dst[i]
loop branch
```

处理 8 个元素，就重复 8 次。

### 2.2 SIMD 循环

如果使用 256-bit AVX2，一条向量寄存器可以容纳 8 个 `uint32_t`：

```text
256 bit / 32 bit = 8 lanes
```

向量化后的逻辑变成：

```text
vector load  [a0 a1 a2 a3 a4 a5 a6 a7]
vector load  [b0 b1 b2 b3 b4 b5 b6 b7]
vector add   [a0+b0 ... a7+b7]
vector store [dst0 ... dst7]
```

用伪代码表示：

```c
void
add_vectorized(uint32_t *dst, const uint32_t *a, const uint32_t *b, int n)
{
    int i = 0;

    for (; i + 8 <= n; i += 8) {
        vec256 va = load256(&a[i]);
        vec256 vb = load256(&b[i]);
        vec256 vc = add8x32(va, vb);
        store256(&dst[i], vc);
    }

    for (; i < n; i++) {
        dst[i] = a[i] + b[i];
    }
}
```

后面的标量循环叫 tail handling，用来处理不足一个向量宽度的剩余元素。

### 2.3 直观对比

```text
标量:
  add a0,b0
  add a1,b1
  add a2,b2
  add a3,b3
  add a4,b4
  add a5,b5
  add a6,b6
  add a7,b7

向量:
  add [a0..a7], [b0..b7]
```

这就是 SIMD 的核心：**把很多次相同的小操作合并成一次宽操作**。

---

## 3. 它到底省了什么时间

SIMD 最直接省掉的是：

```text
重复指令数
循环控制开销
地址计算次数
前端 decode/issue 压力
每元素或每包固定处理成本
部分 load/store 指令数量
```

它不直接省掉的是：

```text
DRAM 延迟
Cache miss 本身
复杂分支判断
不规则内存访问
锁和跨核同步
```

所以可以这样分工理解：

```text
Cache 优化:     少等数据
Prefetch:       提前把数据拉近 CPU
Batch:          摊薄函数调用、同步和队列操作
SIMD:           减少重复执行相同操作的指令数
Ring 优化:      减少跨核 ownership 迁移和同步等待
```

DPDK 的性能通常不是靠一个技巧，而是这些技巧叠加：

```text
burst API 批处理
mbuf/cache line 布局
prefetch 隐藏内存延迟
per-lcore 数据减少 false sharing
vector PMD 减少每包指令数
```

---

## 4. 理论收益怎么算

如果一个循环完全由可向量化操作构成，理论上指令数下降接近：

```text
减少比例 ~= 1 - 1 / W
```

`W` 是每条向量指令一次处理几个元素。

| 指令宽度         | 数据类型   | 一次处理 | 理论指令下降上限 |
| ---------------- | ---------- | -------: | ---------------: |
| 128-bit SSE/NEON | `uint32_t` |     4 个 |              75% |
| 256-bit AVX2     | `uint32_t` |     8 个 |            87.5% |
| 512-bit AVX-512  | `uint32_t` |    16 个 |           93.75% |
| 256-bit AVX2     | `uint64_t` |     4 个 |              75% |
| 512-bit AVX-512  | `uint64_t` |     8 个 |            87.5% |

但真实循环里不全是可向量化操作。更现实的模型是：

```text
标量总成本 = S + F
向量总成本 = S / W + F + V
```

含义：

```text
S: 可向量化的标量工作
F: 固定开销，比如循环控制、函数框架、不可向量化逻辑
W: 向量宽度
V: 向量化额外成本，比如 shuffle、mask、尾部处理、对齐修正
```

例子：

```text
处理 8 个元素:

标量:
  可向量化工作 80 条指令
  固定开销     20 条指令
  总计        100 条指令

AVX2:
  可向量化工作 80 / 8 = 10 条
  固定开销     20 条
  额外开销     10 条
  总计         40 条

指令数减少:
  100 -> 40，减少 60%
```

所以实际收益通常是：

```text
规则数组计算:       50% - 90% 指令数下降
descriptor 批处理:  20% - 60% per-packet 指令数下降
分支很多的逻辑:     收益很小，甚至退回 scalar path
```

---

## 5. CPU 怎么执行 SIMD

### 5.1 Vector Register

SIMD 使用更宽的寄存器。

```text
SSE:     128-bit XMM
AVX/AVX2: 256-bit YMM
AVX-512: 512-bit ZMM
ARM NEON: 常见 128-bit vector register
```

一个 256-bit 寄存器可以解释成不同 lane：

```text
32 x uint8_t
16 x uint16_t
 8 x uint32_t
 4 x uint64_t
 8 x float
 4 x double
```

同一条指令会对每个 lane 做相同操作。

### 5.2 Load / Compute / Store

典型 SIMD 循环还是三步：

```text
load:    把连续数据加载到 vector register
compute: 对多个 lane 同时执行计算
store:   把结果写回内存
```

如果数据连续、对齐良好、分支少，SIMD 很容易发挥作用。

如果数据是链表、随机指针、复杂分支，SIMD 会很难用。

### 5.3 Shuffle 和 Mask

真实程序不总是简单加法。经常需要：

```text
shuffle: 重新排列 lane
blend:   按条件选择 lane
compare: 批量比较
mask:    只对满足条件的 lane 生效
```

AVX-512 强化了 mask 能力，所以可以表达更多“部分 lane 有效”的逻辑。但 AVX-512 也可能带来降频和功耗问题，不能默认认为一定更快。

---

## 6. 为什么 DPDK 适合 SIMD

DPDK 的 packet I/O 热路径天然适合向量化。

### 6.1 Descriptor 格式固定

网卡 RX/TX queue 是 descriptor ring：

```text
desc[0], desc[1], desc[2], ...
```

每个 descriptor 的字段布局固定：

```text
status
length
offload flags
buffer address
```

批量收包时，PMD 会连续检查多个 descriptor。这个模式非常适合 vector load、compare、mask。

### 6.2 Burst API 天然批处理

DPDK API 不是一次收一个包，而是：

```c
uint16_t nb_rx = rte_eth_rx_burst(port, queue, pkts, 32);
```

一次 burst 里有多个包，vector PMD 可以把这批包当成 SIMD 的输入。

### 6.3 mbuf metadata 布局固定

`rte_mbuf` 的热字段集中在前几个 cache line。PMD 可以批量填充：

```text
data_off
refcnt
nb_segs
port
packet_type
pkt_len
data_len
ol_flags
```

这类固定字段填充也适合宽 load/store 和 shuffle。

### 6.4 每包操作高度重复

RX 热路径里大量动作是重复的：

```text
检查 descriptor done bit
读取 packet length
设置 mbuf data_len/pkt_len
设置 packet_type/offload flags
把 mbuf 指针放入返回数组
更新 queue index
```

如果标量处理，每个包都做一遍。vector path 会把“每包重复的小动作”合并成“每批几个包一起做”。

---

## 7. DPDK 哪里用 SIMD

### 7.1 Vector PMD

PMD 常见两类路径：

```text
scalar path:
  一次处理一个 descriptor/packet

vector path:
  一次处理多个 descriptor/packet
```

以 ixgbe 为例，DPDK 2.0 文档已经说明：

```text
Vector PMD uses Intel SIMD instructions to optimize packet I/O.
```

它的目标是：

```text
用更宽的 SSE/AVX register 提升 L1 load/store 效率
一次容纳多个 packet buffer
减少 bulk packet processing 的指令数
```

### 7.2 rte_vect.h

DPDK 提供 `rte_vect.h` 这类抽象头文件，屏蔽不同架构的 vector 类型和能力差异。

常见平台：

```text
x86: SSE, AVX2, AVX-512
ARM: NEON
Power: Altivec/VSX
```

### 7.3 rte_memcpy / hash / checksum / crypto

除了 PMD，DPDK 其他库也会用 SIMD：

```text
rte_memcpy:  宽 load/store 加速小块/中块内存复制
hash:        批量比较 key 或优化哈希计算
checksum:    批量加和
crypto:      AES、GHASH、SHA 等指令或 vector path
compress:    压缩/解压中的重复数据处理
ACL/LPM:     部分查找路径可用 SIMD 并行比较
```

### 7.4 AVX-512 不是默认无脑开

AVX-512 的寄存器更宽，但可能带来：

```text
CPU 降频
功耗上升
更高的指令延迟
更复杂的调度压力
```

DPDK 提供 max SIMD bitwidth 控制。应用可以通过 EAL 参数或 API 控制最大 SIMD 宽度：

```bash
--force-max-simd-bitwidth=512
```

```c
rte_vect_set_max_simd_bitwidth(RTE_VECT_SIMD_512);
```

实际是否开启 AVX-512，要靠 benchmark 决定。

---

## 8. 什么时候 SIMD 不划算

SIMD 适合规则批处理，但不适合所有场景。

### 8.1 分支太多

如果每个包走不同逻辑：

```text
packet 0: IPv4 + TCP
packet 1: IPv6 + UDP
packet 2: VLAN + tunnel
packet 3: fragmented packet
```

vector lane 会分歧。CPU 不能让同一条 SIMD 指令里的不同 lane 自由执行完全不同的控制流。

结果是：

```text
需要 mask
需要 blend
需要拆分路径
或者直接退回 scalar path
```

### 8.2 数据不连续

SIMD 最喜欢连续数组：

```text
a[0], a[1], a[2], a[3]
```

不喜欢指针追踪：

```text
node->next->next->next
```

网络包 payload 经常是指针指向不同 mbuf data buffer。metadata 比 payload 更容易向量化。

### 8.3 内存瓶颈明显

如果瓶颈是 DRAM：

```text
每次访问都 cache miss
数据完全随机
预取也救不了
```

SIMD 减少指令数也可能帮助有限，因为 CPU 主要在等内存。

### 8.4 包形态不满足 vector PMD 条件

很多 PMD 的 vector path 有前提：

```text
特定 offload 不能开启
mbuf 不能 chained 或 scattered
descriptor 数量/对齐要满足要求
burst size 有建议值
queue 配置要符合限制
```

条件不满足时，PMD 会选择 scalar path。

---

## 9. 和 Cache、Prefetch、Ring 的关系

SIMD 经常和 cache 优化一起出现，但它们解决的问题不同。

```text
SIMD:
  同一 core 上，一条指令处理多个数据
  主要减少 per-element/per-packet 指令数

Cache layout:
  让热字段集中，减少 cache miss
  减少无用数据被带进 cache

Prefetch:
  提前把未来要用的数据拉到 cache
  隐藏部分内存访问延迟

Batch:
  一次处理多个包
  摊薄函数调用、队列更新、doorbell、同步成本

Ring sync:
  处理多核之间的生产/消费同步
  减少 cache line ownership bouncing 和 tail 等待
```

DPDK 的 vector PMD 依赖这些基础：

```text
没有 burst，就没有足够多的元素给 SIMD 一起处理
没有 cache-friendly mbuf/descriptor，就会被 load miss 拖住
没有 prefetch，宽指令也可能等数据
没有合理 ring/cache line 隔离，多核同步会吃掉收益
```

所以 DPDK 的优化不是单点技巧，而是一套组合拳：

```text
数据布局 + 批处理 + 预取 + SIMD + per-lcore + ring 同步
```

---

## 10. 一个 DPDK RX Vector Path 的思维模型

下面不是某个 PMD 的真实源码，只是帮助理解 vector path 在做什么。

### 10.1 Scalar 思维

```c
for (int i = 0; i < nb_pkts; i++) {
    desc = rxq->desc[rx_id];

    if (!(desc.status & DD))
        break;

    m = rxq->sw_ring[rx_id].mbuf;
    m->data_len = desc.length;
    m->pkt_len = desc.length;
    m->ol_flags = parse_flags(desc);

    rx_pkts[i] = m;
    rx_id = next(rx_id);
}
```

每个包都要：

```text
读 descriptor
判断 done
读 length
填 mbuf
写 rx_pkts
更新 index
```

### 10.2 Vector 思维

```text
一次加载 4 个 descriptor
一次比较 4 个 done bit
一次提取 4 个 length
批量构造 4 个 mbuf 的 rearm/metadata
一次写回多个 mbuf 字段
一次返回多个 mbuf 指针
```

核心变化是：

```text
不是 4 个包做 4 遍同样逻辑，
而是把 4 个包的同类字段放在一起处理。
```

这就是 DPDK vector PMD 能降低 cycles/packet 的原因。

---

## 11. 学习时要抓住的几个判断

看到一段热路径时，可以问 5 个问题：

1. 这段代码是否对很多元素做相同操作？
2. 数据是否连续或至少可以批量加载？
3. 分支是否少，或者能用 mask 表达？
4. 结果是否能批量写回？
5. 瓶颈是指令数，还是内存等待/同步等待？

如果答案是：

```text
相同操作多
数据规则
分支少
批量读写
瓶颈偏指令吞吐
```

那它就是 SIMD 的好候选。

如果答案是：

```text
每个元素走不同逻辑
大量随机指针
cache miss 很重
跨核同步很重
```

那 SIMD 不是第一优先级，应该先看数据布局、cache、prefetch、批处理或同步设计。

---

## 12. 小结

1. **SIMD 是数据并行**：不是多线程并发，而是一条指令同时处理多个 lane。

2. **它主要减少指令数**：尤其是重复 load/compute/store、循环控制、地址计算和每包固定开销。

3. **理论收益取决于向量宽度**：理想上接近 `1 - 1/W`，现实中还要加固定开销和 shuffle/mask/tail 处理。

4. **DPDK 适合 SIMD**：descriptor ring、mbuf metadata、burst API 都是规则批处理结构。

5. **vector PMD 是典型用法**：一次处理多个 RX/TX descriptor，降低 cycles/packet。

6. **SIMD 不解决所有问题**：cache miss、随机访问、复杂分支、跨核同步仍然需要其他优化。

7. **AVX-512 不一定最快**：更宽不等于更快，可能降频，必须 benchmark。

8. **和 Cache 优化互补**：SIMD 省重复指令，prefetch/cache 省等待数据，ring/per-lcore 省同步和 ownership 迁移。

---

## 13. Practice：标量 vs AVX2

仓库中有一个最小 SIMD 演示程序：

```text
practice/simd_vectorization/
├── Makefile
├── README.md
├── run.sh
└── simd_demo.c
```

它对同一组 `uint32_t` 数组分别执行标量加法和 AVX2 加法：

```text
dst[i] = a[i] + b[i]
```

AVX2 路径一次处理 8 个 `uint32_t` lane：

```text
256 bit / 32 bit = 8 lanes
```

运行：

```bash
cd practice/simd_vectorization
make
./simd_demo
```

也可以指定元素数量和迭代次数：

```bash
./simd_demo 16777216 10
```

这个例子不依赖 DPDK，重点是直接观察：

```text
标量循环：一次处理 1 个元素
AVX2 循环：一次处理 8 个元素
```

---

> [!tip] 参考资料
>
> - DPDK ixgbe Vector PMD 文档：https://doc.dpdk.org/guides-2.0/nics/ixgbe.html#vector-pmd-for-ixgbe
> - DPDK AVX-512 使用说明：https://doc.dpdk.org/guides/howto/avx512.html
> - DPDK API `rte_vect.h`：https://doc.dpdk.org/api/rte__vect_8h.html
> - 2014 ixgbe vectorized RX/TX patch：https://mails.dpdk.org/archives/dev/2014-May/002795.html
> - Intel 64 and IA-32 Architectures Optimization Reference Manual
> - Agner Fog, "Optimizing software in C++" and instruction tables
