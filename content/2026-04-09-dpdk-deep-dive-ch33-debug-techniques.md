---
title: "DPDK 第三十三章：调试技巧：日志、assert、crash 分析"
date: 2026-04-09 15:43:0
tags: [dpdk, debugging, logging, assert, crash-analysis]
description: "深入解析 DPDK 调试技术：日志系统、assert 机制、crash dump 分析与常见问题诊断"
---

# DPDK 第三十三章：调试技巧：日志、assert、crash 分析

> [!abstract] 核心要点
> DPDK 应用程序调试需要系统化的方法。本章覆盖 RTE_LOG 日志系统、自定义 assert、crash 分析、内存检测与性能诊断工具。

## 1. DPDK 日志系统

### 1.1 架构概述

DPDK 使用统一的日志框架，核心是 `rte_log`：

```c
// log 级别（从低到高）
enum {
    RTE_LOG_EMERG  = 0,   // 系统不可用
    RTE_LOG_ALERT  = 1,   // 需要立即处理
    RTE_LOG_CRIT   = 2,   // 严重错误
    RTE_LOG_ERR    = 3,   // 错误条件
    RTE_LOG_WARNING = 4,   // 警告
    RTE_LOG_NOTICE = 5,   // 正常但重要
    RTE_LOG_INFO   = 6,   // 信息
    RTE_LOG_DEBUG  = 7,   // 调试信息
};
```

### 1.2 基础 API

```c
#include <rte_log.h>

// 基础日志函数
rte_log(level, type, "format string", ...);

// 示例
rte_log(RTE_LOG_INFO, RTE_LOGTYPE_USER1, "Port %u initialized\n", port_id);

// 全局日志级别设置
rte_log_set_global_level(RTE_LOG_DEBUG);

// 类型级别单独设置
rte_log_set_level(RTE_LOGTYPE_PMD, RTE_LOG_INFO);
```

### 1.3 自定义日志类型

```c
// 定义自己的日志类型
#define RTE_LOGTYPE_MYAPP RTE_LOGTYPE_USER1

// 使用
RTE_LOG(INFO, MYAPP, "Processing packet on port %u\n", port_id);
RTE_LOG(ERR, MYAPP, "Failed to allocate mbuf: %s\n", strerror(errno));
```

### 1.4 EAL 日志参数

```bash
# 启动时配置日志
./myapp --log-level=debug

# 只显示特定类型的日志
./myapp --log-level=user1:debug

# 禁用所有日志
./myapp --log-level=error

# 保存日志到文件（需要代码配合）
rte_openlog_stream(fp);  // 自定义日志输出流
```

### 1.5 彩色日志输出

```c
// 启用控制台彩色输出
rte_log_set_color(RTE_LOG_ERR,    CONSOLE_COLOR_RED);
rte_log_set_color(RTE_LOG_WARNING, CONSOLE_COLOR_YELLOW);
rte_log_set_color(RTE_LOG_INFO,    CONSOLE_COLOR_GREEN);
```

### 1.6 结构化日志实践

```c
// 推荐的日志格式
#define LOG(level, fmt, args...) \
    rte_log(RTE_LOG_ ## level, RTE_LOGTYPE_USER1, \
            "[%s:%d] " fmt "\n", __func__, __LINE__, ##args)

// 使用
LOG(INFO, "Initializing port %u", port_id);
LOG(ERR, "Mbuf allocation failed: %s", rte_strerror(rte_errno));
LOG(DEBUG, "Packet hash: %u", hash_value);
```

## 2. Assert 机制

### 2.1 DPDK assert 宏

```c
#include <rte_debug.h>

// 标准 assert（DEBUG 模式生效）
RTE_ASSERT(cond);

// 带消息的 assert
rte_assert(cond, "invalid mbuf size");

// 致命 assert（会直接 abort）
rte_panic("reached unreachable code");
```

### 2.2 NDEBUG 模式

```c
// 默认 DEBUG 模式：assert 生效
// 生产模式编译：-DNDEBUG
cc -O2 -DNDEBUG ...

// 代码中检查
#ifdef RTE_DEBUG
    // 仅调试模式执行的检查
    rte_mbuf_sanity_check(mbuf);
#endif
```

### 2.3 自定义 assert 处理器

```c
#include <rte_debug.h>

// 自定义 assert 处理函数
static void
my_assert_handler(const char *func, const char *file, int line,
                  const char *cond, const char *exp)
{
    fprintf(stderr, "ASSERT: %s:%d:%s: %s\n",
            file, line, func, cond);
    
    // 可以选择 dump 更多信息
    rte_dump_stack();
    rte_dump_registers();
    
    // abort 或 longjmp
    abort();
}

// 设置自定义处理器
rte_set_assert_handler(my_assert_handler);
```

### 2.4 防御性编程

```c
// 输入验证宏
#define VALID_PORT(port) do { \
    if ((port) >= RTE_MAX_ETHPORTS) { \
        RTE_LOG(ERR, USER1, "Invalid port %u\n", port); \
        return -EINVAL; \
    } \
} while (0)

// mbuf 有效性检查
static inline int
check_mbuf(struct rte_mbuf *mbuf)
{
    if (mbuf == NULL) {
        RTE_LOG(ERR, USER1, "NULL mbuf\n");
        return -1;
    }
    if (!rte_mbuf_check(mbuf, 0)) {
        RTE_LOG(ERR, USERV1, "Invalid mbuf\n");
        return -1;
    }
    if (rte_pktmbuf_pktlen(mbuf) == 0) {
        RTE_LOG(WARNING, USER1, "Zero-length packet\n");
    }
    return 0;
}
```

## 3. Crash 分析

### 3.1 Segmentation Fault 处理

```c
#include <rte_debug.h>
#include <signal.h>

// 注册 signal handler
static void
sig_handler(int sig)
{
    if (sig == SIGSEGV) {
        fprintf(stderr, "Caught SIGSEGV, dumping state...\n");
        rte_dump_stack();
        rte_dump_registers();
        rte_exit(EXIT_FAILURE, "Segmentation fault\n");
    }
}

// 在 main() 初始化时注册
signal(SIGSEGV, sig_handler);
signal(SIGABRT, sig_handler);
```

### 3.2 Core Dump 配置

```bash
# 查看当前限制
ulimit -c

# 设置 unlimited
ulimit -c unlimited

# 配置 core dump 路径和格式
echo "/tmp/core-%e-%p-%t" > /proc/sys/kernel/core_pattern

# - %e: 可执行文件名
# - %p: 进程 ID
# - %t: 时间戳
```

### 3.3 GDB 调试 DPDK 应用

```bash
# 启动调试
gdb ./myapp

# 设置断点
(gdb) break rte_eth_tx_burst
(gdb) break my_custom_function

# 查看变量
(gdb) print port_id
(gdb) print *mbuf

# 单步执行
(gdb) next
(gdb) step

# 查看内存
(gdb) x/16x 0x7f8a00000000

# 查看调用栈
(gdb) bt

# 附加到运行中的进程
(gdb) attach $(pidof myapp)
```

### 3.4 GDB 脚本自动化

```gdb
# dpdk_debug.gdb
set pagination off
set print pretty on
set print array on

# 定义命令：dump mbuf
define dump_mbuf
    printf "mbuf: %p\n", $arg0
    printf "  buf_addr: %p\n", (void*)$arg0->buf_addr
    printf "  buf_iova: 0x%lx\n", $arg0->buf_iova
    printf "  pkt_len: %u\n", $arg0->pkt_len
    printf "  data_len: %u\n", $arg0->data_len
end

# 定义命令：dump ring
define dump_ring
    printf "ring: %s\n", $arg0->name
    printf "  prod.head: %u\n", $arg0->prod.head
    printf "  prod.tail: %u\n", $arg0->prod.tail
    printf "  cons.head: %u\n", $arg0->cons.head
    printf "  cons.tail: %u\n", $arg0->cons.tail
end

# 加载时自动执行
source dpdk_debug.gdb
```

### 3.5 Post-Mortem 分析

```bash
# 1. 加载 core dump
gdb ./myapp /tmp/core-myapp-12345-1699999999

# 2. 查看崩溃位置
(gdb) bt

# 输出示例：
# #0  0x00007f8a1c2e4567 in rte_eth_tx_burst ()
# #1  0x0000000000401234 in send_packets (port=0)
# #2  0x0000000000401567 in main ()

# 3. 检查局部变量
(gdb) frame 1
(gdb) info locals

# 4. 检查寄存器
(gdb) info registers

# 5. 查看内存
(gdb) x/16x $rsi
```

## 4. 内存问题检测

### 4.1 Memzone 检查

```c
#include <rte_memzone.h>

// 查找已分配的 memzone
const struct rte_memzone *mz;
mz = rte_memzone_lookup("my_mz");
if (mz == NULL) {
    RTE_LOG(ERR, USER1, "Memzone not found!\n");
}

// 遍历所有 memzone
struct rte_memzone *mz;
for (mz = rte_memzone_get_start(); 
     mz < rte_memzone_get_end(); 
     mz++) {
    if (mz->addr != NULL) {
        printf("MZ: %s, size: %zu, addr: %p\n",
               mz->name, mz->len, mz->addr);
    }
}
```

### 4.2 Mbuf 完整性检查

```c
// 调试模式下检查 mbuf
int
mbuf_sanity_check(struct rte_mbuf *mbuf)
{
    if (mbuf == NULL) {
        RTE_LOG(ERR, USER1, "NULL mbuf pointer\n");
        return -1;
    }
    
    // 检查 magic number（如果有）
    if (mbuf->magic == 0xDEADBEEF) {
        RTE_LOG(ERR, USER1, "Corrupted mbuf magic\n");
        return -1;
    }
    
    // 检查 headroom/tailroom
    if (mbuf->data_off > mbuf->buf_len) {
        RTE_LOG(ERR, USER1, "Invalid data_off\n");
        return -1;
    }
    
    return 0;
}

// 在关键路径添加检查
if (mbuf_sanity_check(mbuf) < 0) {
    rte_panic("mbuf check failed\n");
}
```

### 4.3 内存泄漏检测

```bash
# 使用 valgrind（性能严重下降）
valgrind --leak-check=full \
         --show-leak-kinds=all \
         --track-origins=yes \
         ./myapp

# 输出示例：
# ==12345== Memcheck, a memory error detector
# ==12345== HEAP SUMMARY:
# ==12345==   definitely lost: 1,024 bytes in 4 blocks
# ==12345==   indirectly lost: 0 bytes
# ==12345==   still reachable: 2,097,152 bytes in 1 blocks
```

### 4.4 地址消毒器 (ASAN)

```bash
# 编译时启用 AddressSanitizer
export CFLAGS="-fsanitize=address -g -O1"
export LDFLAGS="-fsanitize=address"
meson setup build --prefix=$RTE_SDK
ninja -C build

# 运行
./myapp

# 检测到问题时输出：
# AddressSanitizer: heap-buffer-overflow on address 0x7f8a00000000
```

## 5. 性能诊断

### 5.1 DPDK 内部统计

```c
#include <rte_ethdev.h>

// 获取端口统计
struct rte_eth_stats stats;
rte_eth_stats_get(port_id, &stats);

printf("Port %u stats:\n", port_id);
printf("  RX: %lu packets (%lu bytes)\n", 
       stats.ipackets, stats.ibytes);
printf("  TX: %lu packets (%lu bytes)\n", 
       stats.opackets, stats.obytes);
printf("  RX errors: %lu\n", stats.ierrors);
printf("  TX errors: %lu\n", stats.oerrors);
printf("  RX missed: %lu\n", stats.imissed);

// 清除统计
rte_eth_stats_reset(port_id);
```

### 5.2 lcore 统计

```c
#include <rte_ethdev.h>

// 获取队列统计
struct rte_eth_queue_stats qstats;
rte_eth_queue_stats_get(port_id, queue_id, &qstats);

// 获取 xstat（扩展统计）
#define MYCustom_stat(cnt_ids) do { \
    uint64_t val; \
    if (rte_eth_xstats_get_by_id(port_id, cnt_ids, &val, 1) == 0) \
        printf("my_stat: %lu\n", val); \
} while (0)
```

### 5.3 日志级别动态调整

```c
#include <rte_log.h>

// 代码中动态调整日志级别
void
set_log_level_by_type(const char *type_name, int level)
{
    int type = rte_log_register(type_name);
    if (type >= 0) {
        rte_log_set_level(type, level);
    }
}

// 在运行时通过 EAL 参数调整
// --log-level=user1:debug
```

## 6. 常见问题诊断流程

### 6.1 启动失败

```bash
# 1. 使用 -v 参数获取详细日志
./myapp -l 0,1 -v

# 2. 检查 EAL 日志
./myapp -l 0,1 --log-level=eal:debug

# 3. 常见错误及解决方案

# EAL: No available 2048M hugepages
# 解决: echo 4 > /sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages

# EAL: sinfo failed
# 解决: 检查 /dev/isgtapci 是否存在

# EAL: Cannot open %s, Permission denied
# 解决: 使用 sudo 或设置 vfio-pci 用户权限
```

### 6.2 运行时崩溃

```bash
# 1. 启用 core dump
ulimit -c unlimited

# 2. 重新运行
./myapp

# 3. 崩溃后分析
gdb ./myapp /tmp/core-*

# 4. 检查日志文件
tail -f /var/log/syslog
journalctl -u myapp
```

### 6.3 性能异常

```bash
# 1. 检查 CPU 利用率
mpstat -P ALL 1

# 2. 检查中断分布
cat /proc/interrupts | grep eth

# 3. 检查 CPU 绑定
ps -eLo pid,lwp,psr,args | grep myapp

# 4. 使用 perf
perf top -p $(pidof myapp)
perf record -g -p $(pidof myapp) -- sleep 10
perf report
```

## 7. 调试宏定义实践

```c
// debug.h - 统一的调试头文件

#pragma once

#include <rte_log.h>

#ifdef RTE_DEBUG
#define DEBUG_TRACE(fmt, args...) \
    RTE_LOG(DEBUG, USER1, "[%s:%d] " fmt "\n", \
            __func__, __LINE__, ##args)

#define DEBUG_ASSERT(cond) RTE_ASSERT(cond)
#define DUMP_HEX(prefix, addr, len) \
    rte_hexdump(stdout, prefix, addr, len)
#else
#define DEBUG_TRACE(fmt, args...) do {} while(0)
#define DEBUG_ASSERT(cond) do {} while(0)
#define DUMP_HEX(prefix, addr, len) do {} while(0)
#endif

// 使用示例
void
process_packet(struct rte_mbuf *pkt)
{
    DEBUG_TRACE("Processing packet %p, len=%u", 
                pkt, rte_pktmbuf_pktlen(pkt));
    
    DEBUG_ASSERT(rte_pktmbuf_pktlen(pkt) > 0);
    
    // ...
}
```

## 8. 总结

DPDK 调试的关键要点：

1. **日志系统**：善用 `RTE_LOG` 和 `--log-level`
2. **Assert**：DEBUG 模式下启用，生产模式禁用
3. **Core Dump**：配置 limits，保存崩溃现场
4. **GDB**：配合脚本实现自动化诊断
5. **内存检测**：ASAN、valgrind 检测泄漏和越界
6. **防御性编程**：关键路径添加输入验证

**下章预告**：`ch34 - dpdk-procinfo vs ethtool vs netstat`

---

## 参考资源

- [DPDK 日志系统](https://doc.dpdk.org/guides/prog-guide/debug_insights.html)
- [GDB 手动](https://sourceware.org/gdb/documentation/)
- [AddressSanitizer](https://clang.llvm.org/docs/AddressSanitizer.html)
