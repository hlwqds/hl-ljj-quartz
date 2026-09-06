---
title: "Linux 内核与操作系统研发岗位：面试冲刺手册"
date: 2026-06-09
tags: [linux, kernel, interview, ebpf, performance, container, virtualization, ai-infrastructure]
description: "针对 Linux 内核、eBPF、容器安全、高性能计算与 AI 基础设施岗位的短期面试准备：知识主线、常见追问、排障方法、项目表达和实操清单"
---

> [!warning] 使用方式
>
> 这不是一本从零学习 Linux 内核的教材，而是一份面试前的压缩复习材料。
> 目标不是在几天内“精通所有子系统”，而是做到：
>
> 1. 选择一个主攻子系统并讲到实现细节；
> 2. 对其他方向能画出主链路、说清关键数据结构；
> 3. 遇到故障题时能提出可验证的排查路径；
> 4. 不虚构项目经历，能把已有经验转换成岗位需要的工程语言。

---

## 1. 先判断这个岗位真正要什么

这份 JD 看起来覆盖了整个 Linux 内核，但面试官通常不是要求候选人同时精通调度、
内存、文件系统、网络和块设备，而是在寻找以下能力组合：

```text
                    Linux 内核研发岗位
                           │
          ┌────────────────┼────────────────┐
          │                │                │
     一个深水区        系统级横向知识      工程闭环能力
          │                │                │
  能讲代码和机制      知道子系统如何交互   发现→定位→修复→验证
```

### 1.1 必须证明的六件事

| JD 表述                | 面试官实际验证的内容                               |
| ---------------------- | -------------------------------------------------- |
| 深入理解一个核心子系统 | 能否从用户接口一路讲到内核数据结构、并发和硬件     |
| 熟练使用 C/C++         | 指针、内存模型、并发、生命周期和错误处理是否可靠   |
| 内核调试能力           | 是否会根据现象选择工具，而不是只会背命令           |
| 安全与隔离机制         | 是否理解 namespace/cgroup/seccomp 的边界与组合关系 |
| 熟悉服务器硬件         | 能否把 NUMA、cache、PCIe、DMA 与性能现象联系起来   |
| 系统抽象和协作         | 能否定义接口、指标、故障边界并推动跨团队问题闭环   |

### 1.2 推荐的主攻方向

如果已有网络、DPDK、驱动或高性能 I/O 经验，最稳妥的主线是：

```text
Linux 网络协议栈
  + NAPI / softirq / sk_buff
  + eBPF/XDP
  + NUMA / DMA / PCIe
  + 容器网络与隔离
  + perf/ftrace/bpftrace
```

这条主线可以自然覆盖 JD 中的大部分关键词，而且容易形成系统性回答。不要在面试中声称
“五大子系统都很深入”。更可信的说法是：

> 我的主攻方向是 Linux 网络与高性能数据路径，能够从 socket、协议栈、qdisc、NAPI
> 一直分析到驱动、DMA 和 NUMA。调度、内存管理和容器隔离是我为解决网络性能与资源隔离
> 问题建立的横向能力。

---

## 2. 冲刺时间表

### 2.1 只有一天

按优先级完成：

1. 准备 90 秒自我介绍；
2. 准备两个项目故事，每个都能讲清问题、指标、定位、修改和收益；
3. 复习一个核心子系统的完整链路；
4. 熟记 perf、ftrace、bpftrace、crash 各自解决什么问题；
5. 复习 namespace、cgroup、seccomp、capabilities 的区别；
6. 模拟回答本文第 13 节的高频问题。

不要在最后一天开始通读内核源码。应该围绕几条调用链，查看关键函数和数据结构。

### 2.2 有三天

| 时间   | 目标               | 产出                             |
| ------ | ------------------ | -------------------------------- |
| 第一天 | 主攻子系统         | 一张调用链图、20 个高频问答      |
| 第二天 | 调试、隔离和硬件   | 三个故障排查剧本、工具速查表     |
| 第三天 | 项目表达与模拟面试 | 两个 STAR 故事、一次 60 分钟模拟 |

### 2.3 有七天

```text
Day 1  网络/主攻子系统
Day 2  调度与并发
Day 3  内存管理
Day 4  namespace/cgroup/seccomp/eBPF
Day 5  NUMA/PCIe/DMA/GPU 与性能工具
Day 6  项目复盘、系统设计题
Day 7  模拟面试、查缺补漏、休息
```

每天至少保留 30 分钟做口述。知道答案和能在压力下结构化表达，是两件不同的事。

---

## 3. 90 秒自我介绍模板

自我介绍不要从学校经历开始流水账，也不要逐条复述简历。使用“四段式”：

```text
定位 → 深水区 → 代表性闭环 → 与岗位的连接
```

参考模板：

> 我主要做 Linux 系统和高性能网络方向，工作重点是内核网络数据路径、性能定位以及
> 用户态高性能 I/O。我的技术主线可以从 socket 和协议栈，一直延伸到 NAPI、驱动、
> DMA、NUMA 和网卡队列。
>
> 我比较熟悉 sk_buff 生命周期、softirq/NAPI、GRO/GSO、qdisc、RSS/RPS/XPS，以及
> DPDK 的轮询和内存模型。遇到性能问题时，我通常先把问题分解为 CPU、调度、内存、
> 锁竞争和 I/O 几类，再用 perf、ftrace 或 eBPF 建立证据链。
>
> 在一个代表性项目中，我负责……。当时现象是……，我通过……确认瓶颈位于……，
> 最终修改……，使吞吐从……提升到……，P99 从……降到……，并补充了……监控和
> 回归测试。
>
> 这个岗位涉及内核、eBPF、容器隔离和 AI 基础设施，我已有的系统性能与网络经验
> 可以直接迁移；对于 GPU 集群和安全回溯等方向，我也建立了从硬件拓扑、资源控制到
> 可观测性的基本方法。

其中的项目和数字必须替换成真实经历。没有准确数字时可以说测量方法和相对变化，
不要编造吞吐或延迟。

---

## 4. 内核全局架构：先有地图

### 4.1 用户态进入内核的主要方式

```text
Userspace
   │
   ├─ system call
   ├─ exception / page fault
   ├─ hardware interrupt
   └─ shared memory / mmap-based interface
          │
          ▼
Kernel
   ├─ scheduler
   ├─ virtual memory
   ├─ VFS / filesystem
   ├─ network stack
   ├─ block layer
   ├─ device drivers
   └─ security and isolation
          │
          ▼
Hardware: CPU / cache / memory / PCIe / storage / NIC / GPU
```

### 4.2 面试回答的通用层次

解释任何内核问题时，尽量按下面六层展开：

1. **用户可见语义**：系统调用或配置接口是什么；
2. **关键对象**：核心结构体和生命周期；
3. **主调用链**：从入口到完成；
4. **并发模型**：进程上下文、中断、softirq、锁、RCU；
5. **资源与硬件**：内存分配、cache、NUMA、DMA；
6. **可观测性**：如何证明自己的判断。

例如回答“发送一个 TCP 包发生了什么”，只背函数名是不够的，还要说明：

- 数据何时复制或引用；
- socket buffer 如何记账；
- qdisc 是否排队；
- driver 何时取得 skb 所有权；
- DMA completion 后谁释放 skb；
- 哪些步骤在进程上下文，哪些可能在 softirq 中。

---

## 5. 主攻方向：Linux 网络栈

### 5.1 接收路径

```text
NIC receives frame
  → DMA writes RX buffer
  → interrupt / interrupt moderation
  → driver schedules NAPI
  → NET_RX_SOFTIRQ
  → napi_poll()
       ├─ clean TX completion if driver combines RX/TX cleanup
       ├─ consume RX descriptors
       ├─ XDP hook, if enabled
       └─ build skb / GRO
  → Ethernet receive
  → Netfilter / routing
  → IP
  → TCP or UDP
  → socket receive queue
  → process wakes up
  → recvmsg() copies or maps data to userspace
```

关键点：

- 硬中断通常只做确认中断、屏蔽队列中断和调度 NAPI，不应处理大量报文；
- NAPI poll 通常由 `NET_RX_SOFTIRQ` 驱动；
- poll 的工作不一定只有 RX，很多驱动会顺便回收 TX completion；
- GRO 在协议栈较早阶段合并同一 flow 的报文，减少后续逐包开销；
- native XDP 位于构造 skb 之前，因此适合早期丢包、转发和重定向；
- budget 限制一次 poll 的工作量，避免单个设备无限占用 CPU。

### 5.2 发送路径

```text
sendmsg()
  → socket send buffer accounting
  → TCP/UDP builds or appends skb
  → IP route and output
  → Netfilter
  → neighbor resolution
  → dev_queue_xmit()
  → qdisc enqueue/dequeue
  → ndo_start_xmit()
  → map skb data to DMA descriptors
  → NIC transmits
  → TX completion
  → driver reclaims descriptors
  → consume/free skb
```

常见追问：

**`dev_queue_xmit()` 会等积累一批 skb 再调用驱动吗？**

通常不会按固定包数等待。无竞争、队列可运行时，qdisc 可能立即 dequeue 并调用驱动；
发生拥塞、整形、锁竞争或设备忙时才会排队。批处理可能来自 GSO、`xmit_more`、qdisc
运行方式和驱动 doorbell 优化，但不能概括成“攒够固定数量再发”。

**发送路径为什么也可能看到 softirq？**

- TCP timer、重传、ACK 处理等可能在 softirq 上下文推进发送；
- qdisc 调度可能由 `NET_TX_SOFTIRQ` 继续执行；
- 驱动 TX completion 常在 NAPI poll 中清理，因此可能运行于 `NET_RX_SOFTIRQ`；
- 进程调用 `sendmsg()` 的正常快速路径也可以直接推进到 driver。

### 5.3 sk_buff 必会点

`sk_buff` 是报文元数据描述符，不等于一块连续的完整报文。

```text
struct sk_buff
  ├─ protocol/route/socket/device metadata
  ├─ header offsets
  ├─ linear head buffer
  ├─ page frags[]
  └─ optional frag_list
```

必须能解释：

- `len` 是总长度，`data_len` 是非线性数据长度；
- `skb_headlen(skb) = len - data_len`；
- `head/data/tail/end` 描述线性 head buffer；
- `skb_clone()` 复制描述符并共享数据；
- `skb_copy()` 复制数据，成本更高；
- 修改共享 head 前需要 COW，例如 `skb_cow_head()`；
- GSO 让一个大 skb 延迟分段，GRO 在 RX 合并报文；
- checksum offload 依赖 `ip_summed` 等元数据与驱动 descriptor 正确配合。

延伸阅读：[[ch1-skbuff|sk_buff 与数据包生命周期]]。

### 5.4 RSS、RPS、RFS、XPS

| 机制 | 执行位置 | 作用                                      |
| ---- | -------- | ----------------------------------------- |
| RSS  | 网卡硬件 | 根据 flow hash 将 RX 流量分到多个硬件队列 |
| RPS  | 内核软件 | 将 RX 协议栈处理转移到其他 CPU            |
| RFS  | 内核软件 | 尽量让 flow 在消费该 socket 的 CPU 上处理 |
| XPS  | 内核软件 | 根据 CPU 或 RX queue 选择 TX queue        |

典型权衡：

- RSS 能并行，但跨 NUMA 或队列分布不均会导致性能下降；
- RPS 增加 CPU 间排队和 IPI 成本，不能无脑开启；
- flow pinning 有利于 cache locality，但热点流仍可能压垮单核；
- IRQ affinity、应用线程绑核、内存 NUMA 和队列选择要一起设计。

### 5.5 GRO、GSO、TSO、LRO

| 机制 | 方向 | 位置         | 核心作用                           |
| ---- | ---- | ------------ | ---------------------------------- |
| GRO  | RX   | 内核软件     | 将可合并报文聚合后再进入协议栈     |
| LRO  | RX   | 硬件/驱动    | 更激进的接收聚合，可能破坏转发语义 |
| GSO  | TX   | 内核软件语义 | 让大 skb 延迟到较后阶段分段        |
| TSO  | TX   | 网卡硬件     | 网卡根据 descriptor 完成 TCP 分段  |

不要说“GRO 对应硬件 RO”。准确说法是：GRO 是软件通用接收聚合，
硬件或驱动侧相近机制是 LRO，但二者语义和适用范围不完全相同。

### 5.6 网络性能故障题

现象：吞吐上不去，单个 CPU 的 `ksoftirqd` 很高。

回答框架：

1. 确认是单 flow 上限还是多 flow 也不扩展；
2. 查看 IRQ、队列和 CPU 分布；
3. 检查 RSS indirection table、IRQ affinity、RPS/XPS；
4. 查看 softnet drop、驱动丢包、ring no-buffer；
5. 用 perf 看 CPU 消耗在 driver、GRO、协议栈、Netfilter 还是 socket copy；
6. 检查应用线程和网卡是否跨 NUMA；
7. 调整后用相同流量模型复测吞吐、P99、drop 和 CPU/packet。

命令示例：

```bash
cat /proc/interrupts
cat /proc/net/softnet_stat
ethtool -S eth0
ethtool -l eth0
ethtool -x eth0
ethtool -k eth0
perf top -a
perf record -a -g -- sleep 30
numactl --hardware
```

---

## 6. 调度、进程与并发

### 6.1 调度必须建立的概念

```text
task_struct
  ├─ scheduling class
  ├─ state
  ├─ priority / policy
  ├─ CPU affinity
  ├─ mm / files / namespaces
  └─ runtime accounting
```

Linux 按调度类组织策略，常见优先级关系可概括为：

```text
stop → deadline → real-time → fair → idle
```

普通任务主要由 fair class 管理。讨论 CFS 或较新的 EEVDF 实现时，避免死背某个版本的
内部字段；面试重点通常是公平性、延迟、抢占、唤醒和 CPU 选择。

### 6.2 进程切换发生了什么

上下文切换不只是保存寄存器：

- 保存和恢复 CPU 执行上下文；
- 切换地址空间时可能影响 TLB；
- 调度器更新运行时间和 runqueue；
- 新任务的代码、数据可能不在 cache 中；
- 跨 CPU 唤醒可能产生 IPI；
- 跨 NUMA 运行会增加远端内存访问。

因此 `context-switches` 高不一定有问题，要结合任务类型、延迟和 cache miss 判断。

### 6.3 中断、softirq、workqueue

| 上下文        | 是否可睡眠 | 典型用途                             |
| ------------- | ---------: | ------------------------------------ |
| hardirq       |         否 | 快速确认设备事件、调度后续工作       |
| softirq       |         否 | 网络收发、timer 等高频延后处理       |
| tasklet       |         否 | 基于 softirq 的传统延后机制          |
| workqueue     |         是 | 需要进程上下文、可能阻塞的异步工作   |
| kernel thread |         是 | 长期运行或需要独立调度实体的后台任务 |

“不能睡眠”的实质是当前上下文没有可安全阻塞并恢复的普通任务语义，或者持有不允许
调度的锁/处于原子上下文。不能只背“中断里不能 sleep”，还要知道为什么。

### 6.4 spinlock、mutex、RCU

- `spinlock`：短临界区，不能睡眠；竞争时消耗 CPU；
- `mutex`：允许阻塞，适合进程上下文较长临界区；
- `rwlock/rwsem`：读写不对称，但写竞争和 cache line 抖动可能明显；
- RCU：读侧极轻，更新侧负责发布新版本并等待 grace period；
- per-CPU data：通过拆分共享状态减少 cache line 竞争。

回答锁问题时一定补充：

1. 运行上下文能否睡眠；
2. 临界区长度；
3. 读写比例；
4. 中断是否也访问该数据；
5. 数据生命周期如何保证；
6. 是否存在锁顺序或优先级反转问题。

---

## 7. 内存管理

### 7.1 从虚拟地址到物理页

```text
process virtual address
  → VMA permission check
  → page table walk
  → TLB lookup/miss
  → physical page
  → memory controller / NUMA node
```

缺页异常不等于错误：

- minor fault：不需要从磁盘读取，例如页已在 page cache；
- major fault：通常需要 I/O；
- anonymous page 首次写入可能触发分配；
- fork 后写内存可能触发 COW；
- 文件映射访问可能通过 page cache 建页表。

### 7.2 伙伴系统和 slab

```text
physical pages
  → buddy allocator: power-of-two page blocks
  → SLUB/SLAB allocator: frequently used kernel objects
  → subsystem objects: task_struct, inode, dentry, skb...
```

伙伴系统解决页级连续块分配，slab 类分配器解决小对象频繁分配、构造和缓存问题。

常见追问：

**系统还有很多内存，为什么高阶页分配失败？**

总空闲内存不等于存在足够大的物理连续块。长期运行、不可迁移页和碎片化可能使高阶分配
失败。需要查看 zone、order、compaction 和迁移类型，而不是只看 `free`。

### 7.3 page cache 与脏页

文件读写通常经过 page cache：

```text
read()
  → page cache hit: copy to userspace
  → miss: filesystem submits I/O, page becomes uptodate

write()
  → modify page cache
  → mark dirty
  → writeback
  → block layer / driver / storage
```

`write()` 返回不代表数据已经持久化。持久性还涉及 `fsync()`、文件系统日志、设备缓存和
掉电保护。

### 7.4 OOM 的回答框架

OOM 不是“内存用完”四个字：

1. 哪个 memcg 或系统级分配失败；
2. 分配的 order 和 GFP flags 是什么；
3. 是否允许 reclaim、compaction 或 I/O；
4. anonymous、page cache、slab、pagetable 谁占用；
5. 是否有不可回收内存或泄漏；
6. OOM killer 如何选择 victim；
7. 是否存在 NUMA node 局部耗尽。

常用信息：

```bash
cat /proc/meminfo
cat /proc/zoneinfo
cat /proc/buddyinfo
slabtop
vmstat 1
numastat
cat /sys/fs/cgroup/<group>/memory.events
```

---

## 8. 文件系统与块 I/O：至少能讲通主链路

### 8.1 VFS 抽象

核心对象：

| 对象       | 含义                                   |
| ---------- | -------------------------------------- |
| superblock | 已挂载文件系统实例                     |
| inode      | 文件元数据和操作集合                   |
| dentry     | 路径分量与 inode 的关联缓存            |
| file       | 一次打开文件的状态，如 offset 和 flags |

`open()` 主要解决路径查找和权限，`read()`/`write()` 通过 `struct file` 进入具体文件系统。

### 8.2 块 I/O 主链路

```text
filesystem / page cache
  → bio
  → block multi-queue
  → I/O scheduler, if used
  → device driver
  → hardware submission queue
  → completion
```

`blk-mq` 将软件提交队列和硬件队列结合，减少传统单队列锁竞争，更适合 NVMe 等多队列设备。

### 8.3 延迟升高如何定位

先区分：

- 应用排队；
- 文件系统锁或日志；
- writeback；
- block queue；
- 驱动和设备；
- 云盘/网络存储后端。

工具组合：

```bash
iostat -xz 1
pidstat -d 1
vmstat 1
perf record -g -p <pid>
bpftrace -e 'tracepoint:block:block_rq_issue { @[comm] = count(); }'
```

不要把 `%util=100%` 机械解释为设备已经达到吞吐极限。并行设备、统计口径和 I/O 模型
都会影响含义。

---

## 9. 内核调试与性能工具

### 9.1 先选工具，不要先敲命令

| 问题               | 首选工具      | 原因                               |
| ------------------ | ------------- | ---------------------------------- |
| CPU 花在哪里       | perf          | 采样开销低，可看调用栈和硬件计数器 |
| 某个函数何时调用   | ftrace        | 内核原生函数与事件跟踪             |
| 临时按条件聚合事件 | bpftrace      | 动态、安全地编写观测逻辑           |
| 线上长期可观测程序 | libbpf/CO-RE  | 可维护、可版本适配的 eBPF 工程     |
| 内核崩溃后的状态   | kdump + crash | 基于 vmcore 离线分析               |
| 内存错误           | KASAN/KFENCE  | 检测越界、UAF 等问题               |
| 锁问题             | lockdep       | 动态检查锁依赖                     |
| 内核日志与调用栈   | dmesg / SysRq | 获取第一现场                       |

### 9.2 perf

```bash
# 系统级热点
perf top -a

# 记录调用图
perf record -a -g -- sleep 30
perf report

# 观察指定进程
perf stat -p <pid> -e cycles,instructions,cache-misses,context-switches -- sleep 10

# 调度延迟
perf sched record -- sleep 10
perf sched latency
```

必须能解释：

- sampling 与 counting 的区别；
- frame pointer、DWARF、LBR 等调用栈方式的权衡；
- `cycles` 高不等于函数有问题，要看占比和业务工作量；
- 符号缺失、编译优化、内联会影响栈；
- `perf stat` 的 IPC、cache miss 需要结合 workload 解读。

### 9.3 ftrace

ftrace 适合回答“内核到底走了哪条路径”和“某函数耗时是否异常”：

```bash
mount -t tracefs nodev /sys/kernel/tracing
cd /sys/kernel/tracing

echo function_graph > current_tracer
echo '__netif_receive_skb_core' > set_graph_function
echo 1 > tracing_on
sleep 3
echo 0 > tracing_on
cat trace
```

生产环境使用前需要限制函数、PID、CPU 和 buffer，避免高频函数造成巨大开销。

### 9.4 bpftrace

```bash
# 按进程统计系统调用
bpftrace -e 'tracepoint:raw_syscalls:sys_enter { @[comm] = count(); }'

# 统计调度延迟分布的思路
bpftrace -e '
tracepoint:sched:sched_wakeup { @ts[args->pid] = nsecs; }
tracepoint:sched:sched_switch /@ts[args->next_pid]/ {
  @lat_us = hist((nsecs - @ts[args->next_pid]) / 1000);
  delete(@ts[args->next_pid]);
}'

# 观察 block I/O 延迟需要用 request 指针关联 issue/complete
```

面试时应主动说明：

- kprobe 依赖内核实现细节，tracepoint 更稳定；
- 高频 probe 要控制聚合键数量和输出频率；
- eBPF map 也消耗内存，不能无限记录每个 PID 或指针；
- 观测程序本身必须评估 overhead。

### 9.5 kdump 与 crash

流程：

```text
production kernel crashes
  → kexec enters capture kernel
  → capture kernel writes /proc/vmcore
  → crash loads vmcore + matching vmlinux
  → inspect panic task, stack, registers and kernel objects
```

常见 crash 命令：

```text
sys       系统和 panic 概况
log       内核日志
bt        当前任务调用栈
bt -a     所有 CPU 调用栈
ps        任务列表
runq      runqueue
kmem      内存状态
files     进程文件
net       网络信息
struct    解释结构体
```

回答崩溃题时先强调版本匹配：分析所用 `vmlinux`、debuginfo 和 vmcore 必须匹配。

### 9.6 一套标准故障闭环

```text
定义现象和 SLO
  → 缩小时间、机器、进程和请求范围
  → 区分 CPU / memory / scheduler / lock / I/O / network
  → 用低开销指标建立假设
  → 用 tracing 或 profiling 验证
  → 找到机制级根因
  → 修改并做 A/B
  → 检查吞吐、P50/P99、错误率和资源成本
  → 增加监控与回归测试
```

面试官看重的不是一次猜对，而是每一步都有证据和退出条件。

---

## 10. namespace、cgroup、seccomp、capabilities

### 10.1 四者分别解决什么

```text
namespace    看见什么
cgroup       能用多少、如何统计和控制
capabilities 能做哪些传统特权操作
seccomp      能调用哪些系统调用
LSM          对内核对象执行什么安全策略
```

它们互相补充，不能替代：

- namespace 不是资源限制；
- cgroup 不是安全边界；
- seccomp 只看系统调用及有限参数，不理解完整业务语义；
- 去掉 capabilities 不能消除所有内核攻击面；
- 容器共享宿主机内核，隔离强度通常弱于独立虚拟机。

### 10.2 namespace

常见 namespace：

| 类型    | 隔离内容                       |
| ------- | ------------------------------ |
| mount   | 挂载点视图                     |
| PID     | 进程 ID 层次                   |
| network | 网卡、路由、端口、Netfilter 等 |
| user    | UID/GID 映射与 capability 语义 |
| UTS     | hostname/domainname            |
| IPC     | SysV IPC、POSIX message queue  |
| cgroup  | cgroup 路径视图                |
| time    | 部分系统时钟偏移               |

`chroot` 只改变路径解析根目录，不等于容器隔离。

### 10.3 cgroup v2

cgroup v2 提供统一层次结构。重点理解：

- CPU：`cpu.max`、`cpu.weight`、CPU pressure；
- memory：`memory.current`、`memory.high`、`memory.max`、`memory.events`；
- I/O：`io.max`、`io.weight`；
- pids：`pids.max`；
- PSI：CPU、memory、I/O 的资源压力和等待时间。

`memory.high` 通常用于节流和回收压力，`memory.max` 是硬上限。只配置硬上限容易在突发时
直接进入 memcg OOM，缺乏提前反馈。

### 10.4 seccomp

seccomp filter 使用 cBPF 表达系统调用过滤策略，可执行：

- allow；
- deny 并返回 errno；
- kill process/thread；
- trap；
- log；
- user notification。

局限：

- TOCTOU：用户指针内容可能在检查后变化；
- 复杂策略不适合只依赖 syscall number；
- 新系统调用和架构 ABI 需要维护；
- 允许某个系统调用不代表其所有参数组合安全。

### 10.5 capabilities

传统 root 权限被拆分为多个 capability，例如：

- `CAP_NET_ADMIN`：网络配置；
- `CAP_SYS_ADMIN`：范围过大，应谨慎授予；
- `CAP_BPF`：部分 BPF 操作；
- `CAP_PERFMON`：性能监控能力；
- `CAP_SYS_PTRACE`：ptrace 等；
- `CAP_SYS_RESOURCE`：资源限制相关操作。

容器安全的基本原则是默认 drop，按需增加，而不是直接 privileged。

### 10.6 容器逃逸防护的分层回答

```text
1. 减少权限
   rootless/user namespace/drop capabilities/no-new-privileges

2. 减少攻击面
   seccomp/只读文件系统/设备白名单

3. 内核对象访问控制
   SELinux/AppArmor/其他 LSM

4. 资源隔离
   cgroup limits + PSI + quota

5. 运行时检测
   eBPF/LSM hooks/audit/行为基线

6. 更强边界
   microVM/sandboxed runtime/独立内核
```

不能承诺某一种机制可以“彻底防逃逸”。工程目标是降低攻击面、提高利用难度、限制影响面，
并提升发现和响应能力。

---

## 11. eBPF 加分项

### 11.1 eBPF 执行模型

```text
userspace loader
  → load BPF program
  → verifier checks safety
  → JIT or interpreter
  → attach to hook
  → event triggers program
  → maps exchange state/data
  → ring buffer exports events
```

必须掌握：

- program type 决定可用上下文和 helper；
- verifier 通过抽象解释检查边界、指针类型和控制流；
- map 提供内核/用户态或程序间共享状态；
- tail call 可以构建程序链，但有调用限制；
- BTF 描述内核类型，CO-RE 根据字段信息做重定位；
- eBPF 不是任意内核 C，程序受 hook、helper 和 verifier 限制。

### 11.2 常见 hook 选择

| 场景                | 常见 hook                        |
| ------------------- | -------------------------------- |
| 系统调用观测        | tracepoint/raw tracepoint/kprobe |
| 函数级性能分析      | fentry/fexit/kprobe              |
| 网络早期处理        | XDP                              |
| socket/容器网络策略 | cgroup BPF、TC                   |
| 安全审计与策略      | LSM BPF、tracepoint              |
| 用户态函数跟踪      | uprobe/uretprobe                 |

选择原则：

1. 能用稳定 tracepoint，就不要首先依赖内部函数名；
2. 需要返回值或低开销函数挂接时考虑 fentry/fexit；
3. 需要在 skb 创建前高速处理报文时考虑 XDP；
4. 需要携带 socket/cgroup 语义时选择相应 cgroup hook；
5. 真正阻断安全行为时，优先选择具有明确授权语义的 LSM hook。

### 11.3 eBPF 安全监控设计题

题目：设计一个容器异常进程执行监控系统。

回答框架：

```text
exec/sched/LSM hook
  → collect pid/tgid, uid, cgroup id, executable, parent
  → filter early in kernel
  → send compact event through ring buffer
  → userspace enriches container/pod metadata
  → rule/behavior engine
  → alert and evidence storage
```

必须补充：

- PID 会复用，事件标识要考虑启动时间或其他唯一信息；
- namespace 内 PID 和宿主机 PID 不是同一视图；
- 命令行和环境变量可能包含敏感信息，采集需最小化；
- 高频事件要在内核侧过滤，并监控 ring buffer 丢失；
- 路径解析、容器元数据关联和策略更新应尽量放在用户态；
- 内核版本适配优先使用 BTF/CO-RE；
- 阻断模式要考虑 fail-open/fail-closed 和控制面失效。

### 11.4 XDP 与 TC 的区别

| 维度         | XDP                           | TC BPF                        |
| ------------ | ----------------------------- | ----------------------------- |
| 位置         | 驱动 RX 早期                  | skb 路径 ingress/egress       |
| 数据对象     | `xdp_buff`                    | `sk_buff`                     |
| 性能         | 更高                          | 通常低于 XDP                  |
| 协议栈元数据 | 较少                          | 更丰富                        |
| 常见用途     | DDoS 丢弃、L2/L3 转发、AF_XDP | QoS、策略、封装、复杂流量控制 |

不存在“XDP 永远比 TC 好”。hook 越早，性能通常越高，但可用语义越少。

---

## 12. CPU、NUMA、PCIe、DMA 与 GPU

### 12.1 CPU cache 与伪共享

多核并发性能问题经常不是算法复杂度，而是 cache coherence：

```text
CPU 0 writes cache line
  → ownership transfer / invalidate
  → CPU 1 reads or writes same line
  → cache line ping-pong
```

即使两个线程修改不同变量，只要变量落在同一 cache line，也可能发生 false sharing。
可通过 per-CPU data、分片、批处理和合理 padding 缓解，但 padding 会增加内存占用。

### 12.2 NUMA

NUMA 优化不是简单“绑核”：

```text
CPU affinity
  + memory placement
  + NIC/GPU PCIe locality
  + IRQ affinity
  + worker and queue ownership
```

典型问题：

- 线程在 node 0，内存在 node 1；
- NIC 接在 node 1，但 IRQ 和应用在 node 0；
- GPU 在某 PCIe root complex 下，数据预处理线程在远端 node；
- 自动 NUMA balancing 导致页迁移和抖动；
- 跨 socket 锁和共享队列产生 coherence 流量。

常用命令：

```bash
lscpu
numactl --hardware
numastat -p <pid>
lspci -tv
cat /sys/class/net/eth0/device/numa_node
cat /sys/bus/pci/devices/0000:xx:yy.z/numa_node
```

### 12.3 PCIe 与 DMA

驱动发送数据的大致过程：

1. CPU 准备 descriptor；
2. DMA API 建立设备可访问的地址映射；
3. 写 doorbell 通知设备；
4. 设备通过 PCIe 读取 descriptor 和数据；
5. 设备完成后写 completion 或触发中断；
6. 驱动回收 descriptor、解除映射并释放对象。

需要理解：

- DMA 地址不一定等于 CPU 物理地址，IOMMU 可以做地址转换和隔离；
- coherent DMA 和 streaming DMA 的同步语义不同；
- descriptor ring 和 doorbell batching 影响吞吐；
- PCIe 带宽、lane 数、代际和拓扑会形成上限；
- small I/O 更容易受事务和同步开销影响，而非纯带宽限制。

### 12.4 AI/GPU 集群如何回答

没有 GPU 内核开发经验时，不要硬装 CUDA 专家。可以从 OS 视角回答：

```text
AI job performance
  ├─ CPU preprocessing and dataloader
  ├─ page cache / local NVMe / network storage
  ├─ pinned memory and DMA
  ├─ PCIe / NVLink topology
  ├─ GPU driver and runtime
  ├─ RDMA / RoCE / collective communication
  ├─ NUMA and IRQ placement
  └─ cgroup / scheduler / container isolation
```

可迁移的排查思路：

1. 先判断 GPU 是计算忙、通信等待还是数据饥饿；
2. 将 step time 分为 compute、collective、input 和 checkpoint；
3. 对照 GPU、CPU、网络、存储时间线；
4. 检查 GPU/NIC/CPU NUMA 与 PCIe 拓扑；
5. 检查容器资源限制和 CPU throttling；
6. 用可重复 workload 做拓扑和参数 A/B。

---

## 13. 高频面试题与回答要点

### 13.1 `fork()` 和 `exec()` 分别发生什么

`fork()` 创建新的任务和进程资源视图，地址空间通常通过页表复制加 COW 共享物理页；
`exec()` 不创建新 PID，而是用新程序映像替换当前进程的地址空间和执行上下文。

追问方向：

- `vfork()`；
- 文件描述符继承；
- 多线程进程 fork 的约束；
- COW page fault；
- PID namespace 中的 PID。

### 13.2 系统调用为什么比普通函数调用贵

涉及用户态到内核态的特权级切换、寄存器和入口状态处理、安全检查，以及可能的调度和
cache/TLB 影响。现代 CPU 的缓解措施也可能增加路径成本。但不能简单说“一次系统调用
一定触发上下文切换”，因为它通常仍由同一个 task 执行。

### 13.3 `malloc()` 后内存立刻分配了吗

用户态 allocator 可能从已有 arena 返回，也可能通过 `brk()`/`mmap()` 扩展虚拟地址空间；
物理页通常在首次访问触发缺页后按需分配。大页、预触页、锁页和 allocator 策略会改变行为。

### 13.4 load average 高说明 CPU 忙吗

不一定。Linux load average 统计可运行任务和部分不可中断睡眠任务。高 load 可能来自
CPU 竞争，也可能来自大量 D 状态 I/O 等待。应结合 CPU utilization、runqueue、PSI、
任务状态和 I/O 指标判断。

### 13.5 CPU 使用率不高但延迟很高，怎么查

检查：

- 单线程/单核瓶颈被总体 CPU 平均值掩盖；
- 调度等待和 CPU throttling；
- 锁、futex 和条件变量；
- I/O、page fault、reclaim；
- 网络重传和队列；
- NUMA 远端访问；
- stop-the-world 或 runtime pause。

使用 off-CPU profiling、调度 trace 和请求级时间线，而不只看 on-CPU flame graph。

### 13.6 softirq 很高怎么办

先看是哪类 softirq，再看每 CPU 分布和处理函数。网络场景检查流量模型、IRQ/RSS、
NAPI budget、GRO、丢包、应用消费速度、Netfilter 和 NUMA。`ksoftirqd` 高是现象，
直接提高线程优先级通常不是根治。

### 13.7 RCU 为什么读侧可以不加普通锁

读者在受保护的读侧临界区访问已发布版本；更新者创建新版本并原子发布，旧版本必须等
所有可能引用它的旧读者经过 grace period 后才能回收。重点是“延迟回收”，不是没有同步。

### 13.8 mmap 为什么可能比 read/write 快

它可以减少显式用户/内核数据复制和系统调用次数，并允许按页懒加载；但 page fault、
页表、TLB shootdown、写回和随机访问仍有成本。小文件、顺序读取或复杂一致性场景下，
`mmap()` 不一定更快。

### 13.9 cgroup 限制 CPU 后为什么延迟出现周期性尖峰

可能触发 CFS bandwidth quota：任务在周期内用完 quota 后被 throttle，等下一个 period
恢复。检查 `cpu.stat` 中 throttling 指标、`cpu.max`、线程并行度和延迟尖峰周期。

### 13.10 容器和虚拟机的安全边界区别

容器通过 namespace、cgroup、capabilities、seccomp、LSM 等共享宿主内核；
传统 VM 有独立 guest kernel，通过 hypervisor 和硬件虚拟化隔离。容器启动和密度更优，
但宿主内核漏洞可能影响多个容器；microVM 位于两者之间。

### 13.11 eBPF verifier 为什么会拒绝看似正确的程序

verifier 必须证明所有可能控制流都安全。常见原因包括：

- 指针边界无法证明；
- map value 指针生命周期不合法；
- 未初始化栈数据；
- 循环边界无法确定；
- helper 调用后指针失效；
- 不同分支合并后类型信息不足。

解决方法是让控制流和边界更容易被静态证明，而不只是“代码运行时不会出错”。

### 13.12 如何定位内核内存泄漏

1. 判断增长的是 slab、page cache、pagetable、网络 buffer 还是驱动页；
2. 查看 slab cache 和对象数量；
3. 使用 `kmemleak`、page owner、slab tracing 或 eBPF 跟踪分配/释放；
4. 按调用栈和对象生命周期聚合；
5. 设计触发/停止 workload，验证对象是否应回收；
6. 修复后做长稳回归，而非只跑短测。

---

## 14. 系统设计题

### 14.1 设计容器安全事件回溯系统

目标不是“把所有系统调用都存下来”。那会产生巨大开销和噪声。应先定义可回答的问题：

- 哪个容器中的哪个进程；
- 在什么时间；
- 执行了什么高风险动作；
- 动作前后的父子进程和资源关系；
- 是否可以关联网络、文件和凭据变化；
- 证据是否足以复盘而不会泄露大量敏感数据。

建议架构：

```text
Kernel sensors
  ├─ sched/exec/exit
  ├─ LSM file/socket/cred hooks
  ├─ selected network events
  └─ cgroup and namespace identity
          │
          ▼
Per-CPU maps + ring buffer
          │
          ▼
Node agent
  ├─ metadata enrichment
  ├─ ordering and deduplication
  ├─ local durable buffer
  └─ backpressure/drop metrics
          │
          ▼
Event storage + correlation + query
```

设计权衡：

- 全量事件与关键状态变更；
- 事件顺序与多 CPU 时钟；
- PID 复用和容器生命周期；
- 内核侧过滤与策略热更新；
- 控制面不可用时 fail-open 还是 fail-closed；
- agent 被攻击后的证据可信度；
- 数据保留周期、脱敏和访问审计；
- 性能预算和丢事件可见性。

### 14.2 设计确定性回放

严格确定性回放很难，因为需要控制所有非确定性输入：

- 系统调用结果；
- 信号与调度时序；
- 网络和文件输入；
- 时间、随机数和硬件事件；
- 多线程内存竞争；
- 外部设备和共享服务。

可按目标降低难度：

| 目标           | 可行方法                                            |
| -------------- | --------------------------------------------------- |
| 安全事件复盘   | 记录高价值状态转换和因果关系                        |
| 单进程调试     | ptrace/seccomp/user notification + syscall 结果记录 |
| VM 级回放      | hypervisor 记录外部输入和虚拟 CPU 事件              |
| 分布式请求回放 | trace ID、请求输入、配置与依赖响应快照              |

面试中应先问清“确定性”的边界，而不是直接承诺实现任意多线程系统的完全回放。

### 14.3 设计 AI 节点健康诊断 Agent

```text
Collectors
  ├─ CPU/memory/PSI
  ├─ GPU metrics and errors
  ├─ NIC/RDMA counters
  ├─ NVMe/filesystem
  ├─ kernel logs and eBPF events
  └─ topology/configuration
          │
          ▼
Evidence normalization
          │
          ▼
Rule engine + anomaly detection
          │
          ▼
LLM explanation and tool orchestration
          │
          ▼
human approval / bounded remediation
```

LLM 不应直接替代底层测量，也不应默认拥有无限制 root 命令权限。更合理的角色是：

- 将症状映射为排查计划；
- 调用白名单、参数受限的诊断工具；
- 汇总证据并解释矛盾；
- 在置信度不足时请求人工确认；
- 对修复动作保留审批、审计和回滚。

---

## 15. 项目经历如何讲

### 15.1 STAR 不够，还要有技术证据

建议使用：

```text
Context
  → Symptom and impact
  → Constraints
  → Hypotheses
  → Evidence
  → Root cause
  → Change
  → Verification
  → Follow-up
```

参考表达：

> 线上某类请求 P99 从 8 ms 升到 40 ms，但平均 CPU 只有 45%。我先排除了下游依赖，
> 然后按 CPU、调度、锁和 I/O 分层检查。调度 trace 显示工作线程周期性被 cgroup
> throttle，尖峰周期与 `cpu.max` period 一致。进一步发现并行线程数按宿主 CPU 配置，
> 但容器 quota 只有 4 核。我们调整了线程池 sizing，并重新设计 CPU request/limit。
> 修复后在相同压测模型下 P99 恢复到 10 ms 内，throttled time 明显下降，同时加入
> `cpu.stat` 和 PSI 告警，避免再次只看平均 CPU。

### 15.2 面试官会追问什么

- 你本人具体做了什么；
- 为什么先用这个工具；
- 还有哪些假设，被什么证据排除；
- 指标如何采集，测试流量是否可信；
- 修改是否可能牺牲其他指标；
- 如何证明不是偶然波动；
- 如何灰度、回滚；
- 最后沉淀了什么机制。

### 15.3 没做过加分项怎么回答

错误回答：

> 这个没做过，不了解。

也不要伪造经验。推荐三段式：

> 我没有在生产环境独立负责过 GPU 集群内核适配。与它直接相关的经验是 NUMA、
> PCIe、DMA 和高性能网络定位。面对 GPU 利用率低的问题，我会先把 step time 拆成
> 计算、通信、数据输入和 checkpoint，再结合 GPU/NIC/CPU 拓扑验证是否存在跨 NUMA、
> PCIe 拥塞或 CPU throttling。这个方法论可以迁移，但 GPU driver 和 collective
> library 的具体实现细节我会明确作为需要补齐的部分。

这比背几个 CUDA 名词更可信。

---

## 16. C 语言和内核编码高频点

### 16.1 必须复习

- 指针、数组、函数指针；
- struct layout、alignment、padding；
- bit operation 和 endian；
- `volatile` 不提供线程同步；
- C11 memory ordering 与编译器/CPU 重排；
- 原子操作、barrier、READ_ONCE/WRITE_ONCE；
- intrusive list、container_of；
- 引用计数和对象生命周期；
- 错误码、清理路径和 goto；
- 整数溢出、符号扩展、长度校验；
- UAF、double free、越界和并发竞态。

### 16.2 内存屏障不要乱背

回答顺序：

1. 先说明要保护的数据发布协议；
2. 区分编译器重排和 CPU 重排；
3. 说明单 CPU 顺序不等于其他 CPU 可见顺序；
4. 优先使用锁、原子 API 或 release/acquire 语义；
5. 只有在无锁协议中才直接选择具体 barrier。

孤立地说“这里加一个 `smp_mb()` 就好了”通常是不可靠的。

### 16.3 代码题检查清单

```text
输入是否合法
  → 长度是否溢出
  → 分配是否失败
  → 部分初始化如何清理
  → 谁拥有对象
  → 并发读写如何同步
  → 错误码是否保留
  → 日志是否泄露敏感信息
```

---

## 17. 上机实操清单

面试前至少亲手执行一次，不要只看文章。

### 17.1 性能基线

```bash
uptime
vmstat 1
mpstat -P ALL 1
pidstat -wru -p <pid> 1
perf stat -p <pid> -- sleep 10
perf record -g -p <pid> -- sleep 10
```

### 17.2 网络

```bash
ss -tinmp
ip -s link
ethtool -S eth0
ethtool -k eth0
cat /proc/net/softnet_stat
cat /proc/interrupts
```

### 17.3 内存和 NUMA

```bash
free -h
cat /proc/meminfo
slabtop
numactl --hardware
numastat -p <pid>
cat /proc/<pid>/smaps_rollup
```

### 17.4 cgroup v2

```bash
mount | grep cgroup2
cat /proc/<pid>/cgroup
cat /sys/fs/cgroup/<group>/cpu.stat
cat /sys/fs/cgroup/<group>/memory.events
cat /proc/pressure/cpu
cat /proc/pressure/memory
cat /proc/pressure/io
```

### 17.5 tracing

完成三个小实验：

1. 用 perf 找一个 CPU-bound 程序的热点；
2. 用 bpftrace 按进程统计系统调用；
3. 用 ftrace function graph 跟踪一个低频内核函数。

实验后能够回答：

- 采样是否改变 workload；
- 数据是否丢失；
- 调用栈是否完整；
- 如何缩小到某个 PID/CPU/cgroup；
- 如何在生产环境控制风险。

---

## 18. 模拟面试题单

### 第一轮：基础与主线

1. 从 `send()` 到网卡发包，完整讲一次。
2. NAPI 为什么能缓解中断风暴？
3. `sk_buff` clone 后修改 header 要注意什么？
4. softirq 和 workqueue 的区别是什么？
5. 一次进程上下文切换有哪些成本？
6. minor page fault 和 major page fault 有什么区别？
7. page cache 和 buffer cache 是什么关系？
8. blk-mq 为什么适合 NVMe？
9. RCU 如何保证对象不会过早释放？
10. load average 高但 CPU idle 很高，可能是什么原因？

### 第二轮：工具与故障

1. 线上 CPU 突然升高，你如何选择 perf、ftrace 和 eBPF？
2. CPU 不高但 P99 很高，如何定位？
3. 内核 panic 后如何收集和分析 vmcore？
4. 如何定位内核内存泄漏？
5. 单个 `ksoftirqd` 占满一核如何排查？
6. 网卡没有丢包但应用收包丢失，可能在哪些层？
7. 容器周期性延迟尖峰如何检查 CPU throttling？
8. NUMA 远端访问如何发现和修复？
9. 如何证明性能优化没有把成本转移到其他地方？
10. tracing 工具自身开销如何评估？

### 第三轮：安全、eBPF 与设计

1. namespace 和 cgroup 为什么不能互相替代？
2. seccomp 能否阻止所有容器逃逸？
3. capabilities 相比 root 有什么价值和局限？
4. eBPF verifier 在证明什么？
5. tracepoint、kprobe、fentry 如何选择？
6. 设计一个低开销容器 exec 监控系统。
7. 设计一个系统调用过滤与审计平台。
8. 如何保证安全事件不因 ring buffer 满而静默丢失？
9. 如何设计状态快照和执行轨迹回溯？
10. LLM Agent 执行系统命令时如何做权限和审计控制？

---

## 19. 反向提问

选择三到五个，不要全部问：

1. 团队当前最重要的内核方向是性能、稳定性、安全，还是 AI 基础设施适配？
2. 这个岗位入职前三个月最希望解决的具体问题是什么？
3. 当前主要维护上游内核、发行版内核，还是内部长期支持分支？
4. 内核改动如何做测试、灰度、回滚和线上观测？
5. eBPF 主要用于观测还是策略执行？内核版本和 BTF 覆盖情况如何？
6. GPU/NIC/存储问题中，团队与硬件、驱动、平台团队如何划分责任边界？
7. 是否有稳定的性能基准、故障注入和长稳测试平台？
8. 团队如何推动补丁进入上游或维护内部 patch set？

好的反向提问能验证岗位是否真的做内核工程，而不只是运维和问题转发。

---

## 20. 面试前最后一小时

### 必须能脱稿回答

- 90 秒自我介绍；
- 两个项目闭环；
- 一个内核子系统的端到端链路；
- 一个性能故障排查案例；
- namespace/cgroup/seccomp/capabilities 的区别；
- perf/ftrace/bpftrace/crash 的选择；
- NUMA、PCIe、DMA 对性能的影响；
- 没做过 GPU 或安全回放时，如何诚实表达可迁移能力。

### 最后检查

```text
[ ] 项目数据真实，口径说得清
[ ] 能区分事实、推测和待验证项
[ ] 回答先给结论，再讲机制和证据
[ ] 不把版本相关实现说成永恒不变
[ ] 不把容器描述为绝对安全边界
[ ] 不把 eBPF 描述成无开销或万能
[ ] 不会的问题先界定边界，再给排查方法
[ ] 每个优化都能说出副作用和验证指标
```

---

## 21. 一页速记

```text
内核题：
  API → 对象 → 调用链 → 并发 → 硬件 → 观测

性能题：
  现象 → 范围 → 分类 → 假设 → 证据 → 根因 → A/B → 防复发

网络 RX：
  DMA → IRQ → NAPI → NET_RX_SOFTIRQ → GRO → IP/TCP → socket

网络 TX：
  sendmsg → TCP/IP → qdisc → driver → DMA → completion → free

隔离：
  namespace 看见什么
  cgroup 能用多少
  capability 能做什么
  seccomp 能调什么 syscall
  LSM 能否访问内核对象

eBPF：
  hook + program type + verifier + map + BTF/CO-RE + ring buffer

硬件：
  CPU/cache + NUMA placement + PCIe topology + DMA/IOMMU + IRQ/queue

不会的问题：
  明确没做过 → 关联已有经验 → 给出验证路径 → 说明需要补齐的边界
```

面试的核心不是覆盖所有名词，而是让面试官相信：面对陌生的系统问题，你能建立模型、
采集证据、定位根因，并把修复安全地交付到生产环境。
