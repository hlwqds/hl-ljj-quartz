---
title: "DPDK 深度探索 (二十九)：Profiling——dpdk-proc-info、perf、火焰图"
date: 2026-04-09
tags:
  [
    dpdk,
    series,
    profiling,
    perf,
    flamegraph,
    dpdk-proc-info,
    benchmark,
    hotspot,
    latency,
    throughput,
  ]
description: "深入理解 DPDK 性能分析——dpdk-proc-info、perf、火焰图、热点分析、延迟分布、吞吐量瓶颈定位"
---

> [!info] DPDK 深度探索系列 0. [[2026-04-09-dpdk-deep-dive-series-index|全栈学习路径总览]]
> 1-28. 前二十八章已完成 29. **第二十九章：Profiling——dpdk-proc-info、perf、火焰图**

---

## 1. 概述：为什么需要 Profiling

### 1.1 性能优化方法论

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        性能优化方法论                                       │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  错误的做法:                                                               │
│  ──────────                                                                │
│  1. 猜测热点 (基于直觉)                                                   │
│  2. 优化猜测的热点代码                                                     │
│  3. 期望性能提升                                                           │
│                                                                             │
│  问题:                                                                    │
│  - 直觉经常出错                                                           │
│  - 可能优化了不常用的代码                                                  │
│  - 可能引入新问题                                                          │
│  - 无法量化优化效果                                                        │
│                                                                             │
│  ─────────────────────────────────────────────────────────────────────────  │
│                                                                             │
│  正确的做法:                                                               │
│  ───────────                                                                │
│                                                                             │
│  1. 测量 (Measure)                                                        │
│     - 使用 profiling 工具获取真实数据                                       │
│     - 确认热点位置和耗时                                                   │
│                                                                             │
│  2. 分析 (Analyze)                                                         │
│     - 理解瓶颈原因                                                         │
│     - 区分 CPU bound / Memory bound / I/O bound                          │
│                                                                             │
│  3. 优化 (Optimize)                                                        │
│     - 针对具体瓶颈采取行动                                                 │
│     - 每次只改一处                                                         │
│                                                                             │
│  4. 验证 (Verify)                                                         │
│     - 重新测量，确认优化效果                                               │
│     - 确认没有引入回归                                                     │
│                                                                             │
│  循环往复，直到达到性能目标                                                │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 1.2 性能指标

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        关键性能指标 (KPI)                                   │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  吞吐量指标:                                                              │
│  ──────────                                                                │
│  - Packets Per Second (PPS): 包处理速率                                    │
│  - Bits Per Second (BPS): 比特处理速率                                     │
│  - Transactions Per Second (TPS): 事务处理速率                              │
│  - Operations Per Second (OPS): 操作处理速率                              │
│                                                                             │
│  延迟指标:                                                                │
│  ────────                                                                  │
│  - 平均延迟 (Mean Latency): 所有延迟的算术平均                             │
│  - P50/P90/P95/P99 延迟: 百分位数                                          │
│  - 最大延迟 (Max Latency): 观察到的最长延迟                                │
│  - 延迟抖动 (Jitter): 相邻延迟差值的统计分布                               │
│                                                                             │
│  资源利用率:                                                               │
│  ──────────                                                                │
│  - CPU 利用率: 每个核心的使用率                                             │
│  - Memory Bandwidth: 内存带宽使用                                         │
│  - Cache Miss Rate: L1/L2/L3 未命中率                                      │
│  - CPI (Cycles Per Instruction): 衡量 CPU 执行效率                        │
│    CPI ≈ 0.25: 良好 (接近超标量极限)                                      │
│    CPI > 1.0: 可能存在内存访问瓶颈                                        │
│    CPI > 2.0: 严重 stall，需要重点优化                                    │
│                                                                             │
│  效率指标:                                                                │
│  ────────                                                                  │
│  - Cycles Per Packet (CPP): 每包消耗的 CPU 周期数                          │
│  - Cache Misses Per Packet (CMPP): 每包 Cache Miss 数                     │
│  - Instructions Per Packet (IPP): 每包执行指令数                           │
│                                                                             │
│  DPDK 典型基线 (64B 包, 单核):                                            │
│  ───────────────────────────                                               │
│  - L2 Forwarding: ~30 MPPS, CPP ~46 (@ 1.4 GHz)                           │
│  - L3 Forwarding: ~15 MPPS, CPP ~93                                        │
│  - ACL Processing: ~5 MPPS, CPP ~280                                       │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. dpdk-proc-info

### 2.1 工具概述

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        dpdk-proc-info 工具                                  │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  dpdk-proc-info 是 DPDK 自带的运行时信息查询工具                           │
│  ─────────────────────────────────────────────                              │
│                                                                             │
│  特点:                                                                    │
│  - 以 secondary 进程方式附加到运行中的 DPDK 应用                            │
│  - 读取 primary 进程共享的统计信息 (不干扰业务)                            │
│  - 支持读取 ethdev stats / xstats                                          │
│  - 支持读取 mempool、ring 状态                                             │
│  - 支持读取 rte_metrics 注册的自定义指标                                    │
│                                                                             │
│  位置 (meson 构建):                                                      │
│  - build/app/dpdk-proc-info                                                │
│                                                                             │
│  注意:                                                                    │
│  - 必须与目标应用使用相同的 DPDK 版本和构建配置                            │
│  - 需要共享文件系统 (/var/run/dpdk/) 的访问权限                          │
│  - 不支持在目标应用运行期间启动 primary 进程                               │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 2.2 基本使用

```bash
# 基本语法: dpdk-proc-info [EAL 参数] -- [工具参数]

# 显示 port 0 的基本统计
dpdk-proc-info -l 0 -- --stats -p 1

# 显示 port 0 的扩展统计 (xstats，含 per-queue 数据)
dpdk-proc-info -l 0 -- --xstats -p 1

# 重置 port 0 的基本统计
dpdk-proc-info -l 0 -- --stats-reset -p 1

# 重置 port 0 的 xstats
dpdk-proc-info -l 0 -- --xstats-reset -p 1

# 显示所有 mempool 信息
dpdk-proc-info -l 0 -- --show-mempool

# 显示指定 mempool
dpdk-proc-info -l 0 -- --show-mempool=mbuf_pool_0

# 显示 ring 信息
dpdk-proc-info -l 0 -- --show-ring

# 显示 rte_metrics 注册的自定义指标
dpdk-proc-info -l 0 -- --metrics -p 1

# 按名称查询特定 xstat
dpdk-proc-info -l 0 -- --xstats-name rx_good_packets -p 1

# 按 ID 查询特定 xstats (逗号分隔)
dpdk-proc-info -l 0 -- --xstats-ids 0,1,2 -p 1
```

### 2.3 输出解析

```
========================================
  Port 0 -- basic stats
========================================
  ipackets: 14523456
  opackets: 14523401
  ibytes:   8714073600
  obytes:   8714023456
  imissed:  0
  ierrors:  0
  oerrors:  0
  rx_nombuf: 0

========================================
  Port 0 -- xstats (部分)
========================================
  rx_good_packets:           14523456
  tx_good_packets:           14523401
  rx_good_bytes:             8714073600
  tx_good_bytes:             8714023456
  rx_priority0_mbuf_allocation_errors: 0

  # per-queue 统计 (由 PMD 驱动提供)
  rx_q0_packets:             3630864
  rx_q0_bytes:               2178518400
  rx_q1_packets:             3630864
  rx_q1_bytes:               2178518400
  rx_q2_packets:             3630864
  rx_q2_bytes:               2178518400
  rx_q3_packets:             3630864
  rx_q3_bytes:               2178518400

  tx_q0_packets:             3630850
  tx_q0_bytes:               2178510000
  ...

  # 硬件 offload 统计
  rx_unicast_packets:        14523456
  rx_multicast_packets:      0
  rx_broadcast_packets:      0
  rx_size_64_packets:        14523456

========================================
  Mempool: mbuf_pool_0
========================================
  pool: mbuf_pool_0
  flags:
  private_data_size: 0
  mbuf_data_room_size: 2048
  socket_id: 0
  populated_size: 16384
  obj_header_size: 0
  total_elts: 16384
  cache_size: 256
  nb_memzones: 1
```

### 2.4 xstats：扩展统计

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        stats vs xstats                                     │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  rte_eth_stats (基本统计):                                                 │
│  ──────────────────────────                                                │
│  struct rte_eth_stats {                                                    │
│      uint64_t ipackets;    // 总 RX 包数                                  │
│      uint64_t opackets;    // 总 TX 包数                                  │
│      uint64_t ibytes;      // 总 RX 字节数                                │
│      uint64_t obytes;      // 总 TX 字节数                                │
│      uint64_t imissed;     // HW 丢弃 (FIFO 溢出)                         │
│      uint64_t ierrors;     // RX 错误包                                   │
│      uint64_t oerrors;     // TX 错误包                                   │
│      uint64_t rx_nombuf;   // mbuf 分配失败                               │
│      uint64_t q_ipackets[RTE_ETHDEV_QUEUE_STAT_CNTRS]; // per-queue RX    │
│      uint64_t q_opackets[RTE_ETHDEV_QUEUE_STAT_CNTRS]; // per-queue TX    │
│      uint64_t q_ibytes[RTE_ETHDEV_QUEUE_STAT_CNTRS];                      │
│      uint64_t q_obytes[RTE_ETHDEV_QUEUE_STAT_CNTRS];                      │
│      uint64_t q_errors[RTE_ETHDEV_QUEUE_STAT_CNTRS];                      │
│  };                                                                         │
│                                                                             │
│  xstats (扩展统计):                                                        │
│  ──────────────────                                                        │
│  - 由 PMD 驱动实现，提供硬件级细粒度统计                                   │
│  - 包含 per-queue、per-priority、per-size 分布                             │
│  - 不同网卡 (i40e/ice/mlx5) 提供不同的 xstats 指标                        │
│  - 通过 rte_eth_xstats_get() / rte_eth_xstats_get_names() 访问           │
│                                                                             │
│  常用 xstats 指标:                                                         │
│  ────────────────                                                          │
│  - rx_good_packets / tx_good_packets: 好包计数                             │
│  - rx_size_64_packets ... rx_size_1523_packets: 包长分布                   │
│  - rx_qN_packets / tx_qN_packets: per-queue 包计数                        │
│  - rx_unicast/multicast/broadcast_packets: 包类型分布                      │
│  - rx_dma_length_errors: DMA 长度错误                                     │
│  - rx_mac_short_packet_dropped: 短包丢弃                                  │
│                                                                             │
│  代码获取 xstats:                                                          │
│  ────────────────                                                          │
│  int len = rte_eth_xstats_get_names(port_id, NULL, 0);                    │
│  struct rte_eth_xstat_name *names = malloc(len * sizeof(*names));         │
│  rte_eth_xstats_get_names(port_id, names, len);                           │
│                                                                             │
│  struct rte_eth_xstat *xstats = malloc(len * sizeof(*xstats));            │
│  rte_eth_xstats_get(port_id, xstats, len);                                │
│                                                                             │
│  for (int i = 0; i < len; i++)                                             │
│      printf("%s: %"PRIu64"\n", names[i].name, xstats[i].value);           │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 2.5 rte_metrics 与 rte_telemetry

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                     DPDK 可观测性框架                                       │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  rte_metrics (指标注册库):                                                 │
│  ──────────────────────────                                                │
│  - 应用自定义指标，可通过 dpdk-proc-info --metrics 查看                    │
│  - rte_latencystats 库内部就使用 rte_metrics 注册延迟指标                  │
│                                                                             │
│  API:                                                                      │
│  - rte_metrics_init(socket_id)                                             │
│  - rte_metrics_reg_name("my_metric")  → 返回 key                          │
│  - rte_metrics_update_value(port_id, key, value)                           │
│  - rte_metrics_get_values(port_id, values, capacity)                       │
│                                                                             │
│  rte_telemetry (JSON-RPC 查询接口):                                       │
│  ──────────────────────────────────                                        │
│  - DPDK 21.11+ 内置，通过 UNIX socket 暴露                                │
│  - 路径: /var/run/dpdk/rte/telemetry                                      │
│  - 无需启动 dpdk-proc-info 即可查询                                       │
│  - 支持 JSON 格式输入/输出                                                │
│                                                                             │
│  使用示例:                                                                 │
│  ──────────                                                                │
│  # 查询 port 0 的基本统计                                                  │
│  echo '{"action":1,"command":"/ethdev/stats","params":{"0":0}}' \          │
│    | socat - UNIX-CONNECT:/var/run/dpdk/rte/telemetry                     │
│                                                                             │
│  # 查询 port 0 的 xstats                                                   │
│  echo '{"action":1,"command":"/ethdev/xstats","params":{"0":0}}' \         │
│    | socat - UNIX-CONNECT:/var/run/dpdk/rte/telemetry                     │
│                                                                             │
│  # 列出所有已注册的 telemetry 命令                                         │
│  echo '{"action":1,"command":"/"}' \                                       │
│    | socat - UNIX-CONNECT:/var/run/dpdk/rte/telemetry                     │
│                                                                             │
│  自定义 telemetry 命令:                                                    │
│  ────────────────────                                                      │
│  // 注册自定义命令                                                         │
│  static int                                                                │
│  handle_my_stats(const char *cmd, const char *params,                      │
│                  struct rte_tel_data *data)                                 │
│  {                                                                         │
│      rte_tel_data_start_dict(data);                                        │
│      rte_tel_data_add_dict_uint(data, "pps", current_pps);                 │
│      rte_tel_data_add_dict_uint(data, "latency_ns", avg_latency);          │
│      return 0;                                                             │
│  }                                                                         │
│                                                                             │
│  rte_telemetry_register_cmd("/myapp/stats", handle_my_stats,               │
│      "Returns custom app stats");                                           │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 3. perf 基础

### 3.1 perf 概述

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        perf 性能分析工具                                   │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  perf 是 Linux 内核自带的性能分析工具                                      │
│  ─────────────────────────────────────────                                  │
│                                                                             │
│  安装:                                                                    │
│  ────                                                                    │
│  apt install linux-tools-common linux-tools-$(uname -r)                    │
│  或                                                                    │
│  yum install perf                                                         │
│                                                                             │
│  常用命令:                                                                 │
│  ──────────                                                                │
│  perf list                 列出可用事件                                     │
│  perf stat                 统计计数 (宏观概览)                              │
│  perf record               记录采样数据 (微观分析)                          │
│  perf report               显示报告                                        │
│  perf top                  实时热点 (类似 top)                              │
│  perf annotate             反汇编注释 (指令级)                              │
│  perf script               导出原始采样数据                                │
│  perf c2c                  缓存行竞争分析 (多核关键)                       │
│                                                                             │
│  DPDK 使用 perf 的注意点:                                                 │
│  ────────────────────────                                                  │
│  - DPDK 应用通常绑定到隔离 CPU (isolcpus)                                 │
│    → 使用 perf -C 0,1,2 指定目标 CPU                                      │
│  - DPDK 轮询模式导致 CPU 100% (即使空闲)                                  │
│    → 关注 CPI / cache-miss 等硬件事件，而非 CPU%                          │
│  - 需要 --no-pager 和足够权限 (perf_event_paranoid 设为 0)                │
│  - 编译时加 -ggdb -fno-omit-frame-pointer 以保留调试信息和帧指针          │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 3.2 perf stat 统计

```bash
# 基本统计
perf stat -e cycles,instructions,cache-references,cache-misses ./dpdk_app

# 分组统计
perf stat -e "{cycles,instructions,cache-misses}" ./dpdk_app

# 多核统计 (按 core 分组)
perf stat -a -e cycles,instructions --per-core ./dpdk_app

# 按 socket 分组 (NUMA 感知)
perf stat -a -e cycles,instructions --per-socket ./dpdk_app

# 指定 CPU 采集 (适合 DPDK 绑核场景)
perf stat -C 2,3 -e cycles,instructions,cache-misses sleep 10

# 输出示例
#  Performance counter stats for 'CPU(s) 2,3':
#
#        28,000,000,000      cycles                      (100.00%)
#        56,000,000,000      instructions                (100.00%)  # 2.00 IPC
#         1,000,000,000      cache-references            (100.00%)
#            50,000,000      cache-misses                (100.00%)  # 5.00% miss rate
#           800,000,000      branch-instructions         (100.00%)
#             8,000,000      branch-misses               (100.00%)  # 1.00% miss rate
#
#       10.001234567 seconds time elapsed
```

### 3.3 perf record/report

```bash
# 记录采样数据 (使用帧指针)
perf record -g -e cycles ./dpdk_app

# 使用 DWARF 调用链 (无需帧指针，推荐用于 -O2 编译的代码)
perf record --call-graph dwarf -e cycles ./dpdk_app

# 使用 LBR 调用链 (Intel CPU，低开销)
perf record --call-graph lbr -e cycles ./dpdk_app

# 指定 CPU 采集 (DPDK 常用)
perf record -C 2,3 -g -e cycles sleep 30

# 采样频率 (默认 4000 Hz，DPDK 高频场景可降低到 999 Hz)
perf record -F 999 -C 2,3 -g -e cycles sleep 30

# 查看报告 (交互式 TUI)
perf report

# 按符号排序
perf report --sort symbol

# 只显示 >1% 的热点
perf report --percent-limit 1

# 导出文本报告
perf report --stdio > /tmp/perf_report.txt

# 只看用户空间
perf report --no-kernel

# 查看特定函数
perf report --stdio -s symbol | grep -A 5 process_packet
```

### 3.4 perf top 实时热点

```bash
# 实时显示热点 (类似 top)
perf top

# 只看用户空间热点 (-K 隐藏内核符号)
perf top -K

# 只看内核空间热点 (-U 隐藏用户符号)
perf top -U

# 注意: 不要同时使用 -K 和 -U，否则什么都不会显示

# 指定 CPU (DPDK 场景)
perf top -C 2,3

# 指定进程
perf top -p $(pgrep dpdk_app)

# 使用 Intel PT 精确采样 (如果有硬件支持)
perf top -e cycles:p -C 2
```

### 3.5 perf annotate

```bash
# 详细分析特定函数
perf annotate --symbol=process_packet

# 输出 (汇编 + 采样占比)
#  process_packet()    Percent |      Source Code & Disassembly
#  ----------------------------------------------------------------
#      0.00 :           push   %rbp
#      0.00 :           mov    %rsp,%rbp
#      5.23 :           mov    (%rdi),%rax        # 读解包数据
#     10.45 :           add    $0x1,%rax
#     15.67 :           mov    %rax,(%rdi)        # 写统计
#      3.21 :           cmp    $0x100,%rax
#      2.11 :           jne   .L2
#     63.33 :           callq  rte_hash_lookup    # 热点: hash 查找

# 带源码 (需要 -ggdb 编译)
perf annotate --symbol=process_packet --source

# 指定二进制文件
perf annotate -d ./dpdk_app --symbol=process_packet
```

---

## 4. 火焰图 (Flame Graph)

### 4.1 火焰图原理

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        火焰图原理                                          │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  火焰图 (Flame Graph) 由 Brendan Gregg 发明                               │
│  ─────────────────────────────────────────────────                          │
│                                                                             │
│  结构:                                                                    │
│  ────                                                                    │
│  - Y 轴: 调用栈深度 (从下到上是调用关系)                                   │
│  - X 轴: 采样比例 (宽度 = 该函数在栈上出现的采样占比)                      │
│  - X 轴按字母排序 (不是时间顺序!)                                          │
│  - 每块: 一个函数帧                                                        │
│  - 顶层: 叶子函数 (CPU 热点)                                               │
│  - 底层: 入口函数 (main 等)                                                │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐ │
│  │                                                                    │ │
│  │              ┌──────────────────────┐                              │ │
│  │              │  rte_hash_lookup 35% │ ← 宽顶: 热点!               │ │
│  │              └──────────────────────┘                              │ │
│  │         ┌───────────┐   ┌──────────┐                              │ │
│  │         │parse_hdr  │   │update_st │                              │ │
│  │         │    8%     │   │   2%     │                              │ │
│  │    ┌────┴───────────┴───┴──────────┘                              │ │
│  │    │  process_packet  50%             │                           │ │
│  │    └──────────────────────────────────┘                           │ │
│  │  ┌────────┐  ┌──────────┐  ┌─────────┐                          │ │
│  │  │rx_burst│  │tx_burst  │  │ timers  │                          │ │
│  │  │  15%   │  │  10%     │  │  5%     │                          │ │
│  │  └────────┘  └──────────┘  └─────────┘                          │ │
│  │  ┌──────────────────────────────────────────────────────────┐   │ │
│  │  │  main  100%                                             │   │ │
│  │  └──────────────────────────────────────────────────────────┘   │ │
│  │                                                                    │ │
│  └─────────────────────────────────────────────────────────────────────┘ │
│                                                                             │
│  解读:                                                                    │
│  ────                                                                    │
│  - 越宽的函数 = 越热 (CPU 采样到它的次数越多)                              │
│  - 顶层宽块 = 优化的首要目标                                              │
│  - 从顶层往下追溯，找到完整的调用路径                                      │
│  - 相邻块的顺序无意义 (按字母排列，不是时间顺序)                           │
│                                                                             │
│  冰柱图 (Icicle Graph): 自上而下版本 (顶层是 main，底层是叶子)             │
│  逆火焰图 (Reverse Flame Graph): 以调用者为子节点，用于分析调用开销        │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 4.2 生成火焰图

```bash
# 方法 1: 传统 FlameGraph 工具 (Brendan Gregg)
# 安装
git clone https://github.com/brendangregg/FlameGraph.git
export PATH=$PATH:~/FlameGraph

# 采集 perf 数据 (DWARF 调用链，推荐)
perf record -F 999 --call-graph dwarf -C 2,3 -- sleep 30

# 一行命令生成
perf script | stackcollapse-perf.pl | flamegraph.pl > flame.svg

# 方法 2: 使用 perf 自带的火焰图生成 (Linux 5.8+)
perf record -F 999 -g -C 2,3 -- sleep 30
perf report --hierarchy --stdio | flamegraph.pl > flame.svg

# 方法 3: 使用 speedscope (交互式，支持火焰图和冰柱图)
git clone https://github.com/jlfwong/speedscope
perf record -F 999 --call-graph dwarf -C 2,3 -- sleep 30
perf script > perf.txt
# 在 speedscope 网页中导入 perf.txt

# 只看用户空间
perf script | grep -v '\[k\]' | stackcollapse-perf.pl | flamegraph.pl > user_flame.svg

# 生成差异火焰图 (对比优化前后)
perf record -F 999 -g -C 2 -- sleep 30  # 优化前
mv perf.data perf.data.before
perf record -F 999 -g -C 2 -- sleep 30  # 优化后
perf script -i perf.data.before | stackcollapse-perf.pl > before.folded
perf script -i perf.data | stackcollapse-perf.pl > after.folded
difffolded.pl before.folded after.folded | flamegraph.pl --negate > diff.svg
```

### 4.3 DPDK 应用火焰图采集

```bash
#!/bin/bash
# dpdk_flamegraph.sh - DPDK 应用火焰图采集脚本
#
# 注意事项:
# - DPDK 应用通常是 primary 进程，perf 不需要以相同身份运行
# - 使用 -C 指定目标 lcore 对应的 CPU 编号
# - 采样频率不宜过高 (999 Hz 足够)，避免影响被测应用

set -e

LCORES=${1:-"2,3"}       # 采集的 CPU 列表
DURATION=${2:-30}         # 采集时长 (秒)
OUTPUT=${3:-/tmp/dpdk_flame}

FLAMEGRAPH_DIR=${FLAMEGRAPH_DIR:-$HOME/FlameGraph}

echo "采集 CPU $LCORES 上 $DURATION 秒的采样数据..."

# 采集
perf record -F 999 --call-graph dwarf -C "$LCORES" -o "${OUTPUT}.data" -- sleep "$DURATION"

# 转换
perf script -i "${OUTPUT}.data" > "${OUTPUT}.perf"

# 折叠栈 + 生成火焰图
if [ -d "$FLAMEGRAPH_DIR" ]; then
    "$FLAMEGRAPH_DIR/stackcollapse-perf.pl" "${OUTPUT}.perf" > "${OUTPUT}.folded"
    "$FLAMEGRAPH_DIR/flamegraph.pl" "${OUTPUT}.folded" > "${OUTPUT}.svg"
    echo "火焰图已保存: ${OUTPUT}.svg"
else
    echo "FlameGraph 工具未找到，设置 FLAMEGRAPH_DIR 环境变量"
    echo "原始数据: ${OUTPUT}.perf"
fi
```

### 4.4 火焰图解读

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        火焰图解读指南                                       │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  DPDK 火焰图典型模式:                                                     │
│  ────────────────────                                                      │
│                                                                             │
│  正常: 主体是业务处理函数 (process_packet, lookup, etc.)                    │
│  异常: 大量时间花在 rte_pktmbuf_free / rte_ring_enqueue 等基础操作          │
│                                                                             │
│  常见问题模式:                                                             │
│  ────────────                                                              │
│                                                                             │
│  1. 宽顶 (Plateau):                                                        │
│     单个函数占据很宽的条带                                                  │
│     → 该函数是瓶颈，优先优化                                               │
│     → 常见: rte_hash_lookup, memcpy, rte_pktmbuf_free                      │
│                                                                             │
│  2. 梳状 (Comb):                                                           │
│     循环中反复调用同一组函数                                                │
│     → 正常的 DPDK 处理循环模式                                             │
│     → 如果某一帧特别宽，该帧是热点                                         │
│                                                                             │
│  3. 高塔 (Tower):                                                          │
│     调用栈特别深                                                            │
│     → 可能存在不必要的函数调用层次                                          │
│     → 考虑内联或扁平化                                                     │
│                                                                             │
│  4. 断层 (Gap):                                                            │
│     某些层缺失 (显示为 [unknown])                                          │
│     → 编译时未加 -fno-omit-frame-pointer                                   │
│     → 使用 --call-graph dwarf 可以缓解                                     │
│     → 动态库符号未导出                                                     │
│                                                                             │
│  优化方向:                                                                │
│  ────────                                                                  │
│  - 消除宽顶: 优化热点函数                                                  │
│  - 扁平化调用链: 内联减少调用开销                                          │
│  - 对比差异火焰图: 量化优化效果                                            │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 5. 延迟分析

### 5.1 TSC 精确计时

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        TSC (Time Stamp Counter)                            │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  x86 TSC 特性:                                                            │
│  ──────────                                                                │
│  - rdtsc 指令读取 64 位时间戳计数器                                        │
│  - Invariant TSC (Nehalem+): 频率恒定，不受 CPU 频率调节影响               │
│  - 开销极低: ~20 cycles (非序列化)                                         │
│  - DPDK 封装: rte_rdtsc() / rte_rdtsc_precise()                           │
│                                                                             │
│  时间转换:                                                                │
│  ────────                                                                  │
│  - rte_get_timer_hz() 返回 TSC 频率 (Hz)                                  │
│  - 微秒 = cycles * 1e6 / rte_get_timer_hz()                               │
│  - 纳秒 = cycles * 1e9 / rte_get_timer_hz()                               │
│                                                                             │
│  注意:                                                                    │
│  - 不同 CPU 的 TSC 可能不同步 (即使同一 socket)                            │
│  - DPDK 绑核场景下这不是问题 (每个 lcore 只读自己的 TSC)                   │
│  - 跨 CPU 延迟测量需要考虑 TSC 偏移                                       │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 5.2 自定义延迟测量

```c
#include <rte_cycles.h>

// 延迟测量: 使用 rte_rdtsc() 即可，无需手写 rdtsc 汇编

// 延迟直方图 (指数分布，覆盖 1 cycle ~ 2^32 cycles)
#define LATENCY_BINS 32

struct latency_stats {
    uint64_t count;
    uint64_t min;
    uint64_t max;
    uint64_t sum;
    uint64_t bins[LATENCY_BINS];
};

static inline void
latency_record(struct latency_stats *s, uint64_t cycles)
{
    s->sum += cycles;
    s->count++;
    if (cycles < s->min || s->count == 1) s->min = cycles;
    if (cycles > s->max) s->max = cycles;

    // 指数分桶: bin 0 = [1,2), bin 1 = [2,4), bin k = [2^k, 2^(k+1))
    int bin = cycles ? (63 - __builtin_clzll(cycles)) : 0;
    if (bin >= LATENCY_BINS) bin = LATENCY_BINS - 1;
    s->bins[bin]++;
}

// 计算百分位数
uint64_t
latency_percentile(struct latency_stats *s, int pct)
{
    if (s->count == 0) return 0;

    uint64_t target = s->count * pct / 100;
    uint64_t cumulative = 0;

    for (int i = 0; i < LATENCY_BINS; i++) {
        cumulative += s->bins[i];
        if (cumulative >= target)
            return 1ULL << i;  // 该桶的下界
    }

    return s->max;
}

// 使用示例: 测量单包处理延迟
void
process_packets_with_latency(struct rte_mbuf **pkts, uint16_t nb)
{
    struct latency_stats *stats = &per_lcore_stats;

    for (int i = 0; i < nb; i++) {
        uint64_t t0 = rte_rdtsc();
        process_packet(pkts[i]);
        uint64_t t1 = rte_rdtsc();
        latency_record(stats, t1 - t0);
    }
}
```

### 5.3 rte_latencystats 库

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                   rte_latencystats 库                                       │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  DPDK 内置延迟统计库 (lib/latencystats)                                    │
│  ─────────────────────────────────────────                                 │
│                                                                             │
│  原理:                                                                    │
│  ────                                                                    │
│  1. 注册 RX 回调: 在 rte_eth_rx_burst 返回时记录 TSC                      │
│  2. 注册 TX 回调: 在 rte_eth_tx_burst 发送时记录 TSC                      │
│  3. 计算差值: TX 时间 - RX 时间 = 应用处理延迟                            │
│  4. 结果写入 rte_metrics                                                  │
│                                                                             │
│  提供的指标 (通过 rte_metrics 暴露):                                       │
│  ────────────────────────────────────                                      │
│  - min_latency_ns   最小延迟 (纳秒)                                       │
│  - avg_latency_ns   平均延迟 (纳秒)                                       │
│  - max_latency_ns   最大延迟 (纳秒)                                       │
│  - jitter_ns        抖动 (纳秒)                                           │
│                                                                             │
│  使用:                                                                    │
│  ────                                                                    │
│  #include <rte_latencystats.h>                                             │
│                                                                             │
│  // 初始化                                                                │
│  rte_latencystats_init(nb_rx_queues, NULL);                                │
│                                                                             │
│  // 查询                                                                  │
│  uint16_t nb_names = rte_latencystats_get_names(NULL, 0);                  │
│  struct rte_metric_name *names = malloc(nb_names * sizeof(*names));        │
│  rte_latencystats_get_names(names, nb_names);                              │
│                                                                             │
│  struct rte_metric_value *values = malloc(nb_names * sizeof(*values));     │
│  rte_latencystats_get(port_id, values, nb_names);                          │
│                                                                             │
│  // 也可以通过 dpdk-proc-info --metrics 查看                               │
│                                                                             │
│  // 清理                                                                  │
│  rte_latencystats_uninit();                                                │
│                                                                             │
│  限制:                                                                    │
│  ────                                                                    │
│  - 只测量同一应用内 RX → TX 的延迟                                        │
│  - 不适合测量端到端 (跨机器) 延迟                                         │
│  - 回调本身有少量开销 (~50 cycles/packet)                                  │
│  - 需要启用 RTE_LIBRTE_LATENCY_STATS 构建选项                             │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 5.4 端到端延迟测量

```c
// 端到端延迟: 在包的 payload 中嵌入时间戳
// 注意: 不是用 rte_pktmbuf_prepend (会破坏 Ethernet 头)
// 而是在已有协议头部之后嵌入自定义时间戳

#include <rte_ether.h>
#include <rte_ip.h>
#include <rte_udp.h>

// 方案 1: 使用 UDP payload 前几个字节存储时间戳
// 适用于自研协议或测试工具

struct latency_marker {
    uint64_t tsc_send;
    uint32_t seq;
    uint32_t magic;  // 0xDEADBEEF
} __rte_packed;

// 发送端: 在 UDP payload 开头写入时间戳
void
send_with_timestamp(struct rte_mbuf *m, uint32_t seq)
{
    // 假设包已经构建好 Ethernet + IP + UDP 头
    struct rte_udp_hdr *udp = rte_pktmbuf_mtod_offset(m,
            struct rte_udp_hdr *,
            sizeof(struct rte_ether_hdr) + sizeof(struct rte_ipv4_hdr));

    struct latency_marker *marker = (struct latency_marker *)(udp + 1);
    marker->tsc_send = rte_rdtsc();
    marker->seq = seq;
    marker->magic = 0xDEADBEEF;
}

// 接收端: 读取时间戳计算延迟
void
recv_with_latency(struct rte_mbuf **mbufs, uint16_t count,
                   struct latency_stats *stats)
{
    uint64_t now = rte_rdtsc();

    for (int i = 0; i < count; i++) {
        struct rte_udp_hdr *udp = rte_pktmbuf_mtod_offset(mbufs[i],
                struct rte_udp_hdr *,
                sizeof(struct rte_ether_hdr) + sizeof(struct rte_ipv4_hdr));

        struct latency_marker *marker = (struct latency_marker *)(udp + 1);

        if (marker->magic == 0xDEADBEEF) {
            uint64_t latency = now - marker->tsc_send;
            latency_record(stats, latency);
        }
    }
}

// 方案 2: 使用 IEEE 1588 PTP 硬件时间戳 (精确到纳秒)
// 需要 NIC 支持 RTE_ETH_RX_OFFLOAD_TIMESTAMP
// mbuf->ol_flags & RTE_MBUF_F_RX_IEEE1588_TMST 时
// mbuf->timestamp 包含硬件时间戳
```

### 5.5 Jitter 测量

```c
// RFC 3550 抖动计算 (适用于网络延迟抖动)
// J = J + (|D(i-1,i)| - J) / 16
// 其中 D(i-1,i) 是相邻两个包的延迟差

struct jitter_state {
    int64_t jitter;      // 平滑抖动估计
    uint64_t last_transit; // 上一包的 transit time
};

static inline void
jitter_update(struct jitter_state *j, uint64_t send_ts, uint64_t recv_ts)
{
    uint64_t transit = recv_ts - send_ts;

    if (j->last_transit != 0) {
        int64_t d = (int64_t)transit - (int64_t)j->last_transit;
        if (d < 0) d = -d;
        j->jitter += (d - j->jitter) / 16;
    }
    j->last_transit = transit;
}
```

---

## 6. perf 高级用法

### 6.1 PMU 硬件事件

```bash
# CPU 周期
perf stat -e cycles ./app

# 指令数和 IPC
perf stat -e cycles,instructions ./app

# Cache 分析
perf stat -e cache-references,cache-misses ./app
perf stat -e L1-dcache-loads,L1-dcache-load-misses ./app
perf stat -e LLC-loads,LLC-load-misses ./app

# 分支预测
perf stat -e branch-instructions,branch-misses ./app

# TLB 分析
perf stat -e dTLB-loads,dTLB-load-misses ./app

# 组合采样 (同时采集多个维度)
perf stat -e "{cycles,instructions,cache-misses,branch-misses}" \
    -C 2,3 -- sleep 10

# 使用原始硬件事件 (Intel 特定)
# 通过 perf list 查看
perf list hw

# 使用 Intel uncore 事件 (内存带宽等)
perf stat -e uncore_imc/data_reads/,uncore_imc/data_writes/ -a sleep 10
```

### 6.2 perf c2c：缓存行竞争分析

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                     perf c2c — Cache-to-Cache 分析                         │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  perf c2c 用于发现多核间的缓存行伪共享 (False Sharing)                     │
│  ───────────────────────────────────────────────────────                    │
│  这在 DPDK 多核场景中极为关键                                              │
│                                                                             │
│  伪共享原理:                                                              │
│  ──────────                                                                │
│  CPU 0 写入 addr+0     CPU 1 写入 addr+8                                   │
│       │                      │                                              │
│       └──── 同一 cache line (64B) ────┘                                    │
│              ↕  MESI 协议: Invalidate                                      │
│       每次 CPU 0 写 → CPU 1 的 cache line 失效                            │
│       每次 CPU 1 写 → CPU 0 的 cache line 失效                            │
│       → 两个核反复争抢同一 cache line，性能骤降                            │
│                                                                             │
│  使用:                                                                    │
│  ────                                                                    │
│  # 采集 (需要 root 权限)                                                  │
│  perf c2c record -a -- sleep 30                                           │
│                                                                             │
│  # 查看报告                                                               │
│  perf c2c report                                                           │
│                                                                             │
│  # 针对特定 CPU                                                           │
│  perf c2c record -C 2,3 -- sleep 30                                       │
│                                                                             │
│  报告关键列:                                                              │
│  ────────────                                                              │
│  - CL Addr:      争抢的 cache line 地址                                    │
│  - HITM:         修改过的数据在另一个核的 cache 中                         │
│  - Percent:      该 cache line 占总争抢的比例                              │
│  - Offsets:      哪些偏移量被访问                                          │
│  - Shared Cache Line: 最需要关注的 cache line                              │
│                                                                             │
│  常见 DPDK 伪共享场景:                                                    │
│  ────────────────────                                                      │
│  - per-lcore 统计结构未对齐到 cache line                                   │
│  - 全局数组中相邻元素被不同 lcore 修改                                     │
│  - rte_ring 的 prod/deferred 指针在同一 cache line                        │
│                                                                             │
│  修复:                                                                    │
│  ────                                                                    │
│  // 错误: 两个计数器在同一 cache line                                     │
│  struct shared_counters {                                                  │
│      uint64_t rx_pkts;  // lcore 0 写                                     │
│      uint64_t tx_pkts;  // lcore 1 写 (伪共享!)                           │
│  };                                                                         │
│                                                                             │
│  // 修复: 每个 counter 独占一个 cache line                                │
│  struct aligned_counter {                                                  │
│      uint64_t value;                                                       │
│      char __pad[RTE_CACHE_LINE_SIZE - sizeof(uint64_t)];                   │
│  } __rte_cache_aligned;                                                    │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 6.3 Intel PT：指令级追踪

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                     Intel PT (Processor Trace)                              │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  Intel PT 是 CPU 硬件级的指令执行追踪                                      │
│  ─────────────────────────────────────────                                 │
│  记录每个分支的 taken/not-taken，可以重建完整执行路径                       │
│                                                                             │
│  优势:                                                                    │
│  ────                                                                    │
│  - 精确到每条指令的执行顺序                                                │
│  - 开销低 (~5%)，可以长时间采集                                           │
│  - 可以事后精确分析任何函数的执行路径                                      │
│                                                                             │
│  使用:                                                                    │
│  ────                                                                    │
│  # 采集 Intel PT 数据                                                     │
│  perf record -e intel_pt//u -C 2 -- sleep 10                               │
│                                                                             │
│  # 查看指令级追踪 (带时间戳)                                              │
│  perf script --insn-trace --time                                                           │
│                                                                             │
│  # 查看特定函数的执行路径                                                  │
│  perf script --insn-trace -S process_packet                                                │
│                                                                             │
│  # 生成火焰图                                                              │
│  perf script --insn-trace | stackcollapse-perf.pl | flamegraph.pl           │
│                                                                             │
│  限制:                                                                    │
│  ────                                                                    │
│  - 仅 Intel CPU (Haswell+)                                                │
│  - 数据量可能很大 (需要足够磁盘空间)                                      │
│  - 需要 Kernel 4.1+ 支持                                                  │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 6.4 bpftrace：动态追踪

```bash
# bpftrace 可以在运行时动态插桩 DPDK 函数
# 适用于排查运行时问题，无需重启应用

# 安装
apt install bpftrace

# 追踪特定 DPDK 函数的调用频率
# 注意: 需要指向实际的二进制文件路径
bpftrace -e '
    uprobe:/path/to/dpdk_app:rte_eth_rx_burst
    {
        @rx_burst_count[pid] = count();
    }
'

# 追踪函数耗时分布
bpftrace -e '
    uprobe:/path/to/dpdk_app:rte_hash_lookup
    /pid == $1/
    {
        @t0[tid] = nsecs;
    }
    uretprobe:/path/to/dpdk_app:rte_hash_lookup
    /@t0[tid]/
    {
        @hash_latency = hist(nsecs - @t0[tid]);
        delete(@t0[tid]);
    }
'

# 追踪 mbuf 分配失败
bpftrace -e '
    uprobe:/path/to/dpdk_app:rte_pktmbuf_alloc
    /retval == 0/
    {
        @mbuf_alloc_fail = count();
    }
'

# 追踪 per-lcore 处理包数
bpftrace -e '
    uprobe:/path/to/dpdk_app:rte_eth_rx_burst
    {
        @rx_calls[cpu] = count();
    }
'
```

### 6.5 多核分析

```bash
# perf stat: per-core / per-socket / per-thread 统计
perf stat -a --per-core -e cycles,instructions sleep 10
perf stat -a --per-socket -e cycles,instructions sleep 10

# perf record: 指定 CPU 采集
perf record -C 2,3 -g -- sleep 30

# perf report: 按 CPU 分组查看
perf report --sort cpu,symbol

# 查看特定 CPU 的热点
perf report --cpu=2

# 查看特定线程的热点 (如果有多个线程)
perf report --sort comm,symbol
```

---

## 7. 热点定位实战

### 7.1 瓶颈定位流程

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        热点定位流程                                        │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  Step 1: 确定目标                                                         │
│  ───────────                                                                │
│  - 吞吐量是否达标? (目标 PPS)                                             │
│  - 延迟是否满足? (目标 P99)                                                │
│  - 哪个指标最重要?                                                         │
│                                                                             │
│  Step 2: 宏观分析                                                         │
│  ─────────────                                                              │
│  - perf stat 查看 CPI:                                                    │
│    CPI < 0.5:  CPU 利用良好                                                │
│    CPI 0.5-1:  有改善空间                                                  │
│    CPI > 1.0:  存在 stall (内存/分支预测)                                 │
│  - perf stat 查看 Cache Miss Rate                                         │
│    L1 Miss < 5%: 正常                                                      │
│    L1 Miss > 10%: 需要优化数据布局                                        │
│    LLC Miss > 20%: 严重内存瓶颈                                           │
│  - perf c2c 检查缓存行竞争                                                │
│                                                                             │
│  Step 3: 微观分析                                                         │
│  ─────────────                                                              │
│  - perf record + report 定位热点函数                                       │
│  - 火焰图直观展示调用关系                                                  │
│  - perf annotate 查看热点函数的汇编级分析                                  │
│                                                                             │
│  Step 4: 验证优化效果                                                     │
│  ──────────────────                                                        │
│  - 差异火焰图对比前后                                                      │
│  - perf stat 对比 CPI / Cache Miss Rate                                    │
│  - 吞吐/延迟回归测试                                                      │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 7.2 常见瓶颈模式

```c
// 模式 1: Cache Miss 热点
//
// 现象: perf annotate 显示高占比在 load 指令
//       CPI > 1.0, LLC Miss Rate 高

// 问题: 随机访问哈希表，每次都可能 cache miss
void
bad_hash_lookup(uint32_t key)
{
    for (int i = 0; i < TABLE_SIZE; i++) {
        if (table[i].key == key)  // 顺序扫描，cache 不友好
            return table[i].value;
    }
}

// 优化: hash + prefetch
static inline void
good_hash_lookup(uint32_t key)
{
    uint32_t hash = rte_hash_crc(&key, sizeof(key), 0);
    struct entry *e = &table[hash & TABLE_MASK];
    rte_prefetch0(e);  // 预取，隐藏内存延迟

    // 等待预取期间可以做一些其他计算
    // ...
    return e->value;
}

// 模式 2: 锁竞争
//
// 现象: perf 显示大量时间在 spinlock / futex
//       多核 CPI 低但吞吐上不去

// 问题: 所有线程竞争同一把锁
rte_spinlock_t lock = RTE_SPINLOCK_INITIALIZER;
void bad_update(void) {
    rte_spinlock_lock(&lock);
    shared_counter++;
    rte_spinlock_unlock(&lock);
}

// 优化: per-lcore 无锁计数 + 定期聚合
struct per_core_counter {
    uint64_t value;
    char __pad[RTE_CACHE_LINE_SIZE - sizeof(uint64_t)];
} __rte_cache_aligned;

static struct per_core_counter counters[RTE_MAX_LCORE];

void good_update(void) {
    counters[rte_lcore_id()].value++;  // 无锁，无竞争
}

// 模式 3: 分支预测失败
//
// 现象: perf stat 显示 branch-miss > 5%

// 问题: 协议分发不可预测
int classify(struct rte_mbuf *m) {
    struct rte_ipv4_hdr *ip = rte_pktmbuf_mtod_offset(
        m, struct rte_ipv4_hdr *, sizeof(struct rte_ether_hdr));
    switch (ip->next_proto_id) {
        case IPPROTO_TCP:   return classify_tcp(m);
        case IPPROTO_UDP:   return classify_udp(m);
        case IPPROTO_ICMP:  return classify_icmp(m);
        default:             return classify_other(m);
    }
}

// 优化: 使用 likely/unlikely 提示 (如果 TCP 占绝大多数)
int classify_opt(struct rte_mbuf *m) {
    struct rte_ipv4_hdr *ip = ...;
    if (likely(ip->next_proto_id == IPPROTO_TCP))
        return classify_tcp(m);
    if (likely(ip->next_proto_id == IPPROTO_UDP))
        return classify_udp(m);
    return classify_other(m);
}
```

### 7.3 DPDK 特定优化

```c
// 优化 1: 批量操作

// 问题: 单个释放 mbuf
void bad_free(struct rte_mbuf **pkts, uint16_t nb) {
    for (int i = 0; i < nb; i++)
        rte_pktmbuf_free(pkts[i]);
}

// 优化: 使用 bulk API (DPDK 21.11+)
void good_free(struct rte_mbuf **pkts, uint16_t nb) {
    rte_pktmbuf_free_bulk(pkts, nb);  // 一次性释放
}

// 优化 2: Ring 批量操作

// 问题: 逐个入队
void bad_enqueue(struct rte_ring *r, void **objs, int n) {
    for (int i = 0; i < n; i++)
        rte_ring_enqueue(r, objs[i]);  // 每次都有 CAS 开销
}

// 优化: 批量入队
int good_enqueue(struct rte_ring *r, void **objs, int n) {
    return rte_ring_enqueue_bulk(r, objs, n, NULL);
}

// 优化 3: 减少内存拷贝

// 问题: 不必要的 memcpy
void bad_forward(struct rte_mbuf *m) {
    struct rte_mbuf *copy = rte_pktmbuf_alloc(pool);
    char *src = rte_pktmbuf_mtod(m, char *);
    char *dst = rte_pktmbuf_mtod(copy, char *);
    rte_memcpy(dst, src, m->pkt_len);  // 不必要的拷贝
    rte_eth_tx_burst(port, queue, &copy, 1);
}

// 优化: 直接转发原始 mbuf (zero-copy)
void good_forward(struct rte_mbuf *m) {
    // 修改头部后直接发送
    struct rte_ether_hdr *eth = rte_pktmbuf_mtod(m, struct rte_ether_hdr *);
    // swap MAC addresses in-place
    rte_eth_tx_burst(port, queue, &m, 1);
}

// 优化 4: 预取 (掩盖内存延迟)

void prefetch_pipeline(struct rte_mbuf **pkts, uint16_t nb) {
    // 软件流水线: 在处理 pkt[i] 时预取 pkt[i+1] 和 pkt[i+2]
    for (int i = 0; i < nb; i++) {
        if (i + 2 < nb)
            rte_prefetch0(rte_pktmbuf_mtod(pkts[i + 2], void *));
        process_packet(pkts[i]);
    }
}
```

---

## 8. 性能测试框架

### 8.1 自定义 benchmark

```c
#include <rte_cycles.h>
#include <stdlib.h>
#include <math.h>

struct bench_result {
    uint64_t min;
    uint64_t max;
    uint64_t mean;
    uint64_t p50;
    uint64_t p90;
    uint64_t p99;
};

// 比较函数，用于 qsort
static int
cmp_u64(const void *a, const void *b)
{
    uint64_t va = *(const uint64_t *)a;
    uint64_t vb = *(const uint64_t *)b;
    if (va < vb) return -1;
    if (va > vb) return 1;
    return 0;
}

// 运行 benchmark
// fn: 被测函数, arg: 参数, warmup: 预热次数, iters: 测量次数
struct bench_result
bench_run(void (*fn)(void *), void *arg, int warmup, int iters)
{
    struct bench_result r = {0};
    uint64_t *times = malloc(iters * sizeof(uint64_t));

    // 预热 (让 cache 热起来，分支预测器进入稳定状态)
    for (int i = 0; i < warmup; i++)
        fn(arg);

    // 测量
    for (int i = 0; i < iters; i++) {
        uint64_t t0 = rte_rdtsc_precise();
        fn(arg);
        uint64_t t1 = rte_rdtsc_precise();
        times[i] = t1 - t0;
    }

    // 排序
    qsort(times, iters, sizeof(uint64_t), cmp_u64);

    // 统计
    r.min = times[0];
    r.max = times[iters - 1];
    r.p50 = times[iters * 50 / 100];
    r.p90 = times[iters * 90 / 100];
    r.p99 = times[iters * 99 / 100];

    uint64_t sum = 0;
    for (int i = 0; i < iters; i++)
        sum += times[i];
    r.mean = sum / iters;

    free(times);
    return r;
}

// 使用示例
static void
bench_hash_lookup(void *arg)
{
    uint32_t key = rte_rand();
    rte_hash_lookup((struct rte_hash *)arg, &key);
}

void
run_benchmarks(void)
{
    struct rte_hash *h = create_test_hash();

    struct bench_result r = bench_run(
        bench_hash_lookup, h, 100, 100000);

    double hz = rte_get_timer_hz();
    printf("Hash Lookup Benchmark:\n");
    printf("  min:  %.0f cycles (%.2f us)\n",
           (double)r.min, r.min * 1e6 / hz);
    printf("  mean: %.0f cycles (%.2f us)\n",
           (double)r.mean, r.mean * 1e6 / hz);
    printf("  P99:  %.0f cycles (%.2f us)\n",
           (double)r.p99, r.p99 * 1e6 / hz);
}
```

### 8.2 DPDK 测试工具

```bash
# dpdk-testpmd: 吞吐量测试
./build/app/dpdk-testpmd -l 0-7 -n 4 -- -i \
    --forward-mode=io \
    --rxd 512 --txd 512 \
    --burst 32 \
    --txq 4 --rxq 4

# testpmd 内部命令
start                        # 开始转发
show port stats all          # 显示统计
set fwd macswap              # 切换转发模式
clear port stats all         # 清零统计
stop                         # 停止

# dpdk-test: 单元测试 + 性能测试
./build/app/dpdk-test
# 进入交互界面后可选择具体的 test case

# dpdk-proc-info: 运行时统计查询
# (详见第 2 节)

# 外部工具: Moongen (精确延迟测量)
# 开源 LuaJIT-based DPDK 包生成器
# 支持 nano-second 精度的延迟直方图

# 外部工具: TRex (高性能流量生成)
# Cisco 开源，支持多种协议
# 适合吞吐量和延迟压测
```

---

## 9. 小结

本章核心要点：

1. **性能优化方法论**：测量 → 分析 → 优化 → 验证的循环，避免猜测热点。

2. **关键性能指标**：吞吐量 (PPS/BPS)、延迟 (P50/P90/P99)、资源利用率 (CPI/Cache Miss)、效率 (CPP/CMPP)。

3. **dpdk-proc-info**：DPDK 自带的 secondary 进程工具，查询 stats/xstats/mempool/ring/metrics，不干扰业务运行。

4. **xstats**：PMD 驱动提供的硬件级细粒度统计，包含 per-queue、包长分布、包类型分布等。

5. **rte_metrics + rte_telemetry**：DPDK 可观测性框架，应用自定义指标，通过 JSON-RPC socket 实时查询。

6. **perf stat**：宏观统计硬件事件 (CPI、Cache Miss Rate、Branch Miss Rate)，per-core/per-socket 分组。

7. **perf record/report**：采样分析热点函数、调用链，推荐 `--call-graph dwarf` 用于优化编译的代码。

8. **火焰图**：Brendan Gregg 发明的可视化工具，X 轴采样比例（字母排序），Y 轴调用栈深度，直观展示 CPU 时间分布。

9. **延迟测量**：`rte_rdtsc()` 提供纳秒精度计时；`rte_latencystats` 库自动统计 RX→TX 延迟和抖动。

10. **perf c2c**：缓存行竞争分析，发现多核伪共享，对 DPDK 多核性能极为关键。

11. **Intel PT**：CPU 硬件级指令追踪，精确到每条指令，低开销长时间采集。

12. **bpftrace**：运行时动态插桩，无需重启应用即可追踪 DPDK 函数调用频率和耗时。

13. **常见瓶颈模式**：Cache Miss (预取优化)、锁竞争 (per-lcore 无锁)、分支预测失败 (likely/unlikely)、伪共享 (cache line 对齐)。

14. **DPDK 批量操作**：`rte_pktmbuf_free_bulk`、`rte_ring_enqueue_bulk` 等减少逐个操作的 CAS 开销。

**下一篇预告**：[[2026-04-09-dpdk-deep-dive-ch30-performance-tuning|第三十章]]将讲解性能调优——Batching、RSS、Flow Director。

---

> [!tip] 参考文献
>
> - Brendan Gregg, "Systems Performance: Enterprise and the Cloud", 2nd Edition
> - Brendan Gregg, "BPF Performance Tools"
> - Linux perf wiki, https://perf.wiki.kernel.org/
> - FlameGraph 工具, https://github.com/brendangregg/FlameGraph
> - Intel, "Intel VTune Profiler User Guide"
> - DPDK Programmers Guide - Profiling, https://doc.dpdk.org/guides/prog_guide/
> - DPDK rte_latencystats API, https://doc.dpdk.org/api/rte__latencystats_8h.html
> - DPDK rte_metrics API, https://doc.dpdk.org/api/rte__metrics_8h.html
> - "perf c2c: Counter Analysis for Shared Cache Lines", https://perf.wiki.kernel.org/index.php/Tutorial#Cache-to-Cache
