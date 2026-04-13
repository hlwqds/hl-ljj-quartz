---
title: "VPP 深入探讨 ch21：Plugin 架构与注册"
date: 2026-04-10 04:30:00
tags: [vpp, plugin, vlib_plugin, module, registration, hook, init]
description: "深入解析 VPP Plugin 架构：Plugin 注册、初始化钩子、依赖管理、Plugin 加载与 Symbol 导出"
---

# VPP 深入探讨 ch21：Plugin 架构与注册

> [!abstract] 核心要点
> VPP 的功能以 Plugin 形式组织。本章深入解析 Plugin 架构、注册机制、初始化钩子、依赖管理与 Symbol 导出。

## 1. Plugin 概述

### 1.1 Plugin 架构

```
┌─────────────────────────────────────────────────────────────┐
│                    VPP Plugin 架构                         │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              VPP Core                                 │  │
│  │  - vlib (向量处理)                                    │  │
│  │  - vnet (网络协议栈)                                  │  │
│  │  - VPP API                                           │  │
│  └──────────────────────────────────────────────────────┘  │
│                            ↓                                │
│  ┌──────────────────────────────────────────────────────┐  │
│  │              Plugins                                  │  │
│  │                                                       │  │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐           │  │
│  │  │  linux-cp│  │  avf     │  │ 肚/span │           │  │
│  │  │  (plugin)│  │  (plugin)│  │ 肚/span │           │  │
│  │  └──────────┘  └──────────┘  └──────────┘           │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### 1.2 Plugin 结构

```
Plugin 文件结构：

┌─────────────────────────────────────────────────────────────┐
│                    Plugin 目录                              │
│                                                              │
│  plugins/my_plugin/                                         │
│  ├── CMakeLists.txt                                        │
│  ├── my_plugin.h                                           │
│  ├── my_plugin.c                                           │
│  ├── my_plugin_test.c                                      │
│  └── __init__.py                                           │
│                                                              │
│  编译产物：                                                  │
│  build/vpp/plugins/libmy_plugin.so                         │
└─────────────────────────────────────────────────────────────┘
```

## 2. Plugin 注册

### 2.1 插件注册宏

```c
// my_plugin.h

// Plugin 描述符
VLIB_PLUGIN_REGISTER() = {
    .version = VPP_BUILD_VER,
    .description = "My Custom Plugin",
    .default_disabled = 1,  // 默认禁用
    .init_priority = 0,     // 初始化优先级
};

// 或使用更详细的注册
#define VLIB_PLUGIN_REGISTER() my_plugin_register(NULL)

static clib_error_t *
my_plugin_register(my_plugin_main_t *pam)
{
    vlib_plugin_t p = {
        .name = "my_plugin",
        .version = "1.0.0",
        .description = "My custom plugin",
        .file_path = __FILE__,
        .default_disabled = 1,
        .init_priority = VLIB_INIT_PRIORITY_DEFAULT,
    };

    return vlib_plugin_register(&p);
}
```

### 2.2 插件主结构

```c
// my_plugin.h
typedef struct {
    // VPP main
    vlib_main_t *vlib_main;

    // API main
    vapi_main_t *vapi_main;

    // 配置
    u32 my_config_value;

    // 统计
    u64 packets_processed;
    u64 bytes_processed;

    // 节点
    u32 my_node_index;

    // 错误
    u32 my_error_code;
} my_plugin_main_t;

// 全局实例
my_plugin_main_t my_plugin_main;
```

### 2.3 初始化函数

```c
// my_plugin.c

// 插件初始化
static clib_error_t *
my_plugin_init(vlib_main_t *vm)
{
    my_plugin_main_t *pm = &my_plugin_main;
    clib_error_t *error = NULL;

    // 获取 vlib main
    pm->vlib_main = vm;

    // 注册节点
    error = my_plugin_nodes_init(vm);
    if (error)
        return error;

    // 注册 API
    error = my_plugin_api_init(vm);
    if (error)
        return error;

    // 设置配置
    pm->my_config_value = 100;

    vlib_log_info(vm->elog_main, "my_plugin initialized");

    return NULL;
}

// 卸载插件
static clib_error_t *
my_plugin_exit(vlib_main_t *vm)
{
    my_plugin_main_t *pm = &my_plugin_main;

    // 清理
    if (pm->my_node_index)
        vlib_node_set_state(vm, pm->my_node_index, VLIB_NODE_STATE_DISABLED);

    return NULL;
}

// 初始化优先级 (可选)
VLIB_INIT_FUNCTION(my_plugin_init);
VLIB_EXIT_FUNCTION(my_plugin_exit);
```

## 3. 初始化钩子

### 3.1 初始化顺序

```
VPP 初始化阶段：

1. EAL init (DPDK)
       ↓
2. 解析命令行参数
       ↓
3. 插件加载 (按优先级)
       ↓
4. 配置读取
       ↓
5. 节点注册
       ↓
6. 接口创建
       ↓
7. Main loop
```

### 3.2 初始化宏

```c
// 初始化函数宏
VLIB_INIT_FUNCTION(my_init)      // 初始化
VLIB_MAIN_LOOP_ENTER_FUNCTION(my_enter)  // 进入主循环前
VLIB_MAIN_LOOP_EXIT_FUNCTION(my_exit)     // 退出主循环时
VLIB_NODE_INIT_FUNCTION(my_node_init)     // 节点初始化

// 示例：多阶段初始化
static clib_error_t *
my_plugin_init_phase1(vlib_main_t *vm)
{
    // 阶段1：基础初始化
    return NULL;
}

static clib_error_t *
my_plugin_init_phase2(vlib_main_t *vm)
{
    // 阶段2：依赖已初始化
    return NULL;
}

VLIB_INIT_FUNCTION(my_plugin_init_phase1);
VLIB_INIT_FUNCTION(my_plugin_init_phase2);
```

### 3.3 优先级

```c
// 初始化优先级
enum {
    VLIB_INIT_PRIORITY_FIRST = 0,
    VLIB_INIT_PRIORITY_DEFAULT = 100,
    VLIB_INIT_PRIORITY_LAST = 200,
};

// 设置优先级
VLIB_INIT_FUNCTION(my_plugin_init) =
{
    .priority = VLIB_INIT_PRIORITY_DEFAULT + 10,
    .function = my_plugin_init,
};
```

## 4. 依赖管理

### 4.1 声明依赖

```c
// 声明插件依赖
VLIB_PLUGIN_REGISTER()
{
    .version = VPP_BUILD_VER,
    .description = "My Custom Plugin",

    // 依赖声明
    .required_plugins = {
        "another_plugin",  // 必须启用
        "optional_plugin", // 可选
        NULL,
    },
};
```

### 4.2 检查依赖

```c
// 检查依赖是否启用
static clib_error_t *
my_plugin_init(vlib_main_t *vm)
{
    // 检查另一个插件
    vlib_plugin_t *p = vlib_plugin_get("another_plugin");
    if (!p) {
        return clib_error_return(0, "another_plugin not found");
    }

    if (!p->enabled) {
        return clib_error_return(0, "another_plugin not enabled");
    }

    // 获取依赖的符号
    void *sym = vlib_plugin_get_symbol("another_plugin", "some_function");
    if (!sym) {
        return clib_error_return(0, "another_plugin: some_function not found");
    }

    return NULL;
}
```

## 5. Symbol 导出

### 5.1 导出 Symbol

```c
// my_plugin.c

// 导出给其他插件使用的函数
int __clib_export
my_plugin_compute_value(int input)
{
    return input * 2;
}

// 导出变量
my_config_t __clib_export my_global_config = {
    .value = 100,
    .enabled = 1,
};
```

### 5.2 导入 Symbol

```c
// other_plugin.c

// 声明要导入的符号
extern int __clib_import my_plugin_compute_value(int input);
extern my_config_t __clib_import my_global_config;

// 使用导入的符号
void
other_plugin_use_my_plugin(void)
{
    int result = my_plugin_compute_value(10);
    // ...
}
```

## 6. Plugin 加载

### 6.1 加载配置

```bash
# /etc/vpp/startup.conf
plugins {
    # 插件路径
    path /usr/lib/vpp_plugins

    # 禁用某些插件
    disable linux-cp
    disable肚/span

    # 默认禁用插件
    plugin default { disable }
}
```

### 6.2 CLI 控制

```bash
# 显示已加载插件
vpp# show plugins

# 示例输出：
# Name                 Version    Enabled   Description
# acl-plugin          24.04      yes      ACL
# map-plugin          24.04      yes      MAP
# my_plugin           1.0.0      no       My custom plugin
# nat-plugin          24.04      yes      NAT

# 启用插件
vpp# plugin my_plugin enable

# 禁用插件
vpp# plugin my_plugin disable
```

## 7. CMakeLists.txt

```cmake
# CMakeLists.txt
add_vpp_plugin(my_plugin
    SOURCES
        my_plugin.c
        my_plugin_node.c
        my_plugin_api.c
    API_FILES
        my_plugin.api
)

# 设置插件元数据
vpp_set_plugin_name(my_plugin "My Plugin")
vpp_set_plugin_description(my_plugin "My custom plugin for VPP")
vpp_set_plugin_version(my_plugin "1.0.0")
```

## 8. 完整示例

### 8.1 最小 Plugin

```c
// minimal_plugin.c
#include <vpp/api/types.h>
#include <vpp/vpp.h>

// 插件描述符
VLIB_PLUGIN_REGISTER() = {
    .version = VPP_BUILD_VER,
    .description = "Minimal Example Plugin",
};

// 初始化
static clib_error_t *
minimal_plugin_init(vlib_main_t *vm)
{
    vlib_log_info(vm->elog_main, "minimal_plugin initialized");
    return NULL;
}

// 退出
static clib_error_t *
minimal_plugin_exit(vlib_main_t *vm)
{
    vlib_log_info(vm->elog_main, "minimal_plugin exiting");
    return NULL;
}

// 注册初始化函数
VLIB_INIT_FUNCTION(minimal_plugin_init);
VLIB_EXIT_FUNCTION(minimal_plugin_exit);
```

### 8.2 带节点的 Plugin

```c
// my_plugin_node.c
#include <vpp/vpp.h>

// 节点声明
VLIB_REGISTER_NODE(my_plugin_node) = {
    .function = my_plugin_node_fn,
    .name = "my-plugin",
    .short_name = "my",
    .type = VLIB_NODE_TYPE_INTERNAL,

    .n_errors = MY_PLUGIN_N_ERROR,
    .error_strings = my_plugin_error_strings,

    .n_next_nodes = MY_PLUGIN_NEXT_NODE,
    .next_nodes = {
        [MY_PLUGIN_NEXT_OUTPUT] = "interface-output",
    },
};

// 节点函数
static uword
my_plugin_node_fn(vlib_main_t *vm,
                  vlib_node_runtime_t *node,
                  vlib_frame_t *frame)
{
    u32 *from = vlib_frame_vector_args(frame);
    u32 n_packets = frame->n_vectors;

    for (u32 i = 0; i < n_packets; i++) {
        // 处理包
    }

    return n_packets;
}
```

## 9. 总结

Plugin 架构：

```
Plugin 生命周期：

1. 编译：libmy_plugin.so
       ↓
2. 加载：dlopen("libmy_plugin.so")
       ↓
3. 解析：VLIB_PLUGIN_REGISTER()
       ↓
4. 初始化：VLIB_INIT_FUNCTION()
       ↓
5. 运行：节点处理包
       ↓
6. 退出：VLIB_EXIT_FUNCTION()
       ↓
7. 卸载：dlclose()
```

关键宏：

| 宏 | 用途 |
|----|------|
| `VLIB_PLUGIN_REGISTER()` | 注册插件 |
| `VLIB_INIT_FUNCTION()` | 初始化函数 |
| `VLIB_EXIT_FUNCTION()` | 退出函数 |
| `VLIB_REGISTER_NODE()` | 注册节点 |
| `__clib_export` | 导出符号 |
| `__clib_import` | 导入符号 |

---

## 参考资源

- [VPP Plugin 文档](https://wiki.fd.io/view/VPP/Plugin_arch)
- [VPP API](https://wiki.fd.io/view/VPP/API_Plug-In_Architecture)
