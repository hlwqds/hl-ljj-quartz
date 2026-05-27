---
title: "DPDK 深度探索 (二十五-B)：预取技术：把内存等待变成后台工作"
date: 2026-04-09
tags: [dpdk, series, prefetch, cache, latency, cycles, memory, performance, mbuf]
description: "系统理解预取技术：它像异步 cache warmup，用计算 cycles 覆盖内存访问延迟，并解释 DPDK 中如何选择预取距离"
---

> [!info] DPDK 深度探索系列
> 本文是第二十五章 Cache 优化的补充篇。前置阅读：
> [[2026-04-09-dpdk-deep-dive-ch25-cache-optimization|第二十五章：Cache 优化——False Sharing 与预取]]

---

## 1. 预取解决什么问题

CPU 很快，内存相对很慢。

```text
L1 hit:     ~4 cycles
L2 hit:     ~12 cycles
L3 hit:     ~30-60 cycles
DRAM miss:  ~150-300+ cycles
```

如果程序真正用数据时才发起 load，并且数据不在 cache，CPU 就可能停在这条 load 上等：

```text
load data
  cache miss
  等 DRAM/L3 返回
  继续执行
```

这段等待在关键路径上：

```text
计算 -> miss 等待 -> 计算
```

预取的目标不是让 DRAM 变快，而是：

```text
提前发起内存请求，
让内存系统在后台把数据搬到 cache，
用中间的计算 cycles 覆盖内存延迟。
```

所以预取省掉的是：

```text
CPU 因 cache miss 原地等待的空转 cycles
```

它不省：

```text
内存带宽
真实搬运的数据量
cache line 大小
DRAM 物理访问延迟
```

---

## 2. 预取像什么

可以把预取理解成一种 **硬件层面的异步 cache warmup hint**。

```c
rte_prefetch0(ptr);
```

这句话的意思不是“马上读取 `*ptr` 到变量”，而是告诉 CPU：

```text
我后面可能要用 ptr 所在的 cache line，
你现在可以提前把它拉近。
```

程序不会等待预取完成，而是继续执行。

```text
发起 prefetch
继续处理当前包
继续处理下一个包
真正访问被预取的数据
```

如果预取成功，后续 load 可能变成 cache hit。

如果预取失败、太晚、太早或地址不准，后续 load 还是 miss，甚至会污染 cache。

### 2.1 和 async I/O 的相似点

```text
普通 async I/O:
  发起请求
  继续做别的事
  后面等待或拿结果

CPU prefetch:
  发起 cache line 加载 hint
  继续执行后续指令
  后面 load 时自然 hit 或 miss
```

### 2.2 和 async I/O 的区别

| 项目 | 普通 async I/O | CPU prefetch |
| --- | --- | --- |
| 请求对象 | 文件、网络、磁盘 | 内存 cache line |
| 是否保证执行 | 通常有明确语义 | 只是 hint，CPU 可忽略 |
| 是否返回结果 | 有 callback/future/result | 没有结果 |
| 是否报错 | 可能报错 | 不报错 |
| 是否改变程序语义 | 会 | 不应该改变语义 |
| 等待方式 | await/poll/callback | 后续 load 自然命中或 miss |

一句话：

```text
预取是 best-effort async cache warmup。
```

---

## 3. 预取和 cycles 的关系

预取要提前多少，取决于：

```text
内存访问延迟 cycles
每次循环可用来覆盖延迟的处理 cycles
```

核心公式：

```text
预取距离 × 每次循环处理成本 ≈ 内存访问延迟
```

例子：

```text
每处理一个包需要 25 cycles
目标数据 miss 到 DRAM 需要 200 cycles

预取距离 ≈ 200 / 25 = 8 个包
```

所以处理第 `i` 个包时，可以预取第 `i + 8` 个包：

```c
for (int i = 0; i < nb_pkts; i++) {
    if (i + 8 < nb_pkts)
        rte_prefetch0(mbufs[i + 8]);

    process_packet(mbufs[i]);
}
```

时间线：

```text
处理 i:
  prefetch i+8  ---- memory request starts

处理 i..i+7:
  useful work covers latency

处理 i+8:
  data may already be in cache
```

### 3.1 预取太近

```text
prefetch i+1
只提前 25 cycles
目标延迟 200 cycles
```

结果：

```text
真正 load 时数据还没到
CPU 仍然要等
```

### 3.2 预取太远

```text
prefetch i+64
提前太多
```

结果可能是：

```text
数据太早进 cache
还没用就被 eviction
污染 L1/L2
浪费内存带宽
挤掉更有用的数据
```

### 3.3 合适窗口

```text
太近: 来不及
刚好: 使用时 hit
太远: 污染 cache 或被挤出
```

这就是 DPDK 代码里经常看到 `PREFETCH_OFFSET = 4` 或 `8` 的原因。

---

## 4. 软件预取 vs 硬件预取

### 4.1 硬件预取器

现代 CPU 有硬件预取器，会自动识别一些访问模式：

```text
连续访问: a[0], a[1], a[2], ...
固定步长: a[0], a[8], a[16], ...
相邻 cache line
部分 stream pattern
```

这种场景下，程序不写 prefetch，CPU 也可能自动提前拉数据。

### 4.2 软件预取

软件预取是程序员显式告诉 CPU：

```text
这个地址后面会用。
```

它适合硬件预取器不容易猜到，但程序知道未来访问的场景：

```text
mbuf 指针数组
descriptor ring
hash table bucket
flow table entry
下一批 packet metadata
```

DPDK 里很多访问不是纯数组数据本身，而是：

```text
先读 mbuf 指针数组
再通过指针访问 mbuf
再通过 mbuf 访问 packet data
```

这种指针间接访问，硬件预取器不一定能提前猜到，所以软件预取有价值。

---

## 5. Cache Line 是预取单位

预取通常不是把一个字段拉进 cache，而是把它所在的 cache line 拉进来。

现代 x86/ARM 上常见 cache line 是 64 bytes：

```text
访问 1 byte
实际加载 64B cache line
```

例如：

```c
rte_prefetch0(mbuf);
```

通常会把 `mbuf` 开头所在的 64B cache line 拉到 L1 附近。

这意味着：

```text
如果后面访问同一 cache line 内的多个字段，收益很好
如果只用一个字段，剩下 63B 可能是浪费
如果预取地址不准，会污染 cache
```

这也是为什么 DPDK 很重视结构体布局：

```text
把 RX 热路径字段放在第一个 cache line
把 TX 或冷字段放到后面的 cache line
```

这样一次预取可以覆盖多个即将访问的热字段。

---

## 6. DPDK 预取 API

DPDK 提供跨平台预取接口。

```c
static inline void rte_prefetch0(const volatile void *p);
static inline void rte_prefetch1(const volatile void *p);
static inline void rte_prefetch2(const volatile void *p);
static inline void rte_prefetch_non_temporal(const volatile void *p);
```

常见语义：

```text
rte_prefetch0:
  尽量预取到最靠近 CPU 的 cache 层级，通常面向马上要用的数据

rte_prefetch1:
  预取到较远层级，减少 L1 污染

rte_prefetch2:
  预取到更远层级

rte_prefetch_non_temporal:
  数据用完即弃，避免长期污染 cache
```

DPDK 也有写预取和 cache line demote 相关 API：

```c
rte_prefetch0_write(p);
rte_prefetch1_write(p);
rte_prefetch2_write(p);
rte_cldemote(p);
```

这些 API 的实际效果取决于 CPU 架构、编译器和平台支持。它们是性能 hint，不是程序语义保证。

---

## 7. mbuf 预取

DPDK 为 mbuf 提供了专用 helper：

```c
static inline void
rte_mbuf_prefetch_part1(struct rte_mbuf *m)
{
    rte_prefetch0(m);
}
```

`part1` 预取 mbuf 的第一个 cache line，通常包含 RX 热路径常用字段：

```text
buf_addr
buf_iova
data_off
refcnt
nb_segs
port
ol_flags
packet_type
pkt_len/data_len 等
```

还有第二部分：

```c
static inline void
rte_mbuf_prefetch_part2(struct rte_mbuf *m)
{
#if RTE_CACHE_LINE_SIZE == 64
    rte_prefetch0(RTE_PTR_ADD(m, RTE_CACHE_LINE_MIN_SIZE));
#else
    RTE_SET_USED(m);
#endif
}
```

`part2` 用于预取第二个 cache line，常见是 TX 或扩展字段。

关键点：

```text
预取 mbuf 是预取 metadata
预取 packet data 要用 rte_pktmbuf_mtod(m, ...)
两者不是一回事
```

例子：

```c
rte_mbuf_prefetch_part1(m);
rte_prefetch0(rte_pktmbuf_mtod(m, const void *));
```

第一句预取 mbuf 元数据，第二句预取 packet payload 开头。

---

## 8. DPDK 包处理里的预取模式

### 8.1 先预取窗口，再流水处理

常见写法：

```c
#define PREFETCH_OFFSET 8

for (int i = 0; i < PREFETCH_OFFSET && i < nb_rx; i++) {
    rte_mbuf_prefetch_part1(pkts[i]);
    rte_prefetch0(rte_pktmbuf_mtod(pkts[i], const void *));
}

for (int i = 0; i < nb_rx; i++) {
    if (i + PREFETCH_OFFSET < nb_rx) {
        rte_mbuf_prefetch_part1(pkts[i + PREFETCH_OFFSET]);
        rte_prefetch0(rte_pktmbuf_mtod(pkts[i + PREFETCH_OFFSET],
                                       const void *));
    }

    process_packet(pkts[i]);
}
```

含义：

```text
先把前 8 个包热起来
处理第 i 个包时，预取第 i+8 个包
让中间 8 个包的处理 cycles 覆盖内存延迟
```

### 8.2 Flow table 预取

```c
uint32_t bucket = hash & table->mask;
struct flow_entry *entry = &table->entries[bucket];

rte_prefetch0(entry);

for (int i = 0; i < BUCKET_WAYS; i++) {
    if (entry[i].key == key)
        return &entry[i];
}
```

如果 hash table bucket 不在 cache，预取可以提前发起请求。

但这里有一个限制：如果你立刻预取后立刻使用，中间没有足够计算，预取太近，效果可能很小。

更好的模式是 pipeline：

```text
计算 packet i+N 的 hash
预取 packet i+N 的 bucket
处理 packet i 的 flow lookup
```

### 8.3 Descriptor ring 预取

RX/TX descriptor 是连续 ring：

```text
desc[rx_id]
desc[rx_id + 1]
desc[rx_id + 2]
```

硬件预取器通常能处理一部分连续访问，但软件预取仍可能用于：

```text
提前拉 descriptor
提前拉 sw_ring entry
提前拉 mbuf metadata
```

---

## 9. 什么时候预取有效

预取有效通常需要满足：

```text
未来访问地址可以提前知道
发起预取和真正使用之间有足够计算
数据使用时还没有被 cache eviction
内存带宽没有被无用预取打满
预取的数据确实会被用到
```

典型有效场景：

```text
批量 packet processing
mbuf metadata pipeline
flow table lookup pipeline
descriptor ring
固定步长数组
链表但能提前看到 next 指针
```

预取最适合隐藏 latency，而不是提升 bandwidth。

---

## 10. 什么时候预取有害

### 10.1 地址预测错误

如果预取了不会用的数据：

```text
浪费内存带宽
污染 cache
挤掉有用 cache line
```

### 10.2 预取太远

数据太早进 cache，使用前被挤出。

结果：

```text
预取做了
后续 load 还是 miss
还额外污染 cache
```

### 10.3 预取太近

数据还没到就被使用。

结果：

```text
load 仍然等待
预取指令还增加了额外开销
```

### 10.4 工作集已经在 L1

如果数据本来就在 L1，预取只是在增加指令。

```text
小数组
热循环
cache hit rate 已经很高
```

这种情况下预取可能变慢。

### 10.5 纯顺序访问已经被硬件预取覆盖

如果访问模式是：

```text
array[i]
array[i+1]
array[i+2]
```

硬件预取器可能已经做得很好，软件预取收益有限。

---

## 11. 怎么选择 PREFETCH_OFFSET

可以从这个估算开始：

```text
offset = memory_latency_cycles / cycles_per_item
```

例如：

```text
memory latency: 200 cycles
per packet:     25 cycles
offset:         8
```

但真实情况要 benchmark。

建议步骤：

```text
1. 先测没有软件预取的 baseline
2. 尝试 offset = 4, 8, 12, 16
3. 观察 cycles/packet、L1/L2/L3 miss、内存带宽
4. 看 p99 latency，而不只看平均吞吐
5. 不同 CPU、包长、burst size、flow table 大小要分别测
```

常见经验：

```text
包处理 hot path: 4-8 常见
更重的 per-packet compute: offset 可小一些
更轻的 per-packet compute: offset 可能要大一些
工作集很热: 可能不需要软件预取
```

### 11.1 offset 和 batch size 的关系

如果 batch 太小，预取没有足够窗口：

```text
nb_rx = 4
offset = 8
```

那主循环里几乎没有机会预取未来包。

这也是 DPDK 喜欢 burst 的原因之一：

```text
batch 提供未来工作
未来工作给 prefetch 提供提前窗口
```

---

## 12. 如何验证预取是否有用

不要只看代码看起来“高级”。要测。

可以关注：

```text
cycles/packet
instructions/packet
L1-dcache-load-misses
LLC-load-misses
cache-misses
memory bandwidth
p50/p99 latency
```

示例：

```bash
perf stat -e cycles,instructions,L1-dcache-loads,L1-dcache-load-misses \
          -e cache-references,cache-misses \
          ./dpdk_app
```

如果预取有效，可能看到：

```text
cycles/packet 下降
stall cycles 下降
L1 miss 变化不一定简单
instructions 可能略升，因为多了 prefetch 指令
```

注意：预取可能让 instructions 增加，但 cycles 下降。这是正常的，因为它用少量指令换掉了大量等待。

---

## 13. 一个完整思维模型

没有预取：

```text
for packet i:
  load mbuf/data
  miss -> CPU 等 200 cycles
  process packet
```

有预取：

```text
for packet i:
  prefetch packet i+8
  process packet i
  ...
for packet i+8:
  load mbuf/data
  hit cache 或少等很多
```

时间线：

```text
没有预取:
  compute i | wait memory i | compute i+1 | wait memory i+1

有预取:
  prefetch i+8
  compute i | compute i+1 | ... | compute i+7
  use i+8 with data already closer
```

所以预取的本质是：

```text
把 memory latency 从关键路径搬到后台，
用可预测的未来访问和中间计算隐藏等待。
```

---

## 14. 小结

1. **预取不是让内存变快**：它提前发起 cache line 加载，隐藏后续 load 的等待时间。

2. **预取像异步请求**：但它只是 CPU hint，没有返回值、没有完成通知，也不保证执行。

3. **预取单位通常是 cache line**：不是单个字段。结构体布局越 cache-friendly，预取越值。

4. **预取距离由 cycles 决定**：`offset × cycles_per_item ≈ memory_latency_cycles`。

5. **批处理给预取创造窗口**：没有足够 batch，就没有足够“未来工作”可提前拉。

6. **预取会增加指令数**：有效时用少量 prefetch 指令换掉大量 memory stall cycles。

7. **预取可能有害**：太近、太远、地址不准、工作集已热、硬件预取已覆盖，都会浪费。

8. **DPDK 中常见预取对象**：mbuf metadata、packet data、descriptor、flow table bucket、下一批 packet。

9. **必须 benchmark**：不同 CPU、包长、burst size、数据结构和 offload 配置下，最佳 offset 可能不同。

---

> [!tip] 参考资料
>
> - DPDK API `rte_prefetch.h`：https://doc.dpdk.org/api/rte__prefetch_8h.html
> - DPDK API `rte_mbuf.h`：https://doc.dpdk.org/api/rte__mbuf_8h.html
> - Intel 64 and IA-32 Architectures Optimization Reference Manual
> - Ulrich Drepper, "What Every Programmer Should Know About Memory"
> - Agner Fog, "Optimizing software in C++"
