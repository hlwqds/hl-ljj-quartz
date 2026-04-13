---
title: "VPP 深入探讨 ch24：CLI 命令开发"
date: 2026-04-10 06:00:00
tags: [vpp, cli, command, vlib-cli, argument, parsing, help]
description: "深入解析 VPP CLI：命令注册、参数解析、帮助系统、输出格式化与 CLI 调试"
---

# VPP 深入探讨 ch24：CLI 命令开发

> [!abstract] 核心要点
> VPP CLI 是管理 VPP 的主要接口。本章深入解析 CLI 命令注册、参数解析、帮助系统、输出格式与调试。

## 1. CLI 概述

### 1.1 CLI 架构

```
┌─────────────────────────────────────────────────────────────┐
│                    VPP CLI 架构                             │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              Unix Socket (/run/vpp/cli.sock)         │  │
│  └──────────────────────────────────────────────────────┘  │
│                            ↓                                │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              CLI Parser                               │  │
│  │                                                       │  │
│  │  - Tokenization                                      │  │
│  │  - Argument parsing                                   │  │
│  │  - Command dispatch                                  │  │
│  └──────────────────────────────────────────────────────┘  │
│                            ↓                                │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              Command Handler                          │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### 1.2 CLI Socket

```bash
# 连接 VPP CLI
# 方法1: 使用 vppctl
vppctl -s /run/vpp/cli.sock

# 方法2: 使用 socat
socat - UNIX-CONNECT:/run/vpp/cli.sock

# 方法3: 直接通过 VPP (如果开启)
telnet localhost 5002
```

## 2. CLI 命令注册

### 2.1 命令声明

```c
// my_cli.c

#include <vpp/api/types.h>
#include <vpp/vpp.h>

// CLI 命令定义
VLIB_CLI_COMMAND(my_show_command, static) = {
    .path = "show my",
    .short_help = "show my commands",
    .function = my_show_fn,
};

// 带参数的命令
VLIB_CLI_COMMAND(my_set_command, static) = {
    .path = "set my value",
    .short_help = "set my value <int>",
    .function = my_set_fn,
};
```

### 2.2 完整命令

```c
// 命令结构
typedef struct {
    // 命令路径（空格分隔）
    const char *path;

    // 帮助文本
    const char *short_help;
    const char *long_help;  // 可选

    // 处理函数
    vlib_cli_function_t *function;

    // 特定功能
    u32 command_flags;
} vlib_cli_command_t;

// 命令标志
enum {
    VLIB_CLI_COMMAND_FLAG_INTERACTIVE = (1 << 0),
    VLIB_CLI_COMMAND_FLAG_SUPPRESS_PROMPT = (1 << 1),
    VLIB_CLI_COMMAND_FLAG_NO_REPEAT = (1 << 2),
};
```

## 3. 参数解析

### 3.1 解析函数

```c
// vlib_cli_parse_args 解析参数
static int
my_parse_args(unformat_input_t *input,
              vlib_cli_main_t *cm,
              my_config_t *config)
{
    // 循环解析
    while (unformat_check_input(input) != UNFORMAT_END_OF_INPUT) {
        // 整数
        if (unformat(input, "value %u", &config->value)) {
            // 找到 "value <number>"
        }
        // 字符串
        else if (unformat(input, "name %s", &config->name)) {
            // 找到 "name <string>"
        }
        // 布尔
        else if (unformat(input, "enable")) {
            config->enabled = 1;
        }
        // 帮助
        else if (unformat(input, "help")) {
            return -1;
        }
        else {
            // 未知参数
            return -1;
        }
    }

    return 0;
}
```

### 3.2 常用解析模式

```c
// 整数
u32 value;
if (unformat(input, "%u", &value)) {
    // ...
}

// IP 地址
ip4_address_t ip;
if (unformat(input, "%U", unformat_ip4_address, &ip)) {
    // ...
}

// MAC 地址
u8 mac[6];
if (unformat(input, "%U", unformat_ethernet_address, mac)) {
    // ...
}

// 接口名
u32 sw_if_index;
if (unformat(input, "%U", unformat_sw_interface, cm->vlib_main, &sw_if_index)) {
    // ...
}
```

## 4. 命令处理函数

### 4.1 函数签名

```c
// CLI 函数签名
typedef clib_error_t *
(*vlib_cli_function_t)(vlib_main_t *vm,
                       vlib_cli_command_t *cmd,
                       unformat_input_t *input);

// 简单命令
static clib_error_t *
my_show_fn(vlib_main_t *vm,
           vlib_cli_command_t *cmd,
           unformat_input_t *input)
{
    // 获取插件 main
    my_main_t *pm = &my_main;

    // 打印输出
    vlib_cli_output(vm, "My plugin info:");
    vlib_cli_output(vm, "  value: %u", pm->value);
    vlib_cli_output(vm, "  enabled: %u", pm->enabled);

    return NULL;
}
```

### 4.2 带参数命令

```c
// 带参数的命令
static clib_error_t *
my_set_fn(vlib_main_t *vm,
          vlib_cli_command_t *cmd,
          unformat_input_t *input)
{
    my_main_t *pm = &my_main;
    u32 value = 0;
    int set_value = 0;

    // 解析参数
    while (unformat_check_input(input) != UNFORMAT_END_OF_INPUT) {
        if (unformat(input, "value %u", &value)) {
            set_value = 1;
        }
        else if (unformat(input, "enable")) {
            pm->enabled = 1;
        }
        else if (unformat(input, "disable")) {
            pm->enabled = 0;
        }
        else {
            return clib_error_return(0, "unknown input %U",
                                     format_unformat_error, input);
        }
    }

    if (set_value) {
        pm->value = value;
    }

    return NULL;
}
```

## 5. 输出格式化

### 5.1 基本输出

```c
// 输出到 CLI
vlib_cli_output(vm, "Hello World");

// 格式化输出
vlib_cli_output(vm, "Value: %u, Name: %s", value, name);

// 换行
vlib_cli_output(vm, "Line 1\nLine 2");

// 缩进
vlib_cli_output(vm, "  Indented line");

// 表格
vlib_cli_output(vm, "%-20s %10s", "Name", "Value");
vlib_cli_output(vm, "%-20s %10u", "item1", 100);
```

### 5.2 表格输出

```c
// 格式化表格
vlib_cli_output(vm, "%-20s %12s", "Interface", "Packets");
vlib_cli_output(vm, "%-20s %12lld", "eth0", (long long)packets);
vlib_cli_output(vm, "%-20s %12lld", "eth1", (long long)packets);

// 分隔线
vlib_cli_output(vm, "%-20s%+20s", "Interface", "");
```

## 6. 子命令

### 6.1 子命令树

```c
// show my
VLIB_CLI_COMMAND(my_show_command, static) = {
    .path = "show my",
    .short_help = "show my info",
    .function = my_show_fn,
};

// show my stats
VLIB_CLI_COMMAND(my_show_stats_command, static) = {
    .path = "show my stats",
    .short_help = "show my statistics",
    .function = my_show_stats_fn,
};

// show my config
VLIB_CLI_COMMAND(my_show_config_command, static) = {
    .path = "show my config",
    .short_help = "show my configuration",
    .function = my_show_config_fn,
};

// set my
VLIB_CLI_COMMAND(my_set_command, static) = {
    .path = "set my",
    .short_help = "set my values",
    .function = my_set_fn,
};
```

### 6.2 命令树使用

```bash
vpp# show my
My plugin info:
  value: 42
  enabled: 1

vpp# show my stats
My statistics:
  packets: 1000000
  bytes: 1000000000

vpp# set my value 100
```

## 7. 帮助系统

### 7.1 Help 命令

```bash
# 全局帮助
vpp# help

# 命令帮助
vpp# show my help

# 命令树帮助
vpp# show my ?
```

### 7.2 帮助文本

```c
// 短帮助
.short_help = "show my statistics"

// 长帮助（可选）
.long_help = "Show detailed statistics for my plugin.\n"
             "\n"
             "Example:\n"
             "  show my stats\n",
```

## 8. 调试

### 8.1 CLI 调试

```bash
# 显示所有命令
vpp# show cli

# 显示命令树
vpp# show cli tree

# 显示已注册命令
vpp# show cli commands

# 调试输出
# vlib_cli_output() 会打印到客户端
```

### 8.2 常见错误

```c
// 常见错误处理
if (!pm->initialized) {
    return clib_error_return(0, "my plugin not initialized");
}

// 参数错误
if (value > MAX_VALUE) {
    return clib_error_return(0, "value %u too large (max %u)",
                             value, MAX_VALUE);
}
```

## 9. 完整示例

### 9.1 基本 CLI

```c
// my_cli.c
#include <vpp/vpp.h>

// show my
VLIB_CLI_COMMAND(my_show_command, static) = {
    .path = "show my",
    .short_help = "show my plugin info",
    .function = my_show_fn,
};

// set my
VLIB_CLI_COMMAND(my_set_command, static) = {
    .path = "set my",
    .short_help = "set my plugin options",
    .function = my_set_fn,
};

// show my
static clib_error_t *
my_show_fn(vlib_main_t *vm,
           vlib_cli_command_t *cmd,
           unformat_input_t *input)
{
    my_main_t *pm = &my_main;

    vlib_cli_output(vm, "My Plugin Configuration:");
    vlib_cli_output(vm, "  value: %u", pm->value);
    vlib_cli_output(vm, "  name: %s", pm->name);
    vlib_cli_output(vm, "  enabled: %s", pm->enabled ? "yes" : "no");

    return NULL;
}

// set my
static clib_error_t *
my_set_fn(vlib_main_t *vm,
          vlib_cli_command_t *cmd,
          unformat_input_t *input)
{
    my_main_t *pm = &my_main;

    while (unformat_check_input(input) != UNFORMAT_END_OF_INPUT) {
        if (unformat(input, "value %u", &pm->value)) {
            // 设置值
        }
        else if (unformat(input, "name %s", pm->name)) {
            // 设置名称
        }
        else if (unformat(input, "enable")) {
            pm->enabled = 1;
        }
        else if (unformat(input, "disable")) {
            pm->enabled = 0;
        }
        else {
            return clib_error_return(0, "unknown input %U",
                                     format_unformat_error, input);
        }
    }

    vlib_cli_output(vm, "Configuration updated");

    return NULL;
}
```

## 10. 总结

CLI 命令结构：

```
┌─────────────────────────────────────────────────────────────┐
│                    CLI 命令树                               │
│                                                              │
│  show                                                       │
│  ├── my                                                    │
│  │   ├── info                                              │
│  │   ├── stats                                             │
│  │   └── config                                            │
│  └── interface                                             │
│                                                              │
│  set                                                        │
│  ├── my                                                    │
│  │   ├── value                                            │
│  │   └── name                                             │
│  └── interface                                            │
└─────────────────────────────────────────────────────────────┘
```

解析模式：

| 模式 | 示例 | 解析结果 |
|------|------|----------|
| `%u` | `42` | u32 value |
| `%s` | `hello` | char *str |
| `%U` | `unformat_func` | 自定义解析 |
| `%d` | `-42` | i32 value |

---

## 参考资源

- [VPP CLI](https://wiki.fd.io/view/VPP/CLI)
- [VPP CLI Tutorial](https://wiki.fd.io/view/VPP/CLI_Tutorial)
