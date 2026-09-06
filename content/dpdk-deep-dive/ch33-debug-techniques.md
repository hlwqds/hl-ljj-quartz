---
title: "DPDK 深度探索 (三十三)：调试技术——日志、断言、Crash 分析"
date: 2026-04-09 15:43:00
tags: [dpdk, series, debugging, logging, assert, crash-analysis, rte-trace]
description: "深入解析 DPDK 调试技术：RTE_LOG 日志系统、RTE_ASSERT 断言、rte_trace 追踪、core dump 与 GDB post-mortem 分析"
---

> [!info] DPDK 深度探索系列 0. [[dpdk-deep-dive|全栈学习路径总览]]
> 1-30. 前三十章已完成 31. **第三十三章：调试技术——日志、断言、Crash 分析**
>
> 调试侧工具与运行时观测:
>
> - [[ch31-debugging-tools|第三十一章：DPDK 调试工具]]
> - [[ch30-performance-tuning|第三十章：性能调优]]
> - 实战: [[2026-05-30-dpdk-debugging-practice|5 类典型 bug 的调试实战]]

---

## 1. RTE_LOG 日志系统

### 1.1 架构

DPDK 用统一的 `RTE_LOG` 框架管理所有模块日志。每个 PMD、库、用户应用都有独立的 logtype，可以单独控制级别。

```
RTE_LOG 框架组成:

   应用程序 / DPDK 库
        │
        │ RTE_LOG(LEVEL, TYPE, fmt, ...)
        ▼
   ┌─────────────────────────────┐
   │  RTE_LOG 宏                 │  ← 编译时决定是否输出
   │  (条件: 级别 + logtype 阈值) │
   └────────────┬────────────────┘
                │
                ▼
   ┌─────────────────────────────┐
   │  rte_log 运行时派发         │  ← 格式化 + 路由
   └────────────┬────────────────┘
                │
       ┌────────┴────────┐
       ▼                 ▼
   console (stderr)   history buffer (环形)
   (可重定向到文件)    (可被 dpdk-proc-info 拉取)
```

### 1.2 日志级别

DPDK 用 1-8 整数定义日志级别，**不是 syslog 那种 0-7**：

```c
#include <rte_log.h>

RTE_LOG_EMERG    = 1   // 系统不可用
RTE_LOG_ALERT    = 2   // 需要立即处理
RTE_LOG_CRIT     = 3   // 严重错误
RTE_LOG_ERR      = 4   // 错误
RTE_LOG_WARNING  = 5   // 警告
RTE_LOG_NOTICE   = 6   // 正常但重要
RTE_LOG_INFO     = 7   // 普通信息
RTE_LOG_DEBUG    = 8   // 调试信息
```

> 易错点：DPDK 的 `RTE_LOG_EMERG = 1`（不是 syslog 那种 0）。别用 0 当作"全部关闭"。

### 1.3 基础用法

```c
#include <rte_log.h>

/* 正确写法: RTE_LOG 宏 + 短名 */
RTE_LOG(INFO,  USER1, "Port %u initialized\n", port_id);
RTE_LOG(ERR,   USER1, "Failed to allocate mbuf: %s\n", rte_strerror(rte_errno));
RTE_LOG(DEBUG, USER1, "Packet hash: 0x%x\n", hash_value);

/* 错误写法: 不要再加 RTE_LOG_ 或 RTE_LOGTYPE_ 前缀 */
RTE_LOG(RTE_LOG_INFO, RTE_LOGTYPE_USER1, "...");  // 编译报错
```

`RTE_LOG` 宏会自动做两件事：

1. 检查 `global_level` 和 `type_level`，**级别不够直接编译期丢弃**
2. 拼接 `__FILE__:__LINE__`、timestamp、logtype 名称

### 1.4 用户日志类型

DPDK 预分配了 `RTE_LOGTYPE_USER1` 到 `RTE_LOGTYPE_USER8` 共 8 个用户类型：

```c
/* 简单用法: 直接用 USER1 */
#define MY_LOG RTE_LOGTYPE_USER1

RTE_LOG(INFO, MY_LOG, "...");

/* 推荐: 动态注册更灵活 (24+ 类型也支持) */
#include <rte_log.h>

/* 静态注册: 文件作用域 */
RTE_LOG_REGISTER(myapp_logtype, myapp, INFO);

/* 动态注册: 运行时 */
int mytype = rte_log_register("myapp");
rte_log_set_level(mytype, RTE_LOG_INFO);
```

> **RTE_LOG_REGISTER 默认宏在 DPDK 21+ 已经从 `RTE_LOG_REGISTER()` (旧: 1 参数) 改为 `RTE_LOG_REGISTER(type, name, level)` (3 参数)**，调用前先看 `rte_log.h` 当前定义。

### 1.5 EAL 日志参数

```bash
# 全局级别
./myapp --log-level=debug

# 特定类型 (格式: type:level, 可多个逗号分隔)
./myapp --log-level=user1:debug,pmd:info

# 用 glob 匹配多个类型
./myapp --log-level='pmd.net.*:debug'

# 禁用所有日志
./myapp --log-level=emergency

# 关闭彩色 (TTY 默认开)
./myapp --log-color=never

# 启动时不打印 banner
./myapp --log-level=notice
```

### 1.6 重定向日志到文件

```c
#include <rte_log.h>

/* 重定向到文件 (传 NULL 恢复 stderr) */
FILE *log_fp = fopen("/var/log/myapp.log", "a");
rte_openlog_stream(log_fp);

/* 运行时切换 (信号处理里也能调) */
rte_openlog_stream(NULL);  // 恢复 stderr
```

### 1.7 运行时调整日志级别

```c
#include <rte_log.h>

/* 全局 */
rte_log_set_global_level(RTE_LOG_DEBUG);

/* 单独类型 */
rte_log_set_level(RTE_LOGTYPE_USER1, RTE_LOG_DEBUG);
rte_log_set_level(RTE_LOGTYPE_PMD,    RTE_LOG_INFO);

/* 用名字查 type (适合配置文件场景) */
int type = rte_log_register("myapp");   // 已有则返回 id
rte_log_set_level(type, RTE_LOG_DEBUG);

/* 正则匹配批量设置 (名字末尾多个 p) */
rte_log_set_level_regexp("pmd\\.net\\..*", RTE_LOG_DEBUG);
rte_log_set_level_pattern("user*", RTE_LOG_INFO);  // glob 风格
```

### 1.8 错误: 那些不存在的 API

```c
/* ❌ 这些函数都不存在 */

/* 不存在 */
rte_assert(cond, "msg");             // 应该是 RTE_ASSERT(cond)
rte_dump_registers();                // 20.11 已移除
rte_set_assert_handler(handler);     // 不存在
rte_set_panic_handler(handler);      // 不存在
rte_log_set_color(level, COLOR_RED); // 颜色是内部 enum,不暴露

/* ❌ typo */
rte_pktmbuf_pktlen(m);               // 应该是 rte_pktmbuf_pkt_len(m)
rte_log_set_level_regex(...);        // 应该是 rte_log_set_level_regexp(...)
```

---

## 2. Assert / Panic 机制

### 2.1 RTE_ASSERT vs rte_panic

DPDK 提供两套"必须为真"的检查，**功能不同**：

| 宏                    | 触发时行为                            | 是否受 RTE_ENABLE_ASSERT 控制 | 用途                 |
| --------------------- | ------------------------------------- | ----------------------------- | -------------------- |
| `RTE_ASSERT(cond)`    | 打印 + `rte_dump_stack()` + `abort()` | **是** (默认开)               | 内部不变式检查       |
| `RTE_VERIFY(cond)`    | 同上                                  | **是**                        | 同上, 强调"必须为真" |
| `rte_panic(fmt, ...)` | 打印 + dump + `abort()`               | 否 (总是开)                   | 不可恢复错误         |

```c
#include <rte_debug.h>

/* 内部不变式: 开发期检查, release 编译会优化掉 */
RTE_ASSERT(rte_pktmbuf_pkt_len(m) > 0);
RTE_ASSERT(port_id < RTE_MAX_ETHPORTS);

/* 不可恢复: 总是启用 */
if (rxq == NULL)
    rte_panic("RX queue allocation failed for port %u\n", port_id);
```

### 2.2 编译期控制

```bash
# 默认: RTE_ENABLE_ASSERT=1, assert 生效
meson setup build
ninja -C build

# Release 构建: 关闭 assert (meson buildtype=release)
meson setup build --buildtype=release
ninja -C build

# 手动覆盖 (比如想要 release + 保留 assert)
meson setup build -Dc_args=-DRTE_ENABLE_ASSERT
ninja -C build
```

> **关键点**: `RTE_ASSERT` 在 release 构建里会被编成 `do {} while (0)`，整个条件表达式都不会求值。代码里**不要**写有副作用的 assert 条件。

### 2.3 错误: 自定义 assert handler

```c
/* ❌ 错误: 这些 API 不存在 */
void my_handler(const char *func, const char *file, int line,
                const char *cond, const char *exp) {
    fprintf(stderr, "ASSERT: %s:%d\n", file, line);
    abort();
}
rte_set_assert_handler(my_handler);   // 编译不过
```

DPDK **没有公开的自定义 assert handler 接口**。`rte_panic` 和 `RTE_ASSERT` 内部固定走 `rte_dump_stack()` + `abort()`。

如果想要自定义行为, 唯一办法是**包一层宏**：

```c
#define MY_ASSERT(cond) do {                                           \
    if (!(cond)) {                                                      \
        fprintf(stderr, "[%s:%d] MY_ASSERT(%s) failed\n",              \
                __func__, __LINE__, #cond);                            \
        rte_dump_stack();                                              \
        abort();                                                       \
    }                                                                   \
} while (0)
```

---

## 3. Mbuf 完整性检查

### 3.1 编译期门控

mbuf sanity check 是 DPDK 调试最常用的工具, 但默认**不编译进去**：

```bash
# 启用 mbuf debug (会大幅影响性能, 慢 30%+)
meson setup build -Dc_args=-DRTE_LIBRTE_MBUF_DEBUG
ninja -C build
```

启用后, `rte_pktmbuf_alloc` 等函数会做额外检查。

### 3.2 两个不同的 API

| 函数                                    | 行为                            | 返回 |
| --------------------------------------- | ------------------------------- | ---- |
| `rte_mbuf_sanity_check(m, is_header)`   | 失败**直接 panic + abort**      | void |
| `rte_mbuf_check(m, is_header, &reason)` | 失败**返回 -1 + reason 字符串** | int  |

```c
#include <rte_mbuf.h>

/* 检查失败直接 abort (适合 ASSERT 路径) */
rte_mbuf_sanity_check(m, 0);   // is_header=0 表示非 header mbuf

/* 检查失败返回 -1 (适合运行时检查) */
const char *reason = NULL;
if (rte_mbuf_check(m, 0, &reason) < 0) {
    RTE_LOG(ERR, USER1, "Corrupt mbuf %p: %s\n", m, reason);
    return -1;
}
```

### 3.3 常见检查项

mbuf debug 启用后, 自动检查这些项:

```
✓ buf_iova 是否对齐
✓ data_off 是否在 [0, buf_len] 范围
✓ data_len + data_off <= buf_len
✓ nb_segs 与 segs->next 链长度一致
✓ refcnt 至少为 1
✓ pkt_len = sum(seg.data_len)
✓ next 指针不能成环
```

---

## 4. Core Dump 与 GDB Post-Mortem

### 4.1 配置 core dump

DPDK 应用通常 root 跑, 配 core dump 三步:

```bash
# 1. 解除大小限制
ulimit -c unlimited

# 2. 配置 core pattern (带 PID + 时间戳, 避免覆盖)
echo '/tmp/core-%e-%p-%t' | sudo tee /proc/sys/kernel/core_pattern
#  %e: 可执行文件名
#  %p: PID
#  %t: 时间戳 (秒)
#  推荐加 %h (hostname) 区分多机

# 3. 验证设置
cat /proc/sys/kernel/core_pattern
ulimit -c

# 4. (可选) 关闭 apport (Ubuntu) 避免它截胡
sudo systemctl disable apport
```

### 4.2 GDB 加载 core

```bash
# 1. 找到 core
ls /tmp/core-myapp-12345-*

# 2. 加载二进制 + core
gdb /path/to/myapp /tmp/core-myapp-12345-1700000000

# 3. 第一件事: 看堆栈
(gdb) bt full
#  #0  rte_panic (fmt=0x...) at eal_common_debug.c:42
#  #1  my_check_mbuf (m=0x...) at myapp.c:120
#  #2  process_packet (m=0x...) at myapp.c:200
#  #3  lcore_main () at myapp.c:300
#  关键看 #1 和 #2 的局部变量

# 4. 看当前帧的变量
(gdb) frame 1
(gdb) info locals
(gdb) print m
(gdb) print *m
# 注意: hugepage 地址在 GDB 里能直接看, 不用重新映射

# 5. 看其他线程
(gdb) info threads
(gdb) thread 3
(gdb) bt
```

### 4.3 GDB 自动化脚本

把常用命令写成 `.gdbinit`, 调试 DPDK 效率翻倍:

```gdb
# ~/.gdbinit 或项目根 .gdbinit
set pagination off
set print pretty on
set print array on
set scheduler-locking on

# 漂亮打印 mbuf
define dpdk-mbuf
    printf "mbuf %p:\n", $arg0
    printf "  buf_addr       = %p\n", $arg0->buf_addr
    printf "  buf_iova       = 0x%lx\n", $arg0->buf_iova
    printf "  buf_len        = %u\n", $arg0->buf_len
    printf "  data_off       = %u\n", $arg0->data_off
    printf "  data_len       = %u\n", $arg0->data_len
    printf "  pkt_len        = %u\n", $arg0->pkt_len
    printf "  nb_segs        = %u\n", $arg0->nb_segs
    printf "  next           = %p\n", $arg0->next
    printf "  ol_flags       = 0x%lx\n", $arg0->ol_flags
    printf "  packet_type    = 0x%x\n", $arg0->packet_type
end
document dpdk-mbuf
    Print key fields of a rte_mbuf pointer
end

# 漂亮打印 rte_ring
define dpdk-ring
    printf "ring %s (%p):\n", $arg0->name, $arg0
    printf "  size           = %u\n", $arg0->size
    printf "  mask           = 0x%x\n", $arg0->mask
    printf "  prod.head      = %u\n", $arg0->prod.head
    printf "  prod.tail      = %u\n", $arg0->prod.tail
    printf "  cons.head      = %u\n", $arg0->cons.head
    printf "  cons.tail      = %u\n", $arg0->cons.tail
end
document dpdk-ring
    Print rte_ring producer/consumer state
end

# 漂亮打印 rte_mempool
define dpdk-mempool
    printf "mempool %s (%p):\n", $arg0->name, $arg0
    printf "  size           = %u\n", $arg0->size
    printf "  cache_size     = %u\n", $arg0->cache_size
    printf "  priv_size      = %u\n", $arg0->priv_size
    printf "  flags          = 0x%x\n", $arg0->flags
    printf "  populated      = %u\n", $arg0->populated_size
end
document dpdk-mempool
    Print rte_mempool summary
end
```

加载:

```bash
gdb -x ~/.gdbinit /path/to/myapp /tmp/core-*

(gdb) dpdk-mbuf 0x7f1234560000
(gdb) dpdk-ring my_ring
(gdb) dpdk-mempool my_pool
```

### 4.4 现场 attach 运行进程

```bash
# 1. 找 pid
PID=$(pidof myapp)

# 2. attach
sudo gdb -p $PID

# 3. (可选) 让进程停下
(gdb) interrupt

# 4. 看所有线程都在干啥
(gdb) info threads
(gdb) thread apply all bt

# 5. 看某个 lcore 栈
(gdb) thread 2
(gdb) bt

# 6. 看完 detach (别 kill)
(gdb) detach
```

---

## 5. 端口统计与运行时观测

### 5.1 基础统计

```c
#include <rte_ethdev.h>

struct rte_eth_stats stats;
if (rte_eth_stats_get(port_id, &stats) == 0) {
    RTE_LOG(INFO, USER1,
        "Port %u: RX %lu pkts (%lu B), TX %lu pkts (%lu B), "
        "RX miss %lu, RX err %lu, TX err %lu, no_mbuf %lu\n",
        port_id,
        stats.ipackets, stats.ibytes,
        stats.opackets, stats.obytes,
        stats.imissed, stats.ierrors, stats.oerrors,
        stats.rx_nombuf);
}

/* 重置 (从此刻开始重新计数) */
rte_eth_stats_reset(port_id);
```

### 5.2 Per-Queue 统计

**没有** `rte_eth_queue_stats_get()` 这个 API。Per-queue 计数在 `rte_eth_stats` 结构体里:

```c
/* 错误 ❌ */
struct rte_eth_queue_stats qstats;
rte_eth_queue_stats_get(port_id, qid, &qstats);  // 不存在

/* 正确 ✓ */
struct rte_eth_stats stats;
rte_eth_stats_get(port_id, &stats);
uint64_t rx_pkts_q5 = stats.q_ipackets[5];
uint64_t tx_pkts_q5 = stats.q_opackets[5];
uint64_t errs_q5    = stats.q_errors[5];
```

但 `q_ipackets[]` 默认是 0, 必须先**映射 queue 到 stat 索引**:

```c
/* 把 queue_id 5 映射到 stat index 0 */
rte_eth_dev_set_rx_queue_stats_mapping(port_id, 5, 0);
rte_eth_dev_set_tx_queue_stats_mapping(port_id, 5, 0);

/* 之后 stats.q_ipackets[0] 就是 queue 5 的计数 */
```

### 5.3 xstats (扩展统计)

PMD 提供的 NIC 级别计数器 (远多于基础 stats):

```c
#include <rte_ethdev.h>

/* 1. 查询 xstat 数量 */
int n = rte_eth_xstats_get(port_id, NULL, 0);

/* 2. 分配并获取 */
struct rte_eth_xstat *xstats = calloc(n, sizeof(*xstats));
int ret = rte_eth_xstats_get(port_id, xstats, n);

/* 3. 打印所有 */
for (int i = 0; i < ret; i++) {
    printf("  %-40s %lu\n", xstats[i].name, xstats[i].value);
}

/* 4. 按 id 查 (知道 id 后) */
uint64_t id = xstats[0].id;  // 比如 "rx_good_packets"
uint64_t val;
rte_eth_xstats_get_by_id(port_id, &id, &val, 1);

/* 5. 按名字查 (字符串 → id) */
int idx = rte_eth_xstats_get_id_by_name(port_id, "rx_good_packets");
if (idx >= 0) {
    rte_eth_xstats_get_by_id(port_id, &xstats[idx].id, &val, 1);
    printf("rx_good_packets = %lu\n", val);
}
```

> `dpdk-proc-info --xstats` 命令正是包了这个 API, 不写代码也能用。

---

## 6. rte_trace 追踪系统 (DPDK 21+)

DPDK 21 引入 `rte_trace`, 性能接近零开销的运行时追踪。比 `RTE_LOG(DEBUG)` 快, 比 `perf` 灵活。

### 6.1 为什么需要 rte_trace

| 工具             | 开销                            | 时序精度 | 灵活性                   |
| ---------------- | ------------------------------- | -------- | ------------------------ |
| `RTE_LOG(DEBUG)` | 中 (每条 log 都格式化 + 写文件) | 毫秒     | 弱 (必须改代码)          |
| `perf`           | 低 (硬件 counter)               | 微秒     | 弱 (看不准是哪个函数)    |
| **rte_trace**    | **极低 (编译时 decide)**        | **纳秒** | **强 (动态开关 + 过滤)** |

### 6.2 编译时埋点

```c
#include <rte_trace.h>

/* 1. 头文件定义 trace point (类似 TRACEPOINT) */
RTE_TRACE_POINT(myapp_packet_rx, RTE_TRACE_POINT_ARGS(
    uint16_t port_id, uint16_t queue_id, uint32_t pkt_len
));

/* 2. 在代码里 trace */
void packet_process(struct rte_mbuf *m) {
    /* 高频路径, 但 rte_trace 默认是 no-op, 几乎零开销 */
    rte_trace_point(myapp_packet_rx,
        m->port, 0, rte_pktmbuf_pkt_len(m));

    /* ... */
}

/* 3. 注册 tracepoint (EAL 启动时) */
RTE_TRACE_POINT_REGISTER(myapp_packet_rx);
```

### 6.3 EAL 参数控制

```bash
# 启用指定 tracepoint
./myapp --trace=myapp.*

# 多 pattern
./myapp --trace=myapp.packet_rx --trace=pmd.net.i40e.rx

# 输出到文件 (默认 stderr)
./myapp --trace=myapp.* --trace-dir=/tmp/traces

# 限制大小 (单位 MB)
./myapp --trace=myapp.* --trace-burstsz=128 --trace-num=10
```

### 6.4 trace 工具查看

```bash
# 1. dump 二进制 trace 为可读格式
dpdk-trace --input /tmp/traces/

# 输出:
# TRACE: myapp.packet_rx
#   port_id=0, queue_id=0, pkt_len=64
#   ts=1234567890ns
```

### 6.5 与 RTE_LOG 的区别

```
RTE_LOG:   程序员的 print, 面向"看"
           适合: 启动信息, 错误, 状态变化
           不适合: 高频事件 (会拖慢数据面)

rte_trace: 程序的飞行记录仪, 面向"事后分析"
           适合: 包到达, ring 操作, 状态转换
           不适合: 长时间运行 (buffer 会满)
```

---

## 7. 内存问题检测

### 7.1 ASan (AddressSanitizer) - 推荐

DPDK 19+ 完整支持 ASan, 编译期开启:

```bash
meson setup build-asan \
    -Db_sanitize=address \
    -Dbuildtype=debugoptimized
ninja -C build-asan
sudo ./build-asan/myapp

# ASan 检测到问题会直接输出:
# ==12345==ERROR: AddressSanitizer: heap-buffer-overflow
# READ of size 8 at 0x7f1234560000
#     #0 0x4abcd in my_check_packet myapp.c:120
#     #1 0x4efgh in lcore_main myapp.c:300
```

**坑**: ASan 和 DPDK 的 `--no-huge` 模式不兼容 (ASan 自身需要小内存模式), 性能慢 5-10x, 仅适合开发期。

### 7.2 Valgrind - 慢但细

```bash
# DPDK 应用跑 valgrind 必须关 hugepage
./myapp --no-huge --valgrind

# valgrind 自己跑 (慢 20-50x)
valgrind --leak-check=full --show-leak-kinds=all --track-origins=yes \
    ./myapp --no-huge
```

**注意**: DPDK 的 mempool 是从 hugepage 分配的, valgrind 看不到 hugepage 区域内的内存访问, 只能检测普通 malloc/free 的问题。

### 7.3 常见内存问题

| 症状            | 工具              | 检查项                          |
| --------------- | ----------------- | ------------------------------- |
| mbuf 越界       | mbuf debug / ASan | `data_off + data_len > buf_len` |
| 多释放同一 mbuf | mbuf debug        | `refcnt > 1` 时还释放           |
| ring 大小不对   | GDB               | `prod.head - cons.head > size`  |
| 段错误 (空指针) | core + GDB        | `bt full`                       |
| 巨页没分配      | dmesg             | `EAL: No hugepages`             |
| 内存泄漏        | valgrind          | 普通 malloc 路径                |

---

## 8. 调试工具箱速查

### 8.1 命令行工具

| 工具                          | 用途                           | 示例                                            |
| ----------------------------- | ------------------------------ | ----------------------------------------------- |
| `dpdk-proc-info`              | 看运行中 DPDK 应用的内部状态   | `dpdk-proc-info -- --stats`                     |
| `dpdk-proc-info -- --xstats`  | 看 xstats (按名字)             | 同上                                            |
| `dpdk-proc-info -- --mempool` | 看 mempool 状态                | 同上                                            |
| `dpdk-proc-info -- --ring`    | 看 ring 状态                   | 需知道 ring 名字                                |
| `dpdk-telemetry`              | 交互式查询 (REST-like socket)  | `dpdk-telemetry -c /var/run/dpdk/xxx/telemetry` |
| `dpdk-dumpcap`                | 像 tcpdump 一样抓包 (PMD 旁路) | `dpdk-dumpcap -i 0 -w /tmp/cap.pcap`            |
| `dpdk-pdump`                  | 抓包主从进程模式               | 启动 pdump 后台, 然后抓                         |
| `dpdk-trace`                  | 解析 rte_trace 二进制          | `dpdk-trace --input trace.ctf`                  |
| `perf`                        | 性能 profiling                 | `perf top -p $(pidof myapp)`                    |
| `bpftrace`                    | 动态追踪                       | 见下方示例                                      |

### 8.2 bpftrace 探测 DPDK

```bash
# 看 rte_eth_tx_burst 调用频率
bpftrace -e 'kprobe:rte_eth_tx_burst { @count++; }' -p $(pidof myapp)

# 看谁在调 mbuf alloc
bpftrace -e '
    kprobe:rte_pktmbuf_alloc {
        @alloc[arg0] = count();
    }
' -p $(pidof myapp)

# 监控 rte_panic (崩溃前)
bpftrace -e '
    kprobe:rte_panic {
        printf("PANIC at %s\n", kstack);
    }
' -p $(pidof myapp)
```

### 8.3 perf profiling

```bash
# 实时 top
sudo perf top -p $(pidof myapp)

# 录制 10 秒, 看调用图
sudo perf record -g -p $(pidof myapp) -- sleep 10
sudo perf report --stdio

# 看 cache miss (为什么数据面慢)
sudo perf stat -e cache-misses,cache-references,L1-dcache-load-misses \
    -p $(pidof myapp) -- sleep 5
```

---

## 9. 常见问题诊断

### 9.1 启动失败

```bash
# 1. 详细日志
./myapp -v   # EAL 自己的 -v
./myapp --log-level=eal:debug

# 2. 巨页不足
# EAL: No free hugepages
# 解: sudo echo 1024 > /proc/sys/vm/nr_hugepages

# 3. 权限
# EAL: Cannot open /dev/vfio/16: Permission denied
# 解: 用户加入 vfio 组, 或 sudo 跑

# 4. IOMMU 没开
# EAL: VFIO not supported
# 解: BIOS 开 VT-d, 内核加 intel_iommu=on
```

### 9.2 运行时崩溃

```bash
# 1. 准备 core
ulimit -c unlimited
echo '/tmp/core-%e-%p-%t' > /proc/sys/kernel/core_pattern

# 2. 复现
./myapp

# 3. 找最新 core
ls -t /tmp/core-myapp-* | head -1

# 4. 分析
gdb ./myapp $(ls -t /tmp/core-myapp-* | head -1)
(gdb) bt full
```

### 9.3 性能不达预期

详见 [[ch30-performance-tuning|第三十章]] 和 [性能调优实战](2026-05-29-dpdk-performance-tuning-practice.md), 简要流程:

```bash
# 1. CPU 是否绑核
ps -eLo pid,lwp,psr,args | grep myapp

# 2. 中断分布
cat /proc/interrupts | grep -E "(eth|NIC)"

# 3. 丢包统计
dpdk-proc-info -- --xstats 2>&1 | grep -iE "(miss|drop|err)"

# 4. perf 看热点
sudo perf top -p $(pidof myapp)
```

---

## 10. 调试宏模板

```c
/* debug.h - 统一的调试头文件 */
#pragma once

#include <rte_log.h>
#include <rte_debug.h>
#include <rte_trace.h>

/* ---------- 日志 ---------- */
#define APP_LOG_TYPE RTE_LOGTYPE_USER1
RTE_LOG_REGISTER(app_log, app, INFO);

#define APP_LOG(level, fmt, args...) \
    rte_log(RTE_LOG_ ## level, APP_LOG_TYPE, \
            "[%s:%d] " fmt "\n", __func__, __LINE__, ##args)

/* ---------- Assert ---------- */
#ifdef RTE_ENABLE_ASSERT
#define APP_ASSERT(cond) do {                                    \
    if (!(cond)) {                                                \
        APP_LOG(ERR, "ASSERT failed: %s", #cond);                 \
        rte_dump_stack();                                         \
        abort();                                                  \
    }                                                             \
} while (0)
#else
#define APP_ASSERT(cond) do {} while (0)
#endif

/* ---------- Hex dump ---------- */
#define APP_DUMP(label, buf, len) \
    rte_hexdump(stdout, label, buf, len)

/* ---------- Trace ---------- */
RTE_TRACE_POINT(app_trace_rx,
    RTE_TRACE_POINT_ARGS(uint16_t port, uint16_t len));

#define APP_TRACE_RX(port, len) \
    rte_trace_point(app_trace_rx, port, len)

/* ---------- 运行时检查 ---------- */
static inline int app_check_mbuf(struct rte_mbuf *m) {
    const char *reason = NULL;
    if (rte_mbuf_check(m, 0, &reason) < 0) {
        APP_LOG(ERR, "Bad mbuf %p: %s", m, reason);
        return -1;
    }
    return 0;
}
```

注册 (main 启动时):

```c
int main(int argc, char **argv) {
    rte_eal_init(argc, argv);
    RTE_TRACE_POINT_REGISTER(app_trace_rx);
    /* ... */
}
```

---

## 11. 小结

| 工具             | 用途               | 何时用             |
| ---------------- | ------------------ | ------------------ |
| `RTE_LOG`        | 静态日志, 状态变化 | 启动/错误/关键事件 |
| `RTE_ASSERT`     | 内部不变式         | release 关闭       |
| `rte_panic`      | 不可恢复错误       | 永远开启           |
| `rte_trace`      | 高频事件追踪       | 性能瓶颈定位       |
| `mbuf debug`     | mbuf 越界/损坏     | 开发期             |
| `core + GDB`     | 崩溃分析           | 段错误后           |
| `ASan`           | 内存越界/UAF       | 开发期             |
| `dpdk-proc-info` | 远程状态查询       | 线上排查           |
| `dpdk-telemetry` | 交互式查询         | 自动化监控         |
| `perf`           | CPU 热点           | 性能问题           |

调试的原则:

1. **预防 > 检测 > 善后**: 加 assert 比事后 gdb 强
2. **trace > log**: 高频事件用 rte_trace
3. **post-mortem 优先**: core dump 永远开着, 线上事故少跑现场
4. **不要 printf 调试**: 数据面用 RTE_LOG 或 rte_trace, 不要裸 printf

---

> 参考:
>
> - [[ch31-debugging-tools|DPDK 深度探索 (三十一)：DPDK 调试工具]]
> - [[ch30-performance-tuning|DPDK 深度探索 (三十)：性能调优]]
> - DPDK Programmer's Guide: Logging, https://doc.dpdk.org/guides/prog_guide/log_lib.html
> - DPDK rte_trace documentation, https://doc.dpdk.org/guides/prog_guide/trace_lib.html
> - GDB User Manual, https://sourceware.org/gdb/documentation/
> - AddressSanitizer, https://clang.llvm.org/docs/AddressSanitizer.html
> - DPDK API: `lib/log/rte_log.h`, `lib/eal/include/rte_debug.h`, `lib/mbuf/rte_mbuf.h`
