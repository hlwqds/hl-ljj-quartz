---
title: "VPP 插件开发：从入门到高级"
date: 2026-04-09 18:30:00
tags: [vpp, plugin, api, vpp-api, binary-api, shared-memory]
description: "深入 VPP 插件开发：API 定义、Binary API、消息传递、plugin 架构、共享内存通信与调试技巧"
---

# VPP 插件开发：从入门到高级

> [!abstract] 概述
> 本章深入讲解 VPP 插件开发的各个方面：API 定义与代码生成、Binary API 机制、plugin 注册与生命周期、共享内存通信、消息处理与调试技巧。

## 1. VPP API 系统

### 1.1 API 层级

```
┌─────────────────────────────────────────────────────────────┐
│                     VPP API 层级                            │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │                  Binary API (C)                       │  │
│  │  - vl_api_xxx_t_handler()                           │  │
│  │  - 进程间通信（共享内存）                             │  │
│  │  - 高性能                                            │  │
│  └──────────────────────────────────────────────────────┘  │
│                           ↑                                  │
│  ┌──────────────────────────────────────────────────────┐  │
│  │                  JSON-RPC API (REST)                   │  │
│  │  - HTTP/JSON                                          │  │
│  │  - 远程调用                                            │  │
│  │  - 低性能但通用                                        │  │
│  └──────────────────────────────────────────────────────┘  │
│                           ↑                                  │
│  ┌──────────────────────────────────────────────────────┐  │
│  │                  CLI (console)                        │  │
│  │  - 人类可读                                            │  │
│  │  - 交互式                                              │  │
│  └──────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### 1.2 API 定义文件

```bash
# myplugin.api
definition {
    counter myplugin_counter;
};

define myplugin_create_session {
    u32 client_index;
    u32 context;
    u32 flags;
    u32 ip_address;
    u16 port;
};

define myplugin_create_session_reply {
    u32 context;
    i32 retval;
    u32 session_id;
    u64 cookie;
};

define myplugin_delete_session {
    u32 client_index;
    u32 context;
    u32 session_id;
};

define myplugin_delete_session_reply {
    u32 context;
    i32 retval;
};

define myplugin_session_details {
    u32 context;
    u32 session_id;
    u32 ip_address;
    u16 port;
    u64 packets_processed;
    u64 bytes_processed;
    u8 state;
};
```

### 1.3 代码生成

```bash
# VPP 提供代码生成工具
# 运行 api-gen
vpp_api_gen --input=myplugin.api --output=build/

# 生成的文件：
# ├── myplugin.api.c         # 消息处理
# ├── myplugin.api.h         # 消息头文件
# ├── myplugin.api_client.c  # 客户端 stub
# ├── myplugin.api_server.c  # 服务端 stub
# └── myplugin.api_json.c    # JSON-RPC 绑定
```

### 1.4 生成的头文件

```c
// myplugin.api.h (生成的部分)

/* myplugin_create_session 消息 */
typedef struct __vl_api_myplugin_create_session_t {
    u16 _vl_msg_id;           // 消息类型 (network order)
    u32 client_index;         // 客户端索引
    u32 context;             // 上下文（用于匹配 reply）
    u32 flags;
    u32 ip_address;           // network order
    u16 port;                // network order
} __attribute__((packed)) vl_api_myplugin_create_session_t;

/* 回复消息 */
typedef struct __vl_api_myplugin_create_session_reply_t {
    u16 _vl_msg_id;
    u32 context;
    i32 retval;               // 0 = success, negative = error
    u32 session_id;
    u64 cookie;
} vl_api_myplugin_create_session_reply_t;
```

## 2. Binary API 机制

### 2.1 共享内存通信

```
┌─────────────────────────────────────────────────────────────┐
│                    Binary API 通信                          │
│                                                              │
│  ┌─────────────────────┐      ┌─────────────────────────┐  │
│  │    vpp (主进程)     │      │   vpp_api (客户端)      │  │
│  │                     │      │   - vppctl              │  │
│  │  ┌───────────────┐  │      │   - Python bindings     │  │
│  │  │ msg queue     │◀─│─────▶│   - Go bindings         │  │
│  │  │ (shared mem)  │  │      │                         │  │
│  │  └───────────────┘  │      │  ┌─────────────────┐    │  │
│  │  ┌───────────────┐  │      │  │ msg queue       │    │  │
│  │  │ reply queue   │◀─│─────▶│  │ (shared mem)    │    │  │
│  │  │ (shared mem)  │  │      │  └─────────────────┘    │  │
│  │  └───────────────┘  │      │                         │  │
│  └─────────────────────┘      └─────────────────────────┘  │
│                                                              │
│  Socket: /run/vpp/api.sock                                  │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 消息 ID 分配

```c
// 消息 ID 分配（自动生成）
enum {
    VL_API_MYPLUGIN_CREATE_SESSION = 1,
    VL_API_MYPLUGIN_CREATE_SESSION_REPLY = 2,
    VL_API_MYPLUGIN_DELETE_SESSION = 3,
    VL_API_MYPLUGIN_DELETE_SESSION_REPLY = 4,
    VL_API_MYPLUGIN_SESSION_DETAILS = 5,
    // ... 更多
};

// 每个消息都有自己的 ID
// Reply 消息 ID = Request ID + 1
```

### 2.3 消息发送与接收

```c
// 服务端处理函数
static void vl_api_myplugin_create_session_t_handler
    (vl_api_myplugin_create_session_t *mp)
{
    myplugin_main_t *pm = &myplugin_main;

    // 1. 验证客户端
    if (mp->client_index != pm->myplugin_client_index) {
        // 无效客户端
        send_error_reply(mp->context, -1);
        return;
    }

    // 2. 创建 session
    u32 session_id = myplugin_session_create(
        pm,
        ntohl(mp->ip_address),
        ntohs(mp->port));

    // 3. 发送回复
    vl_api_myplugin_create_session_reply_t *rmp;
    rmp = vl_msg_api_alloc(sizeof(*rmp));
    rmp->_vl_msg_id = htons(VL_API_MYPLUGIN_CREATE_SESSION_REPLY);
    rmp->context = mp->context;
    rmp->retval = 0;
    rmp->session_id = htonl(session_id);
    rmp->cookie = htonll(generate_cookie());

    // 4. 发送到 reply queue
    vl_msg_api_send_msg(rmp, pm->myplugin_client_index);
}
```

### 2.4 客户端调用

```c
// 客户端调用示例
int myplugin_create_session(u32 ip, u16 port, u32 *session_id)
{
    vl_api_myplugin_create_session_t *mp;
    mp = vl_msg_api_alloc(sizeof(*mp));

    // 填充消息
    mp->_vl_msg_id = htons(VL_API_MYPLUGIN_CREATE_SESSION);
    mp->client_index = pm->myplugin_client_index;
    mp->context = ++pm->context;
    mp->ip_address = htonl(ip);
    mp->port = htons(port);

    // 发送并等待回复
    int rv = vl_msg_api_send_sync_request(mp);

    if (rv == 0) {
        // 获取回复
        vl_api_myplugin_create_session_reply_t *rmp =
            (vl_api_myplugin_create_session_reply_t *)rv;

        *session_id = ntohl(rmp->session_id);
    }

    return rv;
}
```

## 3. Plugin 注册

### 3.1 Plugin 描述文件

```c
// plugin 描述 (myplugin.api)
definition {
    counter myplugin_counter;
    version "1.0.0";
};

// Plugin 名称和版本（用于管理和兼容）
```

### 3.2 Plugin 初始化

```c
// myplugin.c
#include <vnet/plugin/plugin.h>
#include <vpp/api/message.h>

// ========================
// 1. Plugin 注册
// ========================
VLIB_PLUGIN_REGISTER() = {
    .version = VPP_BUILD_VER,
    .description = "My VPP Plugin",
    .version_hint = "myplugin 1.0",
};

// ========================
// 2. 主结构
// ========================
typedef struct {
    // API 客户端信息
    u32 myplugin_client_index;
    u32 myplugin_context;

    // Session 表
    u32 *session_by_id;
    uword *session_hash;

    // 统计
    u64 packets_processed;
    u64 bytes_processed;

    // 配置
    u32 flags;
    u32 ip_range_start;
    u32 ip_range_end;
} myplugin_main_t;

myplugin_main_t myplugin_main;

// ========================
// 3. 初始化函数
// ========================
static clib_error_t *myplugin_init(vlib_main_t *vm)
{
    myplugin_main_t *pm = &myplugin_main;

    // 初始化 session hash
    pm->session_by_id = 0;
    pm->session_hash = hash_create(0, sizeof(uword));

    // 注册 API
    api_main_t *am = &api_main;
    am->myplugin_create_session = vl_api_myplugin_create_session_t_handler;

    // 读取配置
    vlib_read_time_of_day_scale(&pm->config.time_of_day, &pm->config.scale);

    return 0;
}

// ========================
// 4. 清理函数
// ========================
static clib_error_t *myplugin_exit(vlib_main_t *vm)
{
    myplugin_main_t *pm = &myplugin_main;

    // 清理资源
    if (pm->session_hash) {
        hash_free(pm->session_hash);
        pm->session_hash = 0;
    }

    return 0;
}

// ========================
// 5. Plugin 初始化宏
// ========================
VLIB_PLUGIN_INIT() = {
    .init_function = myplugin_init,
    .exit_function = myplugin_exit,
    .init_order = VLIB_PLUGIN_INIT_ORDER_FIRST,
};
```

### 3.3 初始化顺序

```c
// 初始化顺序定义
enum {
    VLIB_PLUGIN_INIT_ORDER_NONE = 0,
    VLIB_PLUGIN_INIT_ORDER_FIRST,
    VLIB_PLUGIN_INIT_ORDER_MIDDLE,
    VLIB_PLUGIN_INIT_ORDER_LAST,
};

// 常用顺序
// FIRST: 基础功能（内存、日志）
// MIDDLE: 网络协议（IP、TCP）
// LAST: 高级功能（NAT、防火墙）
// AFTER_LAST: 插件
```

## 4. 自定义 CLI

### 4.1 CLI 定义

```c
// myplugin_cli.c
#include <vnet/vnet.h>
#include <vlib/vlib.h>
#include <vpp/api/api.h>

// CLI 命令定义
/*?
 * myplugin create session - Create a new session
 * This command creates a new session with the given IP and port.
?*/
static clib_error_t *
myplugin_create_session_command(vlib_main_t *vm,
                                 unformat_input_t *input,
                                 vlib_cli_command_t *cmd)
{
    myplugin_main_t *pm = &myplugin_main;

    u32 ip = 0;
    u16 port = 0;

    // 解析参数
    while (unformat_check_input(input) != UNFORMAT_END_OF_INPUT) {
        if (unformat(input, "ip %U", unformat_ip4_address, &ip)) {
            // 解析 IP
        } else if (unformat(input, "port %d", &port)) {
            // 解析端口
        } else {
            return clib_error_return(0, "unknown input");
        }
    }

    // 创建 session
    u32 session_id;
    int rv = myplugin_session_create(pm, ip, port, &session_id);

    if (rv == 0) {
        vlib_cli_output(vm, "Session created: ID=%d", session_id);
    } else {
        vlib_cli_output(vm, "Failed to create session: %d", rv);
    }

    return 0;
}

// CLI 命令注册
VLIB_CLI_COMMAND(myplugin_create_session_cmd, static) = {
    .path = "myplugin create session",
    .short_help = "myplugin create session ip <addr> port <port>",
    .function = myplugin_create_session_command,
};
```

### 4.2 CLI 解析

```bash
# 使用 CLI
vpp# myplugin create session ip 10.0.0.1 port 8080
Session created: ID=1

vpp# myplugin show sessions
ID    IP              Port    State    Packets
1     10.0.0.1        8080    active   12345
2     10.0.0.2        9090    active   67890

vpp# myplugin delete session 1
Session 1 deleted
```

## 5. 统计与监控

### 5.1 自定义统计

```c
// 定义统计
#define MYPLUGIN_COUNTERS \\
    COUNTER(packets_processed) \\
    COUNTER(bytes_processed) \\
    COUNTER(errors)

// 生成枚举
typedef enum {
    MYPLUGIN_COUNTER_PACKETS_PROCESSED,
    MYPLUGIN_COUNTER_BYTES_PROCESSED,
    MYPLUGIN_COUNTER_ERRORS,
    MYPLUGIN_N_COUNTERS,
} myplugin_counter_t;

// 递增统计
static_always_inline void
myplugin_inc_counter(myplugin_counter_t c, u64 increment)
{
    vlib_counter_t *cm = &myplugin_main.counters[c];
    vlib_counter_add(NULL, cm, increment);
}

// 获取统计
static u64
myplugin_get_counter(myplugin_counter_t c)
{
    vlib_counter_t *cm = &myplugin_main.counters[c];
    return cm->value;
}
```

### 5.2 API 暴露统计

```c
// Session details 消息（用于查询）
static void
vl_api_myplugin_session_details_t_handler
    (vl_api_myplugin_session_details_t *mp)
{
    myplugin_main_t *pm = &myplugin_main;
    u32 session_id = ntohl(mp->session_id);

    // 查找 session
    myplugin_session_t *s = find_session(pm, session_id);
    if (!s) {
        send_error_reply(mp->context, -1);
        return;
    }

    // 发送详情
    vl_api_myplugin_session_details_t *rmp;
    rmp = vl_msg_api_alloc(sizeof(*rmp));

    rmp->_vl_msg_id = htons(VL_API_MYPLUGIN_SESSION_DETAILS);
    rmp->context = mp->context;
    rmp->session_id = htonl(s->id);
    rmp->ip_address = htonl(s->ip);
    rmp->port = htons(s->port);
    rmp->packets_processed = htonll(s->packets);
    rmp->bytes_processed = htonll(s->bytes);
    rmp->state = s->state;

    vl_msg_api_send_msg(rmp, pm->myplugin_client_index);
}
```

## 6. Plugin 间依赖

### 6.1 依赖声明

```c
// myplugin2 依赖 myplugin1
VLIB_PLUGIN_REGISTER() = {
    .version = VPP_BUILD_VER,
    .description = "My Plugin 2 (depends on plugin 1)",
    .version_hint = "myplugin2 1.0",

    // 依赖列表
    .required_plugins = {
        "myplugin1",  // 必须是 myplugin1
    },
};
```

### 6.2 Plugin 间通信

```c
// Plugin 1 导出 API
typedef struct {
    u32 session_id;
    u32 ip;
    u16 port;
} myplugin1_session_t;

// Plugin 2 使用 Plugin 1 的 API
static myplugin1_session_t *
myplugin2_get_session_from_plugin1(u32 session_id)
{
    myplugin1_main_t *pm1 = &myplugin1_main;

    // 直接访问 plugin 1 的数据结构
    return find_session(pm1, session_id);
}
```

## 7. 调试技巧

### 7.1 API 跟踪

```bash
# 启用 API 跟踪
vpp# api trace on

# 执行一些操作
vpp# myplugin create session ip 10.0.0.1 port 8080

# 查看跟踪
vpp# api trace custom-dump
```

### 7.2 消息日志

```bash
# 设置 API 日志级别
vpp# set logging class api all debug

# 查看日志
vpp# show logging
```

### 7.3 Plugin 调试

```bash
# 列出所有插件
vpp# show plugins

# 查看插件详细信息
vpp# show plugin myplugin

# 启用插件调试
vpp# set plugin log myplugin debug
```

### 7.4 GDB 调试

```bash
# 编译时添加调试符号
make VPP_DEBUG=1

# 附加到运行中的 VPP
gdb vpp
(gdb) attach $(pidof vpp)

# 设置断点
(gdb) break myplugin_create_session_command

# 查看 backtrace
(gdb) bt
```

## 8. 完整示例

### 8.1 完整 Plugin 代码结构

```
myplugin/
├── CMakeLists.txt
├── myplugin.api           # API 定义
├── myplugin.c             # 主文件
├── myplugin.h             # 头文件
├── myplugin_cli.c         # CLI
├── node_session.c         # Session 处理 node
└── test/
    └── test_myplugin.py   # Python 测试
```

### 8.2 CMakeLists.txt

```cmake
add_vpp_plugin(myplugin
    SOURCES
        myplugin.c
        myplugin_cli.c
        node_session.c
    API_FILES
        myplugin.api
)
```

## 9. 总结

VPP Plugin 开发要点：

| 阶段 | 关键点 |
|------|--------|
| **API 设计** | 定义清晰的请求/响应消息 |
| **Plugin 注册** | 正确的初始化/清理函数 |
| **消息处理** | Binary API 高性能通信 |
| **CLI** | 人类可读的调试命令 |
| **统计** | 暴露可观测性数据 |
| **测试** | Python/Go bindings 测试 |

---

## 参考资源

- [VPP Plugin How-To](https://wiki.fd.io/view/VPP/How_To_Write_A_VPP_Plugin)
- [VPP API Guide](https://wiki.fd.io/view/VPP/VPP_API)
- [VPP CLI](https://wiki.fd.io/view/VPP/Command-line_Interface_(CLI))
- [api-app 示例](https://github.com/FDio/vpp/tree/master/src/vpp-api)
