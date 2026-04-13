---
title: "VPP 深入探讨 ch26：测试与调试"
date: 2026-04-10 07:00:00
tags: [vpp, test, unittest, framework, debugging, gdb, trace, assert]
description: "深入解析 VPP 测试与调试：单元测试框架、集成测试、性能测试、调试工具、常见问题排查"
---

# VPP 深入探讨 ch26：测试与调试

> [!abstract] 核心要点
> VPP 提供完整的测试框架。本章深入解析单元测试、集成测试、性能测试、调试工具与常见问题排查。

## 1. 测试框架

### 1.1 测试架构

```
┌─────────────────────────────────────────────────────────────┐
│                    VPP Test 框架                           │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              VPP Test Framework (VAT)                  │  │
│  │                                                       │  │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐           │  │
│  │  │ Unit    │  │ Integ    │  │ Perf    │           │  │
│  │  │ Tests   │  │ Tests    │  │ Tests   │           │  │
│  │  └──────────┘  └──────────┘  └──────────┘           │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### 1.2 测试类型

```
1. 单元测试 (Unit Tests)
   - 测试独立函数
   - 快速执行
   - mock 依赖

2. 集成测试 (Integration Tests)
   - 测试节点组合
   - 端到端
   - 使用 vppapigen

3. 性能测试 (Performance Tests)
   - 吞吐量
   - 延迟
   - PPS

4. 回归测试 (Regression Tests)
   - 自动 CI/CD
   - 防止破坏
```

## 2. 单元测试

### 2.1 测试宏

```c
// my_test.c

#include <vpp/test.h>

// 测试函数声明
static void test_my_function(void);

// 测试用例
clib_error_t *
test_my_cases(void)
{
    // 测试 1
    test("my_function basic", test_my_function);

    // 测试 2
    test_equal("addition", 2 + 2, 4);

    // 测试 3
    test_not_equal("string compare",
                   strcmp("hello", "world"), 0);

    return NULL;
}

// 运行测试
int
main(int argc, char *argv[])
{
    return vlib_test_main(test_my_cases);
}
```

### 2.2 断言宏

```c
// 常用断言
TEST_ASSERT(condition, "message");
TEST_ASSERT_EQUAL(expected, actual);
TEST_ASSERT_NOT_EQUAL(expected, actual);
TEST_ASSERT_NULL(ptr);
TEST_ASSERT_NOT_NULL(ptr);
TEST_ASSERT_TRUE(condition);
TEST_ASSERT_FALSE(condition);

// 内存断言
TEST_ASSERT_MEM_EQUAL(expected, actual, size);
TEST_ASSERT_MEM_NOT_EQUAL(expected, actual, size);

// 浮点断言
TEST_ASSERT_FLOAT_EQUAL(expected, actual, tolerance);
```

### 2.3 测试示例

```c
// my_utility_test.c

#include <vpp/test.h>

// 测试函数
u32
my_calculate(u32 input)
{
    return input * 2;
}

// 测试用例
static void
test_my_calculate(void)
{
    // 基本测试
    TEST_ASSERT_EQUAL(10, my_calculate(5));

    // 边界测试
    TEST_ASSERT_EQUAL(0, my_calculate(0));
    TEST_ASSERT_EQUAL(UINT32_MAX, my_calculate(UINT32_MAX / 2));
}

// 运行测试
int
main(int argc, char *argv[])
{
    test("my_calculate", test_my_calculate);
    return 0;
}
```

## 3. 节点测试

### 3.1 节点测试框架

```c
// my_node_test.c

#include <vpp/test.h>
#include <vpp/node.h>

// 测试节点
VLIB_REGISTER_NODE(my_test_node) = {
    .name = "my-test",
    .function = my_test_node_fn,
    // ...
};

// 准备输入 frame
static void
my_setup_frame(vlib_main_t *vm, u32 *buffers, u32 n_buffers)
{
    vlib_frame_t *f = vlib_get_frame(vm, my_test_node.index);

    // 添加 buffer
    u32 *from = vlib_frame_vector_args(f);
    for (u32 i = 0; i < n_buffers; i++) {
        from[i] = buffers[i];
    }
    f->n_vectors = n_buffers;
}

// 测试节点
static void
test_my_node(void)
{
    vlib_main_t *vm = vlib_get_main();
    u32 buffers[10];

    // 准备 buffer
    for (int i = 0; i < 10; i++) {
        buffers[i] = vlib_buffer_alloc(vm, 1);
    }

    // 设置 frame
    my_setup_frame(vm, buffers, 10);

    // 运行节点
    u32 n = my_test_node.function(vm, NULL, NULL);

    // 验证结果
    TEST_ASSERT_EQUAL(10, n);
}
```

### 3.2 模拟输入

```c
// 模拟接收包
static void
my_simulate_rx(vlib_main_t *vm,
                u32 interface,
                u8 *packet_data,
                u32 packet_len)
{
    // 分配 buffer
    u32 bi = vlib_buffer_alloc(vm, 1);
    vlib_buffer_t *b = vlib_get_buffer(vm, bi);

    // 填充数据
    clib_memcpy(b->data, packet_data, packet_len);
    b->current_length = packet_len;

    // 设置接口
    vnet_buffer(b)->sw_if_index[VLIB_RX] = interface;

    // 发送到节点
    vlib_node_runtime_t *node = vlib_node_get_runtime(vm, my_input_node.index);
    vlib_put_next_frame(vm, node, MY_NEXT_PROCESS, bi);
}
```

## 4. 集成测试

### 4.1 VPP-API 测试

```python
# my_plugin_test.py
from vpp_papi import VPP
import unittest

class TestMyPlugin(unittest.TestCase):
    def setUp(self):
        self.vpp = VPP("/run/vpp/api.sock")
        self.vpp.connect()

    def tearDown(self):
        self.vpp.disconnect()

    def test_my_hello(self):
        # 发送 hello
        msg = {
            "client_index": 0,
            "context": 1,
            "plugin_id": 42,
        }

        reply = self.vpp.api.my_plugin_hello(msg)

        # 验证
        self.assertEqual(reply["retval"], 0)
        self.assertEqual(reply["plugin_id"], 42)

    def test_my_config(self):
        # 测试配置
        self.vpp.api.my_plugin_config({"value": 100})
```

### 4.2 CLI 测试

```python
# test_cli.py
from vpp_papi import VPP

def test_cli():
    vpp = VPP("/run/vpp/cli.sock")
    vpp.connect()

    # 发送 CLI 命令
    reply = vpp.cli("show my")

    # 验证输出
    assert "My Plugin" in reply
    assert "value: 42" in reply

    # 设置值
    vpp.cli("set my value 100")

    # 验证
    reply = vpp.cli("show my")
    assert "value: 100" in reply
```

## 5. 性能测试

### 5.1 Benchmark 框架

```c
// my_perf_test.c

#include <vpp/test.h>

// 性能测试
static void
test_throughput(void)
{
    vlib_main_t *vm = vlib_get_main();
    u64 start, end;
    u32 iterations = 1000000;

    // 开始计时
    start = clib_cpu_time_now();

    // 执行
    for (u32 i = 0; i < iterations; i++) {
        my_process_function();
    }

    // 结束计时
    end = clib_cpu_time_now();

    // 计算
    u64 ns_per_op = (end - start) / iterations;
    double mpps = (double)iterations / (end - start) * 1e9 / 1e6;

    // 输出
    printf("Throughput: %.2f Mpps\n", mpps);
    printf("Latency: %lu ns/op\n", ns_per_op);
}
```

### 5.2 pps 测试

```c
// pps_test.c

// 测试包处理速率
static void
test_pps(u32 duration_ms)
{
    vlib_main_t *vm = vlib_get_main();
    u64 start, end;
    u32 count = 0;

    // 准备包
    u32 buffers[1024];
    u32 n_buffers = vlib_buffer_alloc(vm, buffers, 1024);

    // 开始
    start = clib_cpu_time_now();
    u64 deadline = start + duration_ms * 1000 * 1000;

    // 处理
    while (clib_cpu_time_now() < deadline) {
        for (u32 i = 0; i < n_buffers; i++) {
            process_packet(buffers[i]);
            count++;
        }
    }

    // 计算
    end = clib_cpu_time_now();
    double pps = (double)count / (end - start) * 1e9;

    printf("PPS: %.2f Mpps\n", pps / 1e6);
}
```

## 6. 调试工具

### 6.1 GDB 调试

```bash
# 启动 VPP in GDB
gdb --args vpp -c /etc/vpp/startup.conf

# 或者
vgdb --vgdb-error=0 vpp

# GDB 命令
(gdb) break my_function
(gdb) run
(gdb) bt  # backtrace
(gdb) print variable
(gdb) info threads
(gdb) thread apply all bt
```

### 6.2 日志

```bash
# 启用日志
vpp# set logging on
vpp# set logging class all level debug

# 查看日志
vpp# show logging

# 日志输出
# /var/log/vpp/vpp.log
```

### 6.3 Trace

```bash
# 启用 trace
vpp# trace add my-node 100

# 运行一些操作
vpp# set my value 100

# 查看 trace
vpp# show trace

# 清除 trace
vpp# clear trace
```

## 7. 常见问题排查

### 7.1 包丢失

```bash
# 检查 drop 计数器
vpp# show errors

# 示例输出：
# Node          Error           Count
# ip4-input     no next node   100
# my-node       buffer error   50

# 检查 buffer 统计
vpp# show buffers

# 检查接口统计
vpp# show interface
```

### 7.2 内存问题

```bash
# 检查内存
vpp# show memory

# 示例输出：
# Total: 2048 MB
# Used: 1024 MB (50%)
# OOM: 0

# 检查 buffer pool
vpp# show buffer

# 检查 hugepages
cat /proc/meminfo | grep HugePages
```

### 7.3 性能问题

```bash
# 检查节点负载
vpp# show node

# 示例输出：
# Name              Active    Vectors   Suspends
# ip4-lookup        1         1000      0
# my-node           1         0         0

# 检查线程
vpp# show threads

# 检查 CPU 使用
top -H
```

## 8. 总结

测试金字塔：

```
┌─────────────────────────────────────────────────────────────┐
│                    Test Pyramid                             │
│                                                              │
│                         ▲                                    │
│                        /│\                                  │
│                       / │ \                                 │
│                      /  │  \                                │
│                     /   │   \                               │
│                    /    │    \                              │
│                   /     │     \                             │
│                  /      │      \                            │
│                 /       │       \                           │
│                /________│________\                          │
│               Unit     Integ    Perf                        │
└─────────────────────────────────────────────────────────────┘
```

调试命令：

| 命令 | 用途 |
|------|------|
| `show errors` | 错误统计 |
| `show trace` | 包追踪 |
| `show buffers` | Buffer 状态 |
| `show memory` | 内存使用 |
| `show node` | 节点状态 |
| `show interface` | 接口统计 |

---

## 参考资源

- [VPP Testing](https://wiki.fd.io/view/VPP/Test_Framework)
- [VPP Debugging](https://wiki.fd.io/view/VPP/Debugging_VPP)
- [VPP Testing Tutorial](https://wiki.fd.io/view/VPP/Unit_Tests_Tutorial)
